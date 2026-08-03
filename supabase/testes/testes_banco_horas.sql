-- =====================================================================
-- Salinas — Registo de Ponto
-- testes/testes_banco_horas.sql — Testes do banco de horas
-- =====================================================================
-- Corre depois de testes.sql (reutiliza os helpers teste_ok/teste_falha).
-- Ver supabase/testes/correr.sh.
-- =====================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

\echo ''
\echo '== Preparação (banco de horas) =='

truncate banco_horas_movimentos, registos_ponto, faltas_justificacoes,
         horarios_esperados, funcionarios, admins, empresas cascade;
delete from auth.users;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'ana@alfa.pt'),
  ('22222222-2222-2222-2222-222222222222', 'bruno@alfa.pt'),
  ('33333333-3333-3333-3333-333333333333', 'admin@alfa.pt'),
  ('55555555-5555-5555-5555-555555555555', 'admin@beta.pt');

insert into empresas (id, nome, latitude, longitude, raio_metros, qr_code_token,
                      politica_banco_horas, limite_compensacao_meses)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Alfa Lda.', 38.707751, -9.136592, 100,
   'token-alfa', 'compensar_folga', 12),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Beta Lda.', 41.157944, -8.629105, 100,
   'token-beta', 'apenas_reportar', 6);

insert into funcionarios (id, empresa_id, user_id, nome, email, horas_semanais_esperadas) values
  ('ffffffff-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111', 'Ana', 'ana@alfa.pt', 40),
  ('ffffffff-0000-0000-0000-00000000000b', 'aaaaaaaa-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222', 'Bruno', 'bruno@alfa.pt', 40);

