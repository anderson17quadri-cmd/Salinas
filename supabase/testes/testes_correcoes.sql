-- =====================================================================
-- Salinas — Registo de Ponto
-- testes/testes_correcoes.sql — Correcções pelo gestor e regra do GPS
-- =====================================================================
-- Corre depois de testes.sql (reutiliza teste_ok/teste_falha/teste_entrar).
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

\echo ''
\echo '== Preparação (correcções) =='

truncate correcoes_registos, banco_horas_movimentos, registos_ponto, faltas_justificacoes,
         horarios_esperados, funcionarios, admins, empresas cascade;
delete from auth.users;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'ana@alfa.pt'),
  ('33333333-3333-3333-3333-333333333333', 'admin@alfa.pt'),
  ('55555555-5555-5555-5555-555555555555', 'admin@beta.pt');

insert into empresas (id, nome, latitude, longitude, raio_metros, qr_code_token) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Alfa Lda.', 38.707751, -9.136592, 100, 'token-alfa'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Beta Lda.', 41.157944, -8.629105, 100, 'token-beta');

insert into funcionarios (id, empresa_id, user_id, nome, email) values
  ('ffffffff-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111', 'Ana', 'ana@alfa.pt');

insert into admins (empresa_id, user_id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'admin@alfa.pt'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555', 'admin@beta.pt');

-- ---------------------------------------------------------------------
\echo ''
\echo '== 1. A saída esquecida bloqueia a entrada do dia seguinte =='
do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  perform registar_ponto_qrcode('token-alfa', 'entrada');
  -- A entrada foi ontem de manhã e ela esqueceu-se de sair.
  perform teste_recuar(v_ana, interval '1 day');

  perform teste_falha('sem correcção, a entrada de hoje é recusada',
    $sql$ select registar_ponto_qrcode('token-alfa', 'entrada') $sql$,
    'entrada por fechar');
end;
$$;

\echo ''
\echo '== 2. O gestor acrescenta a saída em falta =='
do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_entrada timestamptz;
  v_res jsonb;
begin
  select "timestamp" into v_entrada from registos_ponto where funcionario_id = v_ana;

  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  perform teste_falha('sem motivo, a correcção é recusada',
    format($sql$ select admin_adicionar_registo(%L, 'saida', %L, '  ') $sql$,
           v_ana, v_entrada + interval '8 hours'),
    'motivo');

  perform teste_falha('uma hora no futuro é recusada',
    format($sql$ select admin_adicionar_registo(%L, 'saida', now() + interval '1 hour', 'teste') $sql$, v_ana),
    'futuro');

  perform teste_falha('uma segunda entrada seguida é recusada',
    format($sql$ select admin_adicionar_registo(%L, 'entrada', %L, 'teste') $sql$,
           v_ana, v_entrada + interval '1 hour'),
    'sequência fica errada');
  perform teste_ok('a tentativa recusada não deixou nada gravado',
    (select count(*) from registos_ponto where funcionario_id = v_ana) = 1);

  v_res := admin_adicionar_registo(v_ana, 'saida', v_entrada + interval '8 hours', 'Esqueceu-se de sair');
  perform teste_ok('a saída em falta é acrescentada', v_res->>'tipo' = 'saida');
  perform teste_ok('fica marcada como correcção manual, com o motivo',
    v_res->>'metodo' = 'manual' and v_res->>'observacao' = 'Esqueceu-se de sair');
  perform teste_ok('a correcção fica no histórico, com quem a fez',
    exists (select 1 from correcoes_registos c join admins a on a.id = c.admin_id
            where c.accao = 'adicionado' and a.email = 'admin@alfa.pt'));

  -- Agora a Ana já consegue entrar hoje.
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  v_res := registar_ponto_qrcode('token-alfa', 'entrada');
  perform teste_ok('depois da correcção, a entrada de hoje é aceite', v_res->>'tipo' = 'entrada');
end;
$$;

\echo ''
\echo '== 3. Apagar um registo errado =='
do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_primeira uuid;
  v_ultima uuid;
begin
  select id into v_primeira from registos_ponto where funcionario_id = v_ana order by "timestamp" limit 1;
  select id into v_ultima from registos_ponto where funcionario_id = v_ana order by "timestamp" desc limit 1;

  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  perform teste_falha('apagar uma entrada do meio deixa a sequência errada e é recusado',
    format($sql$ select admin_apagar_registo(%L, 'engano') $sql$, v_primeira),
    'sequência fica errada');
  perform teste_ok('a tentativa recusada não apagou nada',
    exists (select 1 from registos_ponto where id = v_primeira));

  perform admin_apagar_registo(v_ultima, 'Entrada batida por engano');
  perform teste_ok('apagar a última entrada é aceite',
    not exists (select 1 from registos_ponto where id = v_ultima));
  perform teste_ok('o registo apagado fica guardado no histórico',
    exists (select 1 from correcoes_registos
            where accao = 'apagado' and (registo->>'id')::uuid = v_ultima));
end;
$$;

\echo ''
\echo '== 4. Quem pode corrigir =='
do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_reg uuid;
begin
  select id into v_reg from registos_ponto where funcionario_id = v_ana limit 1;

  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  perform teste_falha('o funcionário não corrige os próprios registos',
    format($sql$ select admin_adicionar_registo(%L, 'entrada', now() - interval '1 hour', 'x') $sql$, v_ana),
    'Apenas administradores');
  perform teste_falha('o funcionário não apaga registos',
    format($sql$ select admin_apagar_registo(%L, 'x') $sql$, v_reg),
    'Apenas administradores');

  perform teste_entrar('55555555-5555-5555-5555-555555555555');
  perform teste_falha('o admin de outra empresa não acrescenta registos',
    format($sql$ select admin_adicionar_registo(%L, 'entrada', now() - interval '1 hour', 'x') $sql$, v_ana),
    'não encontrado nesta empresa');
  perform teste_falha('o admin de outra empresa não apaga registos',
    format($sql$ select admin_apagar_registo(%L, 'x') $sql$, v_reg),
    'não encontrado nesta empresa');
end;
$$;

\echo ''
\echo '== 5. Histórico de correcções: só o gestor da empresa o vê =='
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
do $$ begin
  perform teste_ok('o funcionário não vê o histórico de correcções',
    (select count(*) from correcoes_registos) = 0);
end $$;
select set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
do $$ begin
  perform teste_ok('o admin de outra empresa não vê o histórico',
    (select count(*) from correcoes_registos) = 0);
end $$;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
do $$ begin
  perform teste_ok('o gestor da empresa vê o histórico',
    (select count(*) from correcoes_registos) = 2);
end $$;
reset role;

\echo ''
\echo '== 6. GPS só para a saída e as pausas =='
do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_res jsonb;
begin
  delete from registos_ponto where funcionario_id = v_ana;
  update empresas set gps_so_saida = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';

  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  -- Em casa, mesmo por cima da loja: dentro do raio.
  perform teste_falha('a entrada por GPS é recusada, mesmo dentro do raio',
    $sql$ select registar_ponto_gps('entrada', 38.707751, -9.136592) $sql$,
    'QR code da loja');

  perform registar_ponto_qrcode('token-alfa', 'entrada');
  perform teste_recuar(v_ana, interval '8 hours');

  v_res := registar_ponto_gps('saida', 38.707751, -9.136592);
  perform teste_ok('a saída por GPS é aceite para quem mora em cima da loja', v_res->>'tipo' = 'saida');

  -- Só com GPS (sem QR activo) a entrada por GPS continua possível —
  -- senão ninguém conseguia entrar.
  update empresas set metodo_qrcode_ativo = false where id = 'aaaaaaaa-0000-0000-0000-000000000001';
  perform teste_recuar(v_ana, interval '12 hours');
  v_res := registar_ponto_gps('entrada', 38.707751, -9.136592);
  perform teste_ok('sem QR activo, a entrada por GPS é aceite', v_res->>'tipo' = 'entrada');

  update empresas set metodo_qrcode_ativo = true, gps_so_saida = false
  where id = 'aaaaaaaa-0000-0000-0000-000000000001';
  perform teste_ok('a app recebe a opção no estado actual',
    (meu_estado_atual()->'empresa') ? 'gps_so_saida');
end;
$$;

\echo ''
\echo '======================================================='
\echo ' Correcções: todos os testes passaram.'
\echo '======================================================='
