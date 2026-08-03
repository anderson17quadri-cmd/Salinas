-- =====================================================================
-- Salinas — Registo de Ponto
-- 06_banco_horas.sql — Banco de horas (conta corrente de horas)
-- =====================================================================
-- Executar depois de 03_functions.sql: usa `_horas_do_periodo`.
--
-- Como funciona
-- -------------
-- Fechar um período grava, por funcionário, uma linha em
-- `banco_horas_movimentos` com o que foi trabalhado, o que era esperado e
-- a diferença. Enquanto o `status` é 'aberto', esse saldo conta para o
-- acumulado; ao passar a 'compensado', 'pago' ou 'descontado', o
-- movimento fica liquidado e sai do acumulado sem desaparecer do
-- histórico.
--
-- `funcionarios.saldo_banco_horas` é sempre **recalculado** a partir dos
-- movimentos abertos, nunca incrementado. Somar deltas dava saldos que,
-- ao fim de alguns meses e algumas correcções, deixavam de bater certo
-- com o histórico — e num saldo de horas isso é dinheiro.
--
-- Saldo negativo é dívida de horas, não é falta. Uma falta só existe
-- quando não há registo nenhum num dia com horário e não há justificação
-- (ver `dias_sem_registo_nem_justificacao` em `_horas_do_periodo`).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Recalcula o acumulado de um funcionário a partir dos movimentos abertos
-- ---------------------------------------------------------------------
create or replace function _recalcular_saldo_banco_horas(p_funcionario_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_saldo numeric;
begin
  select coalesce(sum(saldo), 0) into v_saldo
  from banco_horas_movimentos
  where funcionario_id = p_funcionario_id
    and status = 'aberto';

  update funcionarios
     set saldo_banco_horas = round(v_saldo, 2)
   where id = p_funcionario_id;

  return round(v_saldo, 2);
end;
$$;

revoke all on function _recalcular_saldo_banco_horas(uuid) from public, anon, authenticated;

-- =====================================================================
-- ADMIN — FECHAR UM PERÍODO
-- =====================================================================
-- Percorre os funcionários da empresa, calcula o saldo do mês e grava um
-- movimento por pessoa. Pode ser corrido à mão pelo admin ou por um job
-- mensal (pg_cron).
--
-- É idempotente: refechar o mesmo mês actualiza o movimento automático em
-- vez de criar outro. Períodos já liquidados (pagos, compensados ou
-- descontados) não são tocados — reescrevê-los apagaria uma decisão já
-- tomada, e possivelmente já paga.
create or replace function admin_fechar_periodo_banco_horas(p_ano int, p_mes int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_empresa_id uuid;
  v_tz text;
  v_inicio date;
  v_fim date;
  v_linha record;
  v_saldo numeric;
  v_existente banco_horas_movimentos;
  v_gravados int := 0;
  v_ignorados int := 0;
  v_ignorados_nomes text[] := '{}';
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  if p_mes < 1 or p_mes > 12 then
    raise exception 'Mês inválido: %', p_mes using errcode = '22023';
  end if;

  v_empresa_id := auth_empresa_id();
  select timezone into v_tz from empresas where id = v_empresa_id;

  v_inicio := make_date(p_ano, p_mes, 1);
  v_fim := (v_inicio + interval '1 month')::date;

  if v_inicio > (now() at time zone v_tz)::date then
    raise exception 'Não é possível fechar um período que ainda não começou.'
      using errcode = 'P0001';
  end if;

  for v_linha in
    select h.*, f.nome
    from _horas_do_periodo(v_empresa_id, v_inicio, v_fim, v_tz) h
    join funcionarios f on f.id = h.funcionario_id
  loop
    v_saldo := round((v_linha.horas_trabalhadas - v_linha.horas_esperadas)::numeric, 2);

    select * into v_existente
    from banco_horas_movimentos
    where funcionario_id = v_linha.funcionario_id
      and periodo_referencia = v_inicio
      and manual is false;

    if v_existente.id is not null and v_existente.status <> 'aberto' then
      v_ignorados := v_ignorados + 1;
      v_ignorados_nomes := v_ignorados_nomes || v_linha.nome;
      continue;
    end if;

    insert into banco_horas_movimentos (
      funcionario_id, periodo_referencia, horas_trabalhadas,
      horas_esperadas, saldo, status, manual, revisto_por
    ) values (
      v_linha.funcionario_id, v_inicio, v_linha.horas_trabalhadas,
      v_linha.horas_esperadas, v_saldo, 'aberto', false, auth.uid()
    )
    on conflict (funcionario_id, periodo_referencia) where manual is false
    do update set
      horas_trabalhadas = excluded.horas_trabalhadas,
      horas_esperadas = excluded.horas_esperadas,
      saldo = excluded.saldo,
      revisto_por = excluded.revisto_por,
      created_at = now();

    perform _recalcular_saldo_banco_horas(v_linha.funcionario_id);
    v_gravados := v_gravados + 1;
  end loop;

  return jsonb_build_object(
    'ano', p_ano,
    'mes', p_mes,
    'periodo_referencia', v_inicio,
    'gravados', v_gravados,
    'ignorados', v_ignorados,
    'ignorados_nomes', to_jsonb(v_ignorados_nomes)
  );
end;
$$;

-- =====================================================================
-- ADMIN — SALDOS DA EMPRESA
-- =====================================================================
create or replace function admin_banco_horas()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_empresa_id uuid;
  v_politica text;
  v_limite int;
  v_tz text;
  v_hoje date;
  v_resultado jsonb;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  v_empresa_id := auth_empresa_id();
  select politica_banco_horas, limite_compensacao_meses, timezone
    into v_politica, v_limite, v_tz
  from empresas where id = v_empresa_id;

  v_hoje := (now() at time zone v_tz)::date;

  with func as (
    select * from funcionarios where empresa_id = v_empresa_id
  ),
  movimentos as (
    select m.*
    from banco_horas_movimentos m
    join func f on f.id = m.funcionario_id
  ),
  agregado as (
    select
      funcionario_id,
      count(*) filter (where status = 'aberto')::int as movimentos_abertos,
      min(periodo_referencia) filter (where status = 'aberto') as periodo_mais_antigo,
      max(periodo_referencia) as ultimo_periodo,
      round(coalesce(sum(saldo) filter (where status = 'aberto' and saldo > 0), 0), 2) as credito,
      round(coalesce(sum(saldo) filter (where status = 'aberto' and saldo < 0), 0), 2) as divida
    from movimentos
    group by funcionario_id
  ),
  linhas as (
    select
      f.id as funcionario_id,
      f.nome,
      f.cargo,
      f.ativo,
      round(f.saldo_banco_horas::numeric, 2) as saldo,
      coalesce(a.movimentos_abertos, 0) as movimentos_abertos,
      a.periodo_mais_antigo,
      a.ultimo_periodo,
      coalesce(a.credito, 0) as credito,
      coalesce(a.divida, 0) as divida,
      -- Passado o limite legal de compensação, o saldo tem de ser
      -- decidido (pago, compensado ou renegociado) — o painel destaca-o.
      (a.periodo_mais_antigo is not null
       and a.periodo_mais_antigo < (v_hoje - make_interval(months => v_limite))::date
      ) as fora_do_prazo
    from func f
    left join agregado a on a.funcionario_id = f.id
  )
  select jsonb_build_object(
    'politica', v_politica,
    'limite_compensacao_meses', v_limite,
    'timezone', v_tz,
    'total_credito', (select round(coalesce(sum(credito), 0), 2) from linhas),
    'total_divida', (select round(coalesce(sum(divida), 0), 2) from linhas),
    'total_saldo', (select round(coalesce(sum(saldo), 0), 2) from linhas),
    'fora_do_prazo', (select count(*) from linhas where fora_do_prazo),
    'linhas', coalesce((select jsonb_agg(to_jsonb(l) order by l.nome) from linhas l), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$$;

-- =====================================================================
-- ADMIN — HISTÓRICO DE MOVIMENTOS DE UM FUNCIONÁRIO
-- =====================================================================
create or replace function admin_movimentos_banco_horas(p_funcionario_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  select nome into v_nome
  from funcionarios
  where id = p_funcionario_id and empresa_id = auth_empresa_id();

  if v_nome is null then
    raise exception 'Funcionário não encontrado nesta empresa.' using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'funcionario_id', p_funcionario_id,
    'nome', v_nome,
    'saldo', (select round(saldo_banco_horas::numeric, 2) from funcionarios where id = p_funcionario_id),
    'movimentos', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.periodo_referencia desc, m.created_at desc)
      from (
        select id, periodo_referencia, horas_trabalhadas, horas_esperadas,
               saldo, status, observacao, manual, created_at
        from banco_horas_movimentos
        where funcionario_id = p_funcionario_id
      ) m
    ), '[]'::jsonb)
  );
end;
$$;

-- =====================================================================
-- ADMIN — MOVIMENTO MANUAL (compensação, pagamento, acerto)
-- =====================================================================
-- Serve para lançar horas fora do fecho automático: pagar horas extra,
-- converter crédito em folga, ou corrigir um acerto combinado.
--
-- O sinal segue a mesma convenção dos movimentos automáticos: positivo
-- acrescenta crédito, negativo desconta. Uma folga de 8 h dada a partir
-- do banco lança-se como -8.
create or replace function admin_registar_movimento_banco_horas(
  p_funcionario_id uuid,
  p_saldo numeric,
  p_status text default 'aberto',
  p_observacao text default null,
  p_periodo_referencia date default null
)
returns banco_horas_movimentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov banco_horas_movimentos;
  v_tz text;
  v_periodo date;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  if not exists (
    select 1 from funcionarios
    where id = p_funcionario_id and empresa_id = auth_empresa_id()
  ) then
    raise exception 'Funcionário não encontrado nesta empresa.' using errcode = 'P0001';
  end if;

  if p_saldo is null or p_saldo = 0 then
    raise exception 'Indique quantas horas quer lançar (positivo ou negativo).'
      using errcode = 'P0001';
  end if;

  if p_status not in ('aberto','compensado','pago','descontado') then
    raise exception 'Estado inválido: %', p_status using errcode = '22023';
  end if;

  select timezone into v_tz from empresas where id = auth_empresa_id();
  v_periodo := coalesce(p_periodo_referencia, date_trunc('month', now() at time zone v_tz)::date);

  insert into banco_horas_movimentos (
    funcionario_id, periodo_referencia, horas_trabalhadas, horas_esperadas,
    saldo, status, observacao, manual, revisto_por
  ) values (
    p_funcionario_id, v_periodo, 0, 0,
    round(p_saldo, 2), p_status, p_observacao, true, auth.uid()
  )
  returning * into v_mov;

  perform _recalcular_saldo_banco_horas(p_funcionario_id);

  return v_mov;
end;
$$;

-- =====================================================================
-- ADMIN — LIQUIDAR UM MOVIMENTO
-- =====================================================================
create or replace function admin_liquidar_movimento_banco_horas(
  p_movimento_id uuid,
  p_status text,
  p_observacao text default null
)
returns banco_horas_movimentos
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov banco_horas_movimentos;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  if p_status not in ('aberto','compensado','pago','descontado') then
    raise exception 'Estado inválido: %', p_status using errcode = '22023';
  end if;

  update banco_horas_movimentos m
     set status = p_status,
         observacao = coalesce(p_observacao, m.observacao),
         revisto_por = auth.uid()
    from funcionarios f
   where m.id = p_movimento_id
     and f.id = m.funcionario_id
     and f.empresa_id = auth_empresa_id()
  returning m.* into v_mov;

  if v_mov.id is null then
    raise exception 'Movimento não encontrado nesta empresa.' using errcode = 'P0001';
  end if;

  perform _recalcular_saldo_banco_horas(v_mov.funcionario_id);

  return v_mov;
end;
$$;

-- =====================================================================
-- FUNCIONÁRIO — O MEU BANCO DE HORAS
-- =====================================================================
create or replace function meu_banco_horas()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f funcionarios;
  e empresas;
begin
  f := _funcionario_atual();
  e := _empresa_do_funcionario(f.empresa_id);

  return jsonb_build_object(
    'saldo', round(f.saldo_banco_horas::numeric, 2),
    'politica', e.politica_banco_horas,
    'limite_compensacao_meses', e.limite_compensacao_meses,
    'movimentos', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.periodo_referencia desc, m.created_at desc)
      from (
        select periodo_referencia, horas_trabalhadas, horas_esperadas,
               saldo, status, observacao, manual, created_at
        from banco_horas_movimentos
        where funcionario_id = f.id
        order by periodo_referencia desc, created_at desc
        limit 12
      ) m
    ), '[]'::jsonb)
  );
end;
$$;

-- =====================================================================
-- GRANTS
-- =====================================================================
revoke all on function admin_fechar_periodo_banco_horas(int, int) from public, anon;
revoke all on function admin_banco_horas() from public, anon;
revoke all on function admin_movimentos_banco_horas(uuid) from public, anon;
revoke all on function admin_registar_movimento_banco_horas(uuid, numeric, text, text, date) from public, anon;
revoke all on function admin_liquidar_movimento_banco_horas(uuid, text, text) from public, anon;
revoke all on function meu_banco_horas() from public, anon;

grant execute on function admin_fechar_periodo_banco_horas(int, int) to authenticated;
grant execute on function admin_banco_horas() to authenticated;
grant execute on function admin_movimentos_banco_horas(uuid) to authenticated;
grant execute on function admin_registar_movimento_banco_horas(uuid, numeric, text, text, date) to authenticated;
grant execute on function admin_liquidar_movimento_banco_horas(uuid, text, text) to authenticated;
grant execute on function meu_banco_horas() to authenticated;