insert into admins (empresa_id, user_id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'admin@alfa.pt'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555', 'admin@beta.pt');

-- Ana: segunda a sexta, 09:00–17:00 → 8 h por dia esperado.
insert into horarios_esperados (funcionario_id, dia_semana, hora_entrada, hora_saida)
select 'ffffffff-0000-0000-0000-00000000000a', d, time '09:00', time '17:00'
from generate_series(1, 5) d;

-- ---------------------------------------------------------------------
-- Cenário: mês passado. A Ana trabalha em dois dias úteis —
--   dia A: 09:00–18:00 com 1 h de pausa → 8 h (bate certo com o esperado)
--   dia B: 09:00–13:00                  → 4 h (menos 4 h do que o esperado)
-- Todos os outros dias úteis do mês ficam sem registo.
-- ---------------------------------------------------------------------
create or replace function teste_preparar_mes()
returns date language plpgsql as $$
declare
  v_mes date;
  v_a date;
  v_b date;
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_emp uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
begin
  v_mes := date_trunc('month', (now() at time zone 'Europe/Lisbon') - interval '1 month')::date;

  -- Primeira e segunda segunda-feira do mês
  v_a := v_mes + ((1 - extract(dow from v_mes)::int + 7) % 7);
  v_b := v_a + 7;

  delete from registos_ponto where funcionario_id = v_ana;

  insert into registos_ponto (funcionario_id, empresa_id, tipo, metodo, "timestamp") values
    (v_ana, v_emp, 'entrada',      'qrcode', (v_a + time '09:00') at time zone 'Europe/Lisbon'),
    (v_ana, v_emp, 'inicio_pausa', 'qrcode', (v_a + time '13:00') at time zone 'Europe/Lisbon'),
    (v_ana, v_emp, 'fim_pausa',    'qrcode', (v_a + time '14:00') at time zone 'Europe/Lisbon'),
    (v_ana, v_emp, 'saida',        'qrcode', (v_a + time '18:00') at time zone 'Europe/Lisbon'),
    (v_ana, v_emp, 'entrada',      'qrcode', (v_b + time '09:00') at time zone 'Europe/Lisbon'),
    (v_ana, v_emp, 'saida',        'qrcode', (v_b + time '13:00') at time zone 'Europe/Lisbon');

  return v_mes;
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 1. Cálculo das horas do período =='

do $$
declare
  v_mes date := teste_preparar_mes();
  v_h record;
  v_dias_uteis int;
begin
  select * into v_h
  from _horas_do_periodo(
    'aaaaaaaa-0000-0000-0000-000000000001',
    v_mes,
    (v_mes + interval '1 month')::date,
    'Europe/Lisbon'
  )
  where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a';

  perform teste_ok('8 h num dia e 4 h noutro dão 12 h trabalhadas',
    v_h.horas_trabalhadas = 12);

  perform teste_ok('duas entradas contam como dois dias com entrada',
    v_h.dias_com_entrada = 2);

  -- O esperado são 8 h por cada dia útil do mês.
  select count(*) into v_dias_uteis
  from generate_series(v_mes, (v_mes + interval '1 month')::date - 1, interval '1 day') d
  where extract(dow from d) between 1 and 5;

  perform teste_ok('horas esperadas seguem o horário definido',
    v_h.horas_esperadas = v_dias_uteis * 8);

  perform teste_ok('dias úteis sem registo nem justificação contam como falta',
    v_h.dias_sem_registo_nem_justificacao = v_dias_uteis - 2);

  perform teste_ok('sem horário definido, estima-se pelas horas semanais',
    (select horas_esperadas from _horas_do_periodo(
       'aaaaaaaa-0000-0000-0000-000000000001', v_mes,
       (v_mes + interval '1 month')::date, 'Europe/Lisbon')
     where funcionario_id = 'ffffffff-0000-0000-0000-00000000000b') > 0);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 2. Uma justificação evita a falta =='

do $$
declare
  v_mes date := date_trunc('month', (now() at time zone 'Europe/Lisbon') - interval '1 month')::date;
  v_dia date;
  v_antes int;
  v_depois int;
begin
  select dias_sem_registo_nem_justificacao into v_antes
  from _horas_do_periodo('aaaaaaaa-0000-0000-0000-000000000001', v_mes,
                         (v_mes + interval '1 month')::date, 'Europe/Lisbon')
  where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a';

  -- Terceira segunda-feira do mês: dia útil, sem registo.
  v_dia := v_mes + ((1 - extract(dow from v_mes)::int + 7) % 7) + 14;

  insert into faltas_justificacoes (funcionario_id, data, motivo, status)
  values ('ffffffff-0000-0000-0000-00000000000a', v_dia, 'Doença', 'aprovado');

  select dias_sem_registo_nem_justificacao into v_depois
  from _horas_do_periodo('aaaaaaaa-0000-0000-0000-000000000001', v_mes,
                         (v_mes + interval '1 month')::date, 'Europe/Lisbon')
  where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a';

  perform teste_ok('justificação aprovada tira o dia das faltas', v_depois = v_antes - 1);

  -- Uma justificação rejeitada não deve proteger o dia.
  update faltas_justificacoes set status = 'rejeitado'
  where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a' and data = v_dia;

  select dias_sem_registo_nem_justificacao into v_depois
  from _horas_do_periodo('aaaaaaaa-0000-0000-0000-000000000001', v_mes,
                         (v_mes + interval '1 month')::date, 'Europe/Lisbon')
  where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a';

  perform teste_ok('justificação rejeitada volta a contar como falta', v_depois = v_antes);

  delete from faltas_justificacoes where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a';
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 3. Fechar o período =='

do $$
declare
  v_mes date := date_trunc('month', (now() at time zone 'Europe/Lisbon') - interval '1 month')::date;
  v_res jsonb;
  v_mov banco_horas_movimentos;
  v_saldo numeric;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  v_res := admin_fechar_periodo_banco_horas(
    extract(year from v_mes)::int, extract(month from v_mes)::int);

  perform teste_ok('fecho grava um movimento por funcionário',
    (v_res->>'gravados')::int = 2);
  perform teste_ok('nada foi ignorado no primeiro fecho',
    (v_res->>'ignorados')::int = 0);

  select * into v_mov from banco_horas_movimentos
  where funcionario_id = 'ffffffff-0000-0000-0000-00000000000a';

  perform teste_ok('o movimento aponta para o mês fechado', v_mov.periodo_referencia = v_mes);
  perform teste_ok('o saldo é trabalhado menos esperado',
    v_mov.saldo = v_mov.horas_trabalhadas - v_mov.horas_esperadas);
  perform teste_ok('trabalhar menos do que o esperado dá saldo negativo', v_mov.saldo < 0);
  perform teste_ok('o movimento do fecho não é manual', v_mov.manual is false);
  perform teste_ok('o movimento nasce aberto', v_mov.status = 'aberto');

  select saldo_banco_horas into v_saldo
  from funcionarios where id = 'ffffffff-0000-0000-0000-00000000000a';

  perform teste_ok('o acumulado do funcionário passa a reflectir o movimento',
    v_saldo = v_mov.saldo);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 4. Refechar o mesmo período é idempotente =='

do $$
declare
  v_mes date := date_trunc('month', (now() at time zone 'Europe/Lisbon') - interval '1 month')::date;
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_saldo_antes numeric;
  v_saldo_depois numeric;
  v_total int;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  select saldo_banco_horas into v_saldo_antes from funcionarios where id = v_ana;

  perform admin_fechar_periodo_banco_horas(
    extract(year from v_mes)::int, extract(month from v_mes)::int);
  perform admin_fechar_periodo_banco_horas(
    extract(year from v_mes)::int, extract(month from v_mes)::int);

  select count(*) into v_total from banco_horas_movimentos
  where funcionario_id = v_ana and periodo_referencia = v_mes and manual is false;

  perform teste_ok('refechar não duplica o movimento', v_total = 1);

  select saldo_banco_horas into v_saldo_depois from funcionarios where id = v_ana;
  perform teste_ok('refechar não duplica o saldo', v_saldo_depois = v_saldo_antes);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 5. Um período já liquidado não é reescrito =='

do $$
declare
  v_mes date := date_trunc('month', (now() at time zone 'Europe/Lisbon') - interval '1 month')::date;
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_mov banco_horas_movimentos;
  v_saldo_liquidado numeric;
  v_res jsonb;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  select * into v_mov from banco_horas_movimentos
  where funcionario_id = v_ana and manual is false;

  v_mov := admin_liquidar_movimento_banco_horas(v_mov.id, 'pago', 'Horas pagas em Agosto');
  perform teste_ok('liquidar muda o estado do movimento', v_mov.status = 'pago');
  perform teste_ok('a observação fica registada', v_mov.observacao = 'Horas pagas em Agosto');

  select saldo_banco_horas into v_saldo_liquidado from funcionarios where id = v_ana;
  perform teste_ok('um movimento liquidado sai do acumulado', v_saldo_liquidado = 0);

  -- Refechar não pode apagar uma decisão já tomada (e possivelmente paga).
  v_res := admin_fechar_periodo_banco_horas(
    extract(year from v_mes)::int, extract(month from v_mes)::int);

  perform teste_ok('o fecho ignora o período já pago',
    (v_res->>'ignorados')::int = 1);
  perform teste_ok('o nome de quem foi ignorado é devolvido',
    (v_res->'ignorados_nomes')::text like '%Ana%');

  select * into v_mov from banco_horas_movimentos
  where funcionario_id = v_ana and manual is false;
  perform teste_ok('o movimento pago mantém-se pago', v_mov.status = 'pago');

  -- Repor o estado para os testes seguintes.
  perform admin_liquidar_movimento_banco_horas(v_mov.id, 'aberto');
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 6. Movimentos manuais =='

do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_mov banco_horas_movimentos;
  v_antes numeric;
  v_depois numeric;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  select saldo_banco_horas into v_antes from funcionarios where id = v_ana;

  v_mov := admin_registar_movimento_banco_horas(v_ana, 10, 'aberto', 'Acerto combinado');
  perform teste_ok('o movimento manual fica marcado como manual', v_mov.manual is true);

  select saldo_banco_horas into v_depois from funcionarios where id = v_ana;
  perform teste_ok('lançar +10 h soma 10 h ao acumulado', v_depois = v_antes + 10);

  -- Uma folga de 8 h dada a partir do banco lança-se como -8.
  perform admin_registar_movimento_banco_horas(v_ana, -8, 'compensado', 'Folga de 8 h');
  select saldo_banco_horas into v_depois from funcionarios where id = v_ana;

  perform teste_ok('um movimento já compensado não entra no acumulado',
    v_depois = v_antes + 10);

  perform teste_falha(
    'lançar zero horas é recusado',
    format($sql$ select admin_registar_movimento_banco_horas(%L, 0) $sql$, v_ana),
    'quantas horas'
  );

  perform teste_falha(
    'estado inválido é recusado',
    format($sql$ select admin_registar_movimento_banco_horas(%L, 5, 'inventado') $sql$, v_ana),
    'Estado inválido'
  );

  -- Vários movimentos manuais podem coexistir no mesmo período.
  perform admin_registar_movimento_banco_horas(v_ana, 2, 'aberto', 'Segundo acerto');
  select saldo_banco_horas into v_depois from funcionarios where id = v_ana;
  perform teste_ok('vários movimentos manuais somam-se', v_depois = v_antes + 12);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 7. Saldo é sempre recalculado, nunca acumulado às cegas =='

do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_esperado numeric;
  v_guardado numeric;
begin
  select coalesce(sum(saldo), 0) into v_esperado
  from banco_horas_movimentos
  where funcionario_id = v_ana and status = 'aberto';

  select saldo_banco_horas into v_guardado from funcionarios where id = v_ana;

  perform teste_ok('o acumulado é exactamente a soma dos movimentos abertos',
    round(v_guardado, 2) = round(v_esperado, 2));
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 8. Vista de saldos da empresa =='

do $$
declare
  v_res jsonb;
  v_linha jsonb;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');
  v_res := admin_banco_horas();

  perform teste_ok('a política da empresa é devolvida',
    v_res->>'politica' = 'compensar_folga');
  perform teste_ok('o limite de compensação é devolvido',
    (v_res->>'limite_compensacao_meses')::int = 12);
  perform teste_ok('todos os funcionários aparecem',
    jsonb_array_length(v_res->'linhas') = 2);

  select j into v_linha
  from jsonb_array_elements(v_res->'linhas') j
  where j->>'nome' = 'Ana';

  perform teste_ok('crédito e dívida são separados',
    (v_linha->>'credito')::numeric > 0 and (v_linha->>'divida')::numeric < 0);
  perform teste_ok('o saldo bate certo com o crédito mais a dívida',
    (v_linha->>'saldo')::numeric
      = (v_linha->>'credito')::numeric + (v_linha->>'divida')::numeric);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 9. Limite legal de compensação =='

do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_res jsonb;
  v_linha jsonb;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  -- Um movimento com dois anos ultrapassa o limite de 12 meses.
  perform admin_registar_movimento_banco_horas(
    v_ana, 5, 'aberto', 'Saldo antigo',
    (current_date - interval '24 months')::date);

  v_res := admin_banco_horas();
  select j into v_linha from jsonb_array_elements(v_res->'linhas') j where j->>'nome' = 'Ana';

  perform teste_ok('saldo mais antigo do que o limite é assinalado',
    (v_linha->>'fora_do_prazo')::boolean is true);
  perform teste_ok('a empresa conta quantos estão fora do prazo',
    (v_res->>'fora_do_prazo')::int = 1);

  select j into v_linha from jsonb_array_elements(v_res->'linhas') j where j->>'nome' = 'Bruno';
  perform teste_ok('quem não tem saldo antigo não é assinalado',
    coalesce((v_linha->>'fora_do_prazo')::boolean, false) is false);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 10. Permissões e isolamento =='

do $$
declare
  v_ana uuid := 'ffffffff-0000-0000-0000-00000000000a';
  v_mov banco_horas_movimentos;
begin
  select * into v_mov from banco_horas_movimentos where funcionario_id = v_ana limit 1;

  -- Um funcionário comum não mexe no banco de horas.
  perform teste_entrar('11111111-1111-1111-1111-111111111111');

  perform teste_falha(
    'funcionário não fecha períodos',
    $sql$ select admin_fechar_periodo_banco_horas(2026, 1) $sql$,
    'Apenas administradores'
  );

  perform teste_falha(
    'funcionário não lança movimentos',
    format($sql$ select admin_registar_movimento_banco_horas(%L, 100) $sql$, v_ana),
    'Apenas administradores'
  );

  perform teste_falha(
    'funcionário não vê os saldos da empresa',
    $sql$ select admin_banco_horas() $sql$,
    'Apenas administradores'
  );

  -- Nem o admin de outra empresa.
  perform teste_entrar('55555555-5555-5555-5555-555555555555');

  perform teste_falha(
    'admin de outra empresa não lança movimentos',
    format($sql$ select admin_registar_movimento_banco_horas(%L, 100) $sql$, v_ana),
    'não encontrado nesta empresa'
  );

  perform teste_falha(
    'admin de outra empresa não liquida movimentos alheios',
    format($sql$ select admin_liquidar_movimento_banco_horas(%L, 'pago') $sql$, v_mov.id),
    'não encontrado nesta empresa'
  );

  perform teste_falha(
    'admin de outra empresa não vê o histórico alheio',
    format($sql$ select admin_movimentos_banco_horas(%L) $sql$, v_ana),
    'não encontrado nesta empresa'
  );
end;
$$;

do $$
declare
  v_total int;
begin
  -- RLS: cada um vê apenas os seus movimentos.
  perform teste_entrar('22222222-2222-2222-2222-222222222222');
  set local role authenticated;

  select count(*) into v_total from banco_horas_movimentos;
  perform teste_ok('funcionário só vê os seus movimentos',
    v_total = (select count(*) from banco_horas_movimentos
               where funcionario_id = 'ffffffff-0000-0000-0000-00000000000b'));

  perform teste_falha(
    'funcionário não escreve movimentos à mão',
    $sql$ insert into banco_horas_movimentos
            (funcionario_id, periodo_referencia, horas_trabalhadas, horas_esperadas, saldo)
          values ('ffffffff-0000-0000-0000-00000000000b', current_date, 100, 0, 100) $sql$,
    'permission denied'
  );

  perform teste_falha(
    'funcionário não altera o seu saldo',
    $sql$ update funcionarios set saldo_banco_horas = 999 $sql$,
    'permission denied'
  );

  reset role;
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 11. O funcionário consulta o seu banco de horas =='

do $$
declare
  v_res jsonb;
  v_saldo numeric;
begin
  perform teste_entrar('11111111-1111-1111-1111-111111111111');
  v_res := meu_banco_horas();

  select saldo_banco_horas into v_saldo
  from funcionarios where id = 'ffffffff-0000-0000-0000-00000000000a';

  perform teste_ok('o saldo devolvido é o do próprio', (v_res->>'saldo')::numeric = round(v_saldo, 2));
  perform teste_ok('a política da empresa acompanha o saldo',
    v_res->>'politica' = 'compensar_folga');
  perform teste_ok('o histórico recente vem junto',
    jsonb_array_length(v_res->'movimentos') > 0);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 12. Relatório mensal inclui o banco de horas =='

do $$
declare
  v_mes date := date_trunc('month', (now() at time zone 'Europe/Lisbon') - interval '1 month')::date;
  v_rel jsonb;
  v_linha jsonb;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  v_rel := admin_relatorio_mensal(
    extract(year from v_mes)::int, extract(month from v_mes)::int);

  perform teste_ok('o relatório traz a política da empresa',
    v_rel->>'politica_banco_horas' = 'compensar_folga');

  select j into v_linha
  from jsonb_array_elements(v_rel->'linhas') j
  where j->>'nome' = 'Ana';

  perform teste_ok('cada linha traz o saldo acumulado',
    (v_linha->>'saldo_banco_horas') is not null);
  perform teste_ok('o saldo do mês continua a ser trabalhado menos esperado',
    (v_linha->>'saldo_horas')::numeric
      = (v_linha->>'horas_trabalhadas')::numeric - (v_linha->>'horas_esperadas')::numeric);
  perform teste_ok('o relatório distingue faltas sem justificação',
    (v_linha->>'dias_sem_registo_nem_justificacao')::int > 0);
  perform teste_ok('as horas do relatório batem certo com as do banco de horas',
    (v_linha->>'horas_trabalhadas')::numeric = 12);
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '== 13. Fechar um período futuro é recusado =='

do $$
declare
  v_futuro date := (date_trunc('month', now()) + interval '2 months')::date;
begin
  perform teste_entrar('33333333-3333-3333-3333-333333333333');

  perform teste_falha(
    'não se fecha um mês que ainda não começou',
    format($sql$ select admin_fechar_periodo_banco_horas(%s, %s) $sql$,
           extract(year from v_futuro)::int, extract(month from v_futuro)::int),
    'ainda não começou'
  );

  perform teste_falha(
    'mês inválido é recusado',
    $sql$ select admin_fechar_periodo_banco_horas(2026, 13) $sql$,
    'Mês inválido'
  );
end;
$$;

-- ---------------------------------------------------------------------
\echo ''
\echo '======================================================='
\echo ' Banco de horas: todos os testes passaram.'
\echo '======================================================='
