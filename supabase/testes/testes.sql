-- =====================================================================
-- Salinas — Registo de Ponto
-- testes/testes.sql — Testes das regras de negócio e do RLS
-- =====================================================================
-- Corre contra um Postgres limpo com os stubs de teste aplicados:
--
--   psql -v ON_ERROR_STOP=1 -d salinas \
--     -f supabase/00_stubs_teste.sql \
--     -f supabase/01_schema.sql \
--     -f supabase/02_rls.sql \
--     -f supabase/03_functions.sql \
--     -f supabase/04_storage.sql \
--     -f supabase/testes/testes.sql
--
-- Ou, mais simplesmente: ./supabase/testes/correr.sh
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

-- ---------------------------------------------------------------------
-- Utilitários de teste
-- ---------------------------------------------------------------------
create or replace function teste_ok(p_descricao text, p_condicao boolean)
returns void language plpgsql as $$
begin
  if p_condicao then
    raise notice '  ok    %', p_descricao;
  else
    raise exception 'FALHOU: %', p_descricao;
  end if;
end;
$$;

/** Executa SQL esperando que rebente com uma mensagem que contenha p_fragmento. */
create or replace function teste_falha(p_descricao text, p_sql text, p_fragmento text)
returns void language plpgsql as $$
declare
  v_msg text;
begin
  begin
    execute p_sql;
    raise exception 'FALHOU: % — esperava-se um erro, mas passou.', p_descricao;
  exception
    when others then
      v_msg := sqlerrm;
      if v_msg like '%esperava-se um erro%' then raise; end if;
      if position(p_fragmento in v_msg) = 0 then
        raise exception 'FALHOU: % — erro inesperado: %', p_descricao, v_msg;
      end if;
      raise notice '  ok    % (%)', p_descricao, left(v_msg, 60);
  end;
end;
$$;

/** Recua no tempo os registos de um funcionário, para contornar o anti-duplo-toque. */
create or replace function teste_recuar(p_funcionario uuid, p_intervalo interval)
returns void language sql as $$
  update registos_ponto set "timestamp" = "timestamp" - p_intervalo
  where funcionario_id = p_funcionario;
$$;

create or replace function teste_entrar(p_user uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, false);
end;
$$;

-- ---------------------------------------------------------------------
-- Dados de teste: duas empresas, para provar o isolamento entre elas
-- ---------------------------------------------------------------------
\echo ''
\echo '== Preparação =='

truncate registos_ponto, faltas_justificacoes, horarios_esperados,
         funcionarios, admins, empresas cascade;
delete from auth.users;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'ana@alfa.pt'),
  ('22222222-2222-2222-2222-222222222222', 'bruno@alfa.pt'),
  ('33333333-3333-3333-3333-333333333333', 'admin@alfa.pt'),
  ('44444444-4444-4444-4444-444444444444', 'carla@beta.pt'),
  ('55555555-5555-5555-5555-555555555555', 'admin@beta.pt');

-- Empresa Alfa: Praça do Comércio, Lisboa. Raio de 100 m.
insert into empresas (id, nome, latitude, longitude, raio_metros, qr_code_token)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Alfa Lda.',
   38.707751, -9.136592, 100, 'token-alfa'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Beta Lda.',
   41.157944, -8.629105, 100, 'token-beta');

insert into funcionarios (id, empresa_id, user_id, nome, email, horas_semanais_esperadas) values
  ('ffffffff-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111', 'Ana', 'ana@alfa.pt', 40),
  ('ffffffff-0000-0000-0000-00000000000b', 'aaaaaaaa-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222', 'Bruno', 'bruno@alfa.pt', 40),
  ('ffffffff-0000-0000-0000-00000000000c', 'bbbbbbbb-0000-0000-0000-000000000002',
   '44444444-4444-4444-4444-444444444444', 'Carla', 'carla@beta.pt', 40);

insert into admins (empresa_id, user_id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'admin@alfa.pt'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555', 'admin@beta.pt');

insert into horarios_esperados (funcionario_id, dia_semana, hora_entrada, hora_saida)
select 'ffffffff-0000-0000-0000-00000000000a', d, time '09:00', time '18:00'
from generate_series(1, 5) d;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 1. Haversine =='

do $$
declare
  v_perto numeric;
  v_longe numeric;
begin
  -- ~50 m a norte da Praça do Comércio
  v_perto := round(haversine_metros(38.708201, -9.136592, 38.707751, -9.136592)::numeric, 0);
  perform teste_ok('50 m ficam entre 40 e 60 m', v_perto between 40 and 60);

  -- Lisboa → Porto, ~274 km
  v_longe := round(haversine_metros(38.707751, -9.136592, 41.157944, -8.629105)::numeric / 1000, 0);
  perform teste_ok('Lisboa–Porto ronda os 274 km', v_longe between 270 and 280);

  perform teste_ok('distância a si próprio é zero',
    haversine_metros(38.7, -9.1, 38.7, -9.1) = 0);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 2. Sequência de registos (entrada/saída/pausas) =='

do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_res jsonb;
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');

  v_res := registar_ponto_qrcode('token-alfa', 'entrada');
  perform teste_ok('entrada registada', v_res->>'tipo' = 'entrada');
  perform teste_ok('hora local devolvida', (v_res->>'hora_local') ~ '^\d{2}:\d{2}$');
  perform teste_recuar(v_ana, interval '2 hours');

  -- A regra central: não se pode entrar duas vezes seguidas.
  perform teste_falha(
    'segunda entrada seguida é recusada',
    $sql$ select registar_ponto_qrcode('token-alfa', 'entrada') $sql$,
    'entrada por fechar'
  );

  perform teste_falha(
    'fim de pausa sem pausa a decorrer é recusado',
    $sql$ select registar_ponto_qrcode('token-alfa', 'fim_pausa') $sql$,
    'nenhuma pausa a decorrer'
  );

  v_res := registar_ponto_qrcode('token-alfa', 'inicio_pausa');
  perform teste_ok('início de pausa aceite durante o turno', v_res->>'tipo' = 'inicio_pausa');
  perform teste_recuar(v_ana, interval '1 hour');

  perform teste_falha(
    'saída durante a pausa é recusada',
    $sql$ select registar_ponto_qrcode('token-alfa', 'saida') $sql$,
    'Registe o fim da pausa'
  );

  v_res := registar_ponto_qrcode('token-alfa', 'fim_pausa');
  perform teste_ok('fim de pausa aceite', v_res->>'tipo' = 'fim_pausa');
  perform teste_recuar(v_ana, interval '1 hour');

  v_res := registar_ponto_qrcode('token-alfa', 'saida');
  perform teste_ok('saída aceite depois da pausa', v_res->>'tipo' = 'saida');
  perform teste_recuar(v_ana, interval '1 hour');

  perform teste_falha(
    'segunda saída seguida é recusada',
    $sql$ select registar_ponto_qrcode('token-alfa', 'saida') $sql$,
    'nenhuma entrada aberta'
  );

  perform teste_falha(
    'tipo desconhecido é recusado',
    $sql$ select registar_ponto_qrcode('token-alfa', 'almoco') $sql$,
    'Tipo de registo inválido'
  );
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 3. Anti-duplo-toque =='

do $$
begin
  perform teste_entrar('22222222-2222-2222-2222-222222222222');
  perform registar_ponto_qrcode('token-alfa', 'entrada');

  perform teste_falha(
    'dois registos em menos de 30 s são recusados',
    $sql$ select registar_ponto_qrcode('token-alfa', 'saida') $sql$,
    'demasiado próximo'
  );

  perform teste_recuar('ffffffff-0000-0000-0000-00000000000b', interval '1 hour');
  perform teste_ok('passado o intervalo, a saída passa',
    (registar_ponto_qrcode('token-alfa', 'saida')->>'tipo') = 'saida');
  perform teste_recuar('ffffffff-0000-0000-0000-00000000000b', interval '1 hour');
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 4. QR code: token e empresa =='

do $$
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');

  -- O ponto crítico: ler o QR de outra empresa não pode registar ponto.
  perform teste_falha(
    'token de outra empresa é recusado',
    $sql$ select registar_ponto_qrcode('token-beta', 'entrada') $sql$,
    'de outra empresa'
  );

  perform teste_falha(
    'token inventado é recusado',
    $sql$ select registar_ponto_qrcode('token-a-inventar', 'entrada') $sql$,
    'QR code inválido'
  );

  perform teste_falha(
    'token nulo é recusado',
    $sql$ select registar_ponto_qrcode(null, 'entrada') $sql$,
    'QR code inválido'
  );
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 5. Geolocalização e raio =='

do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_res jsonb;
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');

  -- ~50 m da empresa: dentro do raio de 100 m.
  v_res := registar_ponto_gps('entrada', 38.708201, -9.136592);
  perform teste_ok('registo perto da empresa fica dentro do raio',
    (v_res->>'dentro_do_raio')::boolean is true);
  perform teste_recuar(v_ana, interval '1 hour');

  -- No Porto: muito fora, mas o registo é gravado à mesma para revisão.
  v_res := registar_ponto_gps('saida', 41.157944, -8.629105);
  perform teste_ok('registo longe é gravado, marcado fora do raio',
    (v_res->>'dentro_do_raio')::boolean is false);
  perform teste_ok('distância calculada e devolvida',
    (v_res->>'distancia_metros')::numeric > 200000);
  perform teste_recuar(v_ana, interval '1 hour');

  perform teste_falha(
    'GPS sem coordenadas é recusado',
    $sql$ select registar_ponto_gps('entrada', null, null) $sql$,
    'Localização indisponível'
  );
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 6. Métodos activos por empresa =='

do $$
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');

  update empresas set metodo_gps_ativo = false
  where id = 'aaaaaaaa-0000-0000-0000-000000000001';

  perform teste_falha(
    'GPS desactivado bloqueia o registo por GPS',
    $sql$ select registar_ponto_gps('entrada', 38.7077, -9.1365) $sql$,
    'geolocalização não está activo'
  );

  update empresas set metodo_gps_ativo = true, metodo_qrcode_ativo = false
  where id = 'aaaaaaaa-0000-0000-0000-000000000001';

  perform teste_falha(
    'QR desactivado bloqueia o registo por QR',
    $sql$ select registar_ponto_qrcode('token-alfa', 'entrada') $sql$,
    'QR code não está activo'
  );

  update empresas set metodo_qrcode_ativo = true
  where id = 'aaaaaaaa-0000-0000-0000-000000000001';
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 7. Foto obrigatória =='

do $$
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');

  update empresas set foto_obrigatoria = true
  where id = 'aaaaaaaa-0000-0000-0000-000000000001';

  perform teste_falha(
    'sem foto, o registo por GPS é recusado',
    $sql$ select registar_ponto_gps('entrada', 38.7077, -9.1365) $sql$,
    'exige uma foto'
  );

  perform teste_ok('com foto, o registo passa',
    (registar_ponto_gps('entrada', 38.7077, -9.1365,
       'aaaaaaaa-0000-0000-0000-000000000001/ffffffff-0000-0000-0000-00000000000a/x.jpg'
     )->>'tipo') = 'entrada');

  perform teste_recuar('ffffffff-0000-0000-0000-00000000000a', interval '1 hour');
  update empresas set foto_obrigatoria = false
  where id = 'aaaaaaaa-0000-0000-0000-000000000001';
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 8. Funcionário inactivo =='

do $$
begin
  perform teste_entrar('22222222-2222-2222-2222-222222222222');
  update funcionarios set ativo = false where id = 'ffffffff-0000-0000-0000-00000000000b';

  perform teste_falha(
    'funcionário inactivo não bate ponto',
    $sql$ select registar_ponto_qrcode('token-alfa', 'entrada') $sql$,
    'inactiva'
  );

  update funcionarios set ativo = true where id = 'ffffffff-0000-0000-0000-00000000000b';
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 9. RLS: isolamento entre funcionários e empresas =='

do $$
declare
  v_total int;
begin
  -- A Ana só se vê a si própria.
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  set local role authenticated;

  select count(*) into v_total from registos_ponto;
  perform teste_ok('funcionário só vê os seus registos',
    v_total = (select count(*) from registos_ponto
               where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a'));

  select count(*) into v_total from funcionarios;
  perform teste_ok('funcionário só vê a sua própria ficha', v_total = 1);

  select count(*) into v_total from empresas;
  perform teste_ok('funcionário só vê a sua empresa', v_total = 1);

  reset role;
end;
$$;

do $$
declare
  v_total int;
begin
  -- O admin da Alfa vê a Alfa inteira, e nada da Beta.
  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  set local role authenticated;

  select count(*) into v_total from funcionarios;
  perform teste_ok('admin vê os funcionários da sua empresa', v_total = 2);

  select count(*) into v_total from funcionarios where empresa_id <> 'aaaaaaaa-0000-0000-0000-000000000001';
  perform teste_ok('admin não vê funcionários de outra empresa', v_total = 0);

  select count(*) into v_total from registos_ponto;
  perform teste_ok('admin vê os registos da sua empresa',
    v_total = (select count(*) from registos_ponto
               where empresa_id = 'aaaaaaaa-0000-0000-0000-000000000001'));

  reset role;
end;
$$;

do $$
declare
  v_total int;
begin
  -- O admin da Beta não pode ver nada da Alfa.
  perform teste_entrar('55555555-5555-5555-5555-555555555555');
  set local role authenticated;

  select count(*) into v_total from registos_ponto;
  perform teste_ok('admin de outra empresa não vê registos alheios', v_total = 0);

  select count(*) into v_total from empresas;
  perform teste_ok('admin de outra empresa só vê a sua empresa', v_total = 1);

  reset role;
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 10. O token do QR nunca é legível pela API =='

do $$
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  set local role authenticated;

  perform teste_falha(
    'funcionário não consegue ler empresas.qr_code_token',
    $sql$ select qr_code_token from empresas $sql$,
    'permission denied'
  );

  reset role;
end;
$$;

do $$
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  set local role authenticated;

  perform teste_falha(
    'nem o admin lê a coluna directamente (só via RPC)',
    $sql$ select qr_code_token from empresas $sql$,
    'permission denied'
  );

  perform teste_ok('o admin obtém o token pelo RPC',
    admin_obter_qr_token()->>'qr_code_token' = 'token-alfa');

  reset role;
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 11. Escrita directa em registos_ponto está fechada =='

do $$
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  set local role authenticated;

  -- Se isto passasse, toda a validação de sequência seria contornável.
  perform teste_falha(
    'funcionário não pode inserir registos à mão',
    $sql$ insert into registos_ponto (funcionario_id, tipo, metodo)
          values ('ffffffff-0000-0000-0000-00000000000a', 'entrada', 'qrcode') $sql$,
    'permission denied'
  );

  perform teste_falha(
    'funcionário não pode apagar registos',
    $sql$ delete from registos_ponto $sql$,
    'permission denied'
  );

  perform teste_falha(
    'funcionário não pode mudar de empresa',
    $sql$ update funcionarios set empresa_id = 'bbbbbbbb-0000-0000-0000-000000000002' $sql$,
    'permission denied'
  );

  reset role;
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 12. Regeneração do token do QR =='

do $$
declare
  v_novo text;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  v_novo := admin_regenerar_qr_token()->>'qr_code_token';

  perform teste_ok('token regenerado é diferente', v_novo <> 'token-alfa');

  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  perform teste_falha(
    'o token antigo deixa de funcionar',
    $sql$ select registar_ponto_qrcode('token-alfa', 'entrada') $sql$,
    'QR code inválido'
  );

  -- Repõe um valor previsível para os testes seguintes.
  update empresas set qr_code_token = 'token-alfa'
  where id = 'aaaaaaaa-0000-0000-0000-000000000001';
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 13. Permissões de admin =='

do $$
begin
  -- Um funcionário comum não pode usar os RPC de administração.
  perform teste_entrar('11111111-1111-1111-1111-111111111111');

  perform teste_falha(
    'funcionário não regenera o token',
    $sql$ select admin_regenerar_qr_token() $sql$,
    'Apenas administradores'
  );

  perform teste_falha(
    'funcionário não cria funcionários',
    $sql$ select admin_criar_funcionario('Intruso', 'intruso@alfa.pt') $sql$,
    'Apenas administradores'
  );

  perform teste_falha(
    'funcionário não vê o dashboard',
    $sql$ select admin_dashboard_hoje() $sql$,
    'Apenas administradores'
  );
end;
$$;

do $$
declare
  v_novo funcionarios;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  v_novo := admin_criar_funcionario('Diogo', 'Diogo@Alfa.pt ', 'Estágio', 20);
  perform teste_ok('admin cria funcionário na sua empresa',
    v_novo.empresa_id = 'aaaaaaaa-0000-0000-0000-000000000001');
  perform teste_ok('email é normalizado', v_novo.email = 'diogo@alfa.pt');
  perform teste_ok('horas registadas', v_novo.horas_semanais_esperadas = 20);

  perform teste_falha(
    'email inválido é recusado',
    $sql$ select admin_criar_funcionario('X', 'nao-e-email') $sql$,
    'Email inválido'
  );

  -- O admin da Beta não pode mexer em funcionários da Alfa.
  perform teste_entrar('55555555-5555-5555-5555-555555555555');
  perform teste_falha(
    'admin não edita funcionários de outra empresa',
    format($sql$ select admin_atualizar_funcionario(%L, 'Hackeado') $sql$, v_novo.id),
    'não encontrado nesta empresa'
  );
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 14. Justificações =='

do $$
declare
  v_id uuid;
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  set local role authenticated;

  insert into faltas_justificacoes (funcionario_id, data, motivo, status)
  values ('ffffffff-0000-0000-0000-00000000000a', current_date, 'Consulta médica', 'pendente')
  returning id into v_id;
  perform teste_ok('funcionário submete a sua justificação', v_id is not null);

  perform teste_falha(
    'não pode submeter em nome de outro',
    $sql$ insert into faltas_justificacoes (funcionario_id, data, motivo, status)
          values ('ffffffff-0000-0000-0000-00000000000b', current_date, 'x', 'pendente') $sql$,
    'row-level security'
  );

  perform teste_falha(
    'não pode auto-aprovar-se',
    $sql$ insert into faltas_justificacoes (funcionario_id, data, motivo, status)
          values ('ffffffff-0000-0000-0000-00000000000a', current_date, 'x', 'aprovado') $sql$,
    'row-level security'
  );

  perform teste_falha(
    'não pode aprovar um pedido já submetido',
    format($sql$ update faltas_justificacoes set status = 'aprovado' where id = %L $sql$, v_id),
    'permission denied'
  );

  reset role;

  perform teste_entrar('55555555-5555-5555-5555-555555555555');
  perform teste_falha(
    'admin de outra empresa não decide',
    format($sql$ select admin_rever_justificacao(%L, 'aprovado') $sql$, v_id),
    'não encontrada nesta empresa'
  );

  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  perform teste_ok('admin da empresa aprova',
    (admin_rever_justificacao(v_id, 'aprovado')).status = 'aprovado');
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 15. Estado actual e dashboard =='

do $$
declare
  v_estado jsonb;
  v_dash jsonb;
begin
  -- Fecha o turno aberto da Ana para o estado ficar previsível.
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  v_estado := meu_estado_atual();

  if v_estado->>'estado' <> 'fora' then
    perform registar_ponto_qrcode('token-alfa', 'saida');
    perform teste_recuar('ffffffff-0000-0000-0000-00000000000a', interval '1 hour');
  end if;

  perform registar_ponto_qrcode('token-alfa', 'entrada');
  v_estado := meu_estado_atual();

  perform teste_ok('estado passa a "dentro" após a entrada', v_estado->>'estado' = 'dentro');
  perform teste_ok('próximos tipos limitados a saída e pausa',
    (v_estado->'proximos_tipos')::text like '%saida%'
    and (v_estado->'proximos_tipos')::text like '%inicio_pausa%');
  perform teste_ok('empresa devolvida no estado',
    v_estado->'empresa'->>'nome' = 'Alfa Lda.');
  perform teste_ok('token do QR não vem no estado',
    (v_estado->'empresa')::text not like '%token-alfa%');

  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  v_dash := admin_dashboard_hoje();

  perform teste_ok('dashboard conta a Ana como ao serviço',
    (v_dash->>'dentro')::int >= 1);
  perform teste_ok('dashboard lista os funcionários activos',
    jsonb_array_length(v_dash->'funcionarios') >= 2);
  perform teste_ok('dashboard não conta a empresa Beta',
    (v_dash->>'total_ativos')::int = (
      select count(*) from funcionarios
      where empresa_id = 'aaaaaaaa-0000-0000-0000-000000000001' and ativo));
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 16. Relatório mensal =='

do $$
declare
  v_rel jsonb;
  v_linha jsonb;
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
begin
  -- Um dia limpo: entrada 09:00, pausa 13:00–14:00, saída 18:00 → 8 horas.
  delete from registos_ponto where funcionario_id = v_ana;

  insert into registos_ponto (funcionario_id, empresa_id, tipo, metodo, "timestamp") values
    (v_ana, 'aaaaaaaa-0000-0000-0000-000000000001', 'entrada', 'qrcode',
     (date_trunc('month', now()) + interval '9 hours') at time zone 'Europe/Lisbon'),
    (v_ana, 'aaaaaaaa-0000-0000-0000-000000000001', 'inicio_pausa', 'qrcode',
     (date_trunc('month', now()) + interval '13 hours') at time zone 'Europe/Lisbon'),
    (v_ana, 'aaaaaaaa-0000-0000-0000-000000000001', 'fim_pausa', 'qrcode',
     (date_trunc('month', now()) + interval '14 hours') at time zone 'Europe/Lisbon'),
    (v_ana, 'aaaaaaaa-0000-0000-0000-000000000001', 'saida', 'qrcode',
     (date_trunc('month', now()) + interval '18 hours') at time zone 'Europe/Lisbon');

  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  v_rel := admin_relatorio_mensal(
    extract(year from now())::int,
    extract(month from now())::int
  );

  select j into v_linha
  from jsonb_array_elements(v_rel->'linhas') j
  where j->>'funcionario_id' = v_ana::text;

  perform teste_ok('a linha da Ana existe no relatório', v_linha is not null);
  perform teste_ok('9h–18h com 1h de pausa dão 8 horas',
    (v_linha->>'horas_trabalhadas')::numeric = 8);
  perform teste_ok('horas esperadas vêm do horário definido',
    (v_linha->>'horas_esperadas')::numeric > 0);
  perform teste_ok('saldo é a diferença entre trabalhado e esperado',
    (v_linha->>'saldo_horas')::numeric
      = (v_linha->>'horas_trabalhadas')::numeric - (v_linha->>'horas_esperadas')::numeric);
  perform teste_ok('a Carla (empresa Beta) não aparece',
    not exists (
      select 1 from jsonb_array_elements(v_rel->'linhas') j
      where j->>'funcionario_id' = 'ffffffff-0000-0000-0000-00000000000c'
    ));

  perform teste_falha(
    'mês inválido é recusado',
    $sql$ select admin_relatorio_mensal(2026, 13) $sql$,
    'Mês inválido'
  );
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 17. Utilizador sem funcionário associado =='

do $$
begin
  perform teste_entrar('99999999-9999-9999-9999-999999999999');

  perform teste_falha(
    'utilizador desconhecido não bate ponto',
    $sql$ select registar_ponto_qrcode('token-alfa', 'entrada') $sql$,
    'não está associado a nenhum funcionário'
  );
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 18. Ligação automática da conta Auth por email =='

do $$
declare
  v_user uuid := '77777777-7777-7777-7777-777777777777';
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  perform admin_criar_funcionario('Eva', 'eva@alfa.pt', 'Loja', 40);

  perform teste_ok('funcionário criado ainda sem conta',
    (select user_id from funcionarios where email = 'eva@alfa.pt') is null);

  insert into auth.users (id, email) values (v_user, 'eva@alfa.pt');

  perform teste_ok('conta é ligada automaticamente no signup',
    (select user_id from funcionarios where email = 'eva@alfa.pt') = v_user);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '======================================================='
\echo ' Todos os testes passaram.'
\echo '======================================================='
