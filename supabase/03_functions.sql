-- =====================================================================
-- Salinas — Registo de Ponto
-- 03_functions.sql — RPC functions (SECURITY DEFINER)
-- =====================================================================
-- Todas as operações sensíveis passam por aqui. O cliente nunca escreve
-- directamente em registos_ponto: as regras de sequência (entrada/saída),
-- a validação do token do QR e o cálculo do raio são feitos no servidor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Distância entre dois pontos (fórmula de Haversine), em metros
-- ---------------------------------------------------------------------
create or replace function haversine_metros(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision
)
returns double precision
language sql
immutable
as $$
  select 2 * 6371000 * asin(
    sqrt(
      pow(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) *
      pow(sin(radians(lon2 - lon1) / 2), 2)
    )
  );
$$;

-- ---------------------------------------------------------------------
-- Máquina de estados do ponto
--   (nada|saida)          → entrada
--   (entrada|fim_pausa)   → saida | inicio_pausa
--   inicio_pausa          → fim_pausa
-- ---------------------------------------------------------------------
create or replace function _proximos_tipos_validos(p_ultimo text)
returns text[]
language sql
immutable
as $$
  select case
    when p_ultimo is null or p_ultimo = 'saida' then array['entrada']
    when p_ultimo in ('entrada','fim_pausa')    then array['saida','inicio_pausa']
    when p_ultimo = 'inicio_pausa'              then array['fim_pausa']
    else array['entrada']
  end;
$$;

create or replace function _mensagem_sequencia(p_ultimo text, p_tipo text)
returns text
language sql
immutable
as $$
  select case
    when p_tipo = 'entrada' and p_ultimo in ('entrada','fim_pausa')
      then 'Já tem uma entrada por fechar. Registe a saída primeiro.'
    when p_tipo = 'entrada' and p_ultimo = 'inicio_pausa'
      then 'Está em pausa. Registe o fim da pausa primeiro.'
    when p_tipo = 'saida' and (p_ultimo is null or p_ultimo = 'saida')
      then 'Não tem nenhuma entrada aberta para registar a saída.'
    when p_tipo = 'saida' and p_ultimo = 'inicio_pausa'
      then 'Está em pausa. Registe o fim da pausa antes de sair.'
    when p_tipo = 'inicio_pausa'
      then 'Só pode iniciar uma pausa durante um turno aberto.'
    when p_tipo = 'fim_pausa'
      then 'Não tem nenhuma pausa a decorrer.'
    else 'Sequência de registos inválida.'
  end;
$$;

-- ---------------------------------------------------------------------
-- Núcleo partilhado pelos dois métodos de check-in
-- ---------------------------------------------------------------------
create or replace function _registar_ponto(
  p_funcionario funcionarios,
  p_empresa empresas,
  p_tipo text,
  p_metodo text,
  p_latitude double precision,
  p_longitude double precision,
  p_dentro_do_raio boolean,
  p_distancia numeric,
  p_foto_url text,
  p_observacao text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ultimo_tipo text;
  v_ultimo_ts   timestamptz;
  v_registo     registos_ponto;
begin
  if p_tipo not in ('entrada','saida','inicio_pausa','fim_pausa') then
    raise exception 'Tipo de registo inválido: %', p_tipo
      using errcode = '22023';
  end if;

  select tipo, "timestamp" into v_ultimo_tipo, v_ultimo_ts
  from registos_ponto
  where funcionario_id = p_funcionario.id
  order by "timestamp" desc
  limit 1;

  -- Protege contra duplo toque / duplo scan acidental
  if v_ultimo_ts is not null and now() - v_ultimo_ts < interval '30 seconds' then
    raise exception 'Registo demasiado próximo do anterior. Aguarde alguns segundos.'
      using errcode = 'P0001';
  end if;

  if not (p_tipo = any (_proximos_tipos_validos(v_ultimo_tipo))) then
    raise exception '%', _mensagem_sequencia(v_ultimo_tipo, p_tipo)
      using errcode = 'P0001';
  end if;

  insert into registos_ponto (
    funcionario_id, empresa_id, tipo, metodo, "timestamp",
    latitude, longitude, dentro_do_raio, distancia_metros, foto_url, observacao
  ) values (
    p_funcionario.id, p_empresa.id, p_tipo, p_metodo, now(),
    p_latitude, p_longitude, p_dentro_do_raio, p_distancia, p_foto_url, p_observacao
  )
  returning * into v_registo;

  return jsonb_build_object(
    'id',              v_registo.id,
    'tipo',            v_registo.tipo,
    'metodo',          v_registo.metodo,
    'timestamp',       v_registo."timestamp",
    'hora_local',      to_char(v_registo."timestamp" at time zone p_empresa.timezone, 'HH24:MI'),
    'dentro_do_raio',  v_registo.dentro_do_raio,
    'distancia_metros', v_registo.distancia_metros,
    'proximos_tipos',  to_jsonb(_proximos_tipos_validos(v_registo.tipo))
  );
end;
$$;

revoke all on function _registar_ponto(funcionarios, empresas, text, text, double precision, double precision, boolean, numeric, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Contexto do utilizador autenticado, validado.
-- São duas funções em vez de uma com dois OUT porque o plpgsql não
-- aceita mais do que uma variável composta numa lista INTO.
-- ---------------------------------------------------------------------
create or replace function _funcionario_atual()
returns funcionarios
language plpgsql
security definer
set search_path = public
as $$
declare
  f funcionarios;
begin
  select * into f from funcionarios where user_id = auth.uid() limit 1;

  if f.id is null then
    raise exception 'Utilizador não está associado a nenhum funcionário.'
      using errcode = 'P0001';
  end if;

  if not coalesce(f.ativo, false) then
    raise exception 'Conta de funcionário inactiva. Contacte o seu gestor.'
      using errcode = 'P0001';
  end if;

  return f;
end;
$$;

create or replace function _empresa_do_funcionario(p_empresa_id uuid)
returns empresas
language plpgsql
security definer
set search_path = public
as $$
declare
  e empresas;
begin
  select * into e from empresas where id = p_empresa_id;

  if e.id is null then
    raise exception 'Funcionário sem empresa associada.' using errcode = 'P0001';
  end if;

  return e;
end;
$$;

revoke all on function _funcionario_atual() from public, anon, authenticated;
revoke all on function _empresa_do_funcionario(uuid) from public, anon, authenticated;

-- =====================================================================
-- CHECK-IN POR QR CODE
-- =====================================================================
create or replace function registar_ponto_qrcode(
  p_token text,
  p_tipo text,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_foto_url text default null,
  p_observacao text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f funcionarios;
  e empresas;
  v_dentro boolean := null;
  v_dist numeric := null;
begin
  f := _funcionario_atual();
  e := _empresa_do_funcionario(f.empresa_id);

  if not e.metodo_qrcode_ativo then
    raise exception 'O check-in por QR code não está activo nesta empresa.'
      using errcode = 'P0001';
  end if;

  -- O token tem de pertencer à empresa DESTE funcionário: impede bater
  -- ponto lendo o QR code de outra empresa.
  if p_token is null or e.qr_code_token is null or p_token <> e.qr_code_token then
    raise exception 'QR code inválido ou de outra empresa.'
      using errcode = 'P0001';
  end if;

  -- A geolocalização é opcional aqui; se vier, é guardada como extra.
  if p_latitude is not null and p_longitude is not null
     and e.latitude is not null and e.longitude is not null then
    v_dist := round(haversine_metros(p_latitude, p_longitude, e.latitude, e.longitude)::numeric, 1);
    v_dentro := v_dist <= e.raio_metros;
  end if;

  return _registar_ponto(f, e, p_tipo, 'qrcode', p_latitude, p_longitude,
                         v_dentro, v_dist, p_foto_url, p_observacao);
end;
$$;

-- =====================================================================
-- CHECK-IN POR GEOLOCALIZAÇÃO
-- =====================================================================
create or replace function registar_ponto_gps(
  p_tipo text,
  p_latitude double precision,
  p_longitude double precision,
  p_foto_url text default null,
  p_observacao text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f funcionarios;
  e empresas;
  v_dist numeric;
  v_dentro boolean;
begin
  f := _funcionario_atual();
  e := _empresa_do_funcionario(f.empresa_id);

  if not e.metodo_gps_ativo then
    raise exception 'O check-in por geolocalização não está activo nesta empresa.'
      using errcode = 'P0001';
  end if;

  if p_latitude is null or p_longitude is null then
    raise exception 'Localização indisponível. Active o GPS e tente novamente.'
      using errcode = 'P0001';
  end if;

  if e.latitude is null or e.longitude is null then
    raise exception 'A empresa ainda não tem coordenadas definidas. Contacte o seu gestor.'
      using errcode = 'P0001';
  end if;

  if e.foto_obrigatoria and (p_foto_url is null or p_foto_url = '') then
    raise exception 'Esta empresa exige uma foto de confirmação no registo.'
      using errcode = 'P0001';
  end if;

  v_dist := round(haversine_metros(p_latitude, p_longitude, e.latitude, e.longitude)::numeric, 1);
  v_dentro := v_dist <= e.raio_metros;

  -- Fora do raio o registo é na mesma gravado, marcado a false, para o
  -- admin poder rever depois.
  return _registar_ponto(f, e, p_tipo, 'geolocalizacao', p_latitude, p_longitude,
                         v_dentro, v_dist, p_foto_url, p_observacao);
end;
$$;

-- =====================================================================
-- ESTADO ACTUAL DO FUNCIONÁRIO (ecrã Home da app)
-- =====================================================================
create or replace function meu_estado_atual()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f funcionarios;
  e empresas;
  v_ultimo registos_ponto;
  v_estado text;
begin
  f := _funcionario_atual();
  e := _empresa_do_funcionario(f.empresa_id);

  select * into v_ultimo
  from registos_ponto
  where funcionario_id = f.id
  order by "timestamp" desc
  limit 1;

  v_estado := case
    when v_ultimo.tipo is null or v_ultimo.tipo = 'saida' then 'fora'
    when v_ultimo.tipo = 'inicio_pausa' then 'pausa'
    else 'dentro'
  end;

  return jsonb_build_object(
    'funcionario', jsonb_build_object(
      'id', f.id, 'nome', f.nome, 'cargo', f.cargo,
      'foto_perfil_url', f.foto_perfil_url,
      'horas_semanais_esperadas', f.horas_semanais_esperadas
    ),
    'empresa', jsonb_build_object(
      'id', e.id, 'nome', e.nome, 'timezone', e.timezone,
      'raio_metros', e.raio_metros,
      'latitude', e.latitude, 'longitude', e.longitude,
      'metodo_qrcode_ativo', e.metodo_qrcode_ativo,
      'metodo_gps_ativo', e.metodo_gps_ativo,
      'foto_obrigatoria', e.foto_obrigatoria
    ),
    'estado', v_estado,
    'ultimo_registo', case when v_ultimo.id is null then null else jsonb_build_object(
      'id', v_ultimo.id,
      'tipo', v_ultimo.tipo,
      'metodo', v_ultimo.metodo,
      'timestamp', v_ultimo."timestamp",
      'hora_local', to_char(v_ultimo."timestamp" at time zone e.timezone, 'HH24:MI')
    ) end,
    'proximos_tipos', to_jsonb(_proximos_tipos_validos(v_ultimo.tipo))
  );
end;
$$;

-- =====================================================================
-- ADMIN — QR CODE DA EMPRESA
-- =====================================================================
create or replace function admin_obter_qr_token()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e empresas;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  select * into e from empresas where id = auth_empresa_id();

  return jsonb_build_object(
    'empresa_id', e.id,
    'nome', e.nome,
    'qr_code_token', e.qr_code_token,
    'atualizado_em', e.qr_token_atualizado_em
  );
end;
$$;

create or replace function admin_regenerar_qr_token()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
  v_empresa uuid;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  v_empresa := auth_empresa_id();
  v_token := gen_random_uuid()::text;

  -- Substituir o token invalida imediatamente todos os QR codes antigos.
  update empresas
     set qr_code_token = v_token,
         qr_token_atualizado_em = now()
   where id = v_empresa;

  return jsonb_build_object(
    'empresa_id', v_empresa,
    'qr_code_token', v_token,
    'atualizado_em', now()
  );
end;
$$;

-- =====================================================================
-- ADMIN — GESTÃO DE FUNCIONÁRIOS
-- =====================================================================
create or replace function admin_criar_funcionario(
  p_nome text,
  p_email text,
  p_cargo text default null,
  p_horas_semanais numeric default 40
)
returns funcionarios
language plpgsql
security definer
set search_path = public
as $$
declare
  v_func funcionarios;
  v_email text;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  if p_nome is null or btrim(p_nome) = '' then
    raise exception 'O nome é obrigatório.' using errcode = 'P0001';
  end if;

  -- Normalizar antes de validar: um espaço colado ou uma maiúscula não são
  -- motivo para recusar o email.
  v_email := lower(btrim(coalesce(p_email, '')));

  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Email inválido.' using errcode = 'P0001';
  end if;

  insert into funcionarios (empresa_id, nome, email, cargo, horas_semanais_esperadas)
  values (auth_empresa_id(), btrim(p_nome), v_email, p_cargo,
          coalesce(p_horas_semanais, 40))
  returning * into v_func;

  -- Se o utilizador já tiver conta Auth, liga-a de imediato.
  update funcionarios f
     set user_id = u.id
    from auth.users u
   where f.id = v_func.id
     and lower(u.email) = f.email
     and f.user_id is null;

  select * into v_func from funcionarios where id = v_func.id;
  return v_func;
end;
$$;

create or replace function admin_atualizar_funcionario(
  p_funcionario_id uuid,
  p_nome text default null,
  p_cargo text default null,
  p_horas_semanais numeric default null,
  p_ativo boolean default null
)
returns funcionarios
language plpgsql
security definer
set search_path = public
as $$
declare
  v_func funcionarios;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  update funcionarios
     set nome = coalesce(p_nome, nome),
         cargo = coalesce(p_cargo, cargo),
         horas_semanais_esperadas = coalesce(p_horas_semanais, horas_semanais_esperadas),
         ativo = coalesce(p_ativo, ativo)
   where id = p_funcionario_id
     and empresa_id = auth_empresa_id()
  returning * into v_func;

  if v_func.id is null then
    raise exception 'Funcionário não encontrado nesta empresa.' using errcode = 'P0001';
  end if;

  return v_func;
end;
$$;

-- Define o horário semanal completo de um funcionário.
-- p_horarios: [{"dia_semana":1,"hora_entrada":"09:00","hora_saida":"18:00"}, ...]
create or replace function admin_definir_horario(
  p_funcionario_id uuid,
  p_horarios jsonb
)
returns setof horarios_esperados
language plpgsql
security definer
set search_path = public
as $$
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

  delete from horarios_esperados where funcionario_id = p_funcionario_id;

  insert into horarios_esperados (funcionario_id, dia_semana, hora_entrada, hora_saida)
  select p_funcionario_id,
         (h->>'dia_semana')::integer,
         nullif(h->>'hora_entrada','')::time,
         nullif(h->>'hora_saida','')::time
  from jsonb_array_elements(coalesce(p_horarios, '[]'::jsonb)) h
  where nullif(h->>'hora_entrada','') is not null
    and nullif(h->>'hora_saida','') is not null;

  return query
    select * from horarios_esperados
    where funcionario_id = p_funcionario_id
    order by dia_semana;
end;
$$;

-- =====================================================================
-- ADMIN — JUSTIFICAÇÕES
-- =====================================================================
create or replace function admin_rever_justificacao(
  p_justificacao_id uuid,
  p_status text
)
returns faltas_justificacoes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_just faltas_justificacoes;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  if p_status not in ('aprovado','rejeitado','pendente') then
    raise exception 'Estado inválido: %', p_status using errcode = '22023';
  end if;

  update faltas_justificacoes j
     set status = p_status,
         revisto_por = auth.uid(),
         revisto_em = now()
    from funcionarios f
   where j.id = p_justificacao_id
     and f.id = j.funcionario_id
     and f.empresa_id = auth_empresa_id()
  returning j.* into v_just;

  if v_just.id is null then
    raise exception 'Justificação não encontrada nesta empresa.' using errcode = 'P0001';
  end if;

  return v_just;
end;
$$;

-- =====================================================================
-- ADMIN — DASHBOARD DO DIA
-- =====================================================================
create or replace function admin_dashboard_hoje()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_empresa_id uuid;
  v_tz text;
  v_hoje date;
  v_resultado jsonb;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  v_empresa_id := auth_empresa_id();
  select timezone into v_tz from empresas where id = v_empresa_id;
  v_hoje := (now() at time zone v_tz)::date;

  with ativos as (
    select * from funcionarios
    where empresa_id = v_empresa_id and ativo is true
  ),
  ultimo as (
    select distinct on (r.funcionario_id)
           r.funcionario_id, r.tipo, r."timestamp", r.metodo, r.dentro_do_raio
    from registos_ponto r
    join ativos a on a.id = r.funcionario_id
    order by r.funcionario_id, r."timestamp" desc
  ),
  primeira_entrada as (
    select r.funcionario_id, min(r."timestamp") as ts
    from registos_ponto r
    join ativos a on a.id = r.funcionario_id
    where r.tipo = 'entrada'
      and (r."timestamp" at time zone v_tz)::date = v_hoje
    group by r.funcionario_id
  ),
  detalhe as (
    select
      a.id,
      a.nome,
      a.cargo,
      a.foto_perfil_url,
      case
        when u.tipo is null or u.tipo = 'saida' then 'fora'
        when u.tipo = 'inicio_pausa' then 'pausa'
        else 'dentro'
      end as estado,
      u."timestamp" as ultimo_registo,
      to_char(u."timestamp" at time zone v_tz, 'HH24:MI') as ultimo_registo_hora,
      pe.ts as entrada_hoje,
      to_char(pe.ts at time zone v_tz, 'HH24:MI') as entrada_hoje_hora,
      h.hora_entrada as hora_entrada_esperada,
      case
        when pe.ts is not null and h.hora_entrada is not null
          then greatest(0, round(extract(epoch from (
                 (pe.ts at time zone v_tz)::time - h.hora_entrada
               )) / 60)::int)
        else null
      end as atraso_minutos
    from ativos a
    left join ultimo u on u.funcionario_id = a.id
    left join primeira_entrada pe on pe.funcionario_id = a.id
    left join horarios_esperados h
           on h.funcionario_id = a.id
          and h.dia_semana = extract(dow from v_hoje)::int
  )
  select jsonb_build_object(
    'data', v_hoje,
    'timezone', v_tz,
    'total_ativos', (select count(*) from ativos),
    'dentro', (select count(*) from detalhe where estado = 'dentro'),
    'em_pausa', (select count(*) from detalhe where estado = 'pausa'),
    'fora', (select count(*) from detalhe where estado = 'fora'),
    'atrasos', (select count(*) from detalhe where coalesce(atraso_minutos, 0) > 0),
    'ausentes_com_horario', (
      select count(*) from detalhe
      where entrada_hoje is null and hora_entrada_esperada is not null
    ),
    'registos_fora_do_raio', (
      select count(*) from registos_ponto
      where empresa_id = v_empresa_id
        and dentro_do_raio is false
        and ("timestamp" at time zone v_tz)::date = v_hoje
    ),
    'justificacoes_pendentes', (
      select count(*) from faltas_justificacoes j
      join funcionarios f on f.id = j.funcionario_id
      where f.empresa_id = v_empresa_id and j.status = 'pendente'
    ),
    'funcionarios', coalesce(
      (select jsonb_agg(to_jsonb(d) order by d.estado, d.nome) from detalhe d),
      '[]'::jsonb
    )
  ) into v_resultado;

  return v_resultado;
end;
$$;

-- ---------------------------------------------------------------------
-- Duração de um turno, em horas
-- ---------------------------------------------------------------------
-- Um turno da noite (18:00 → 02:00) tem a hora de saída menor do que a de
-- entrada. Subtrair directamente dava -16 h em vez de 8 — e essas horas
-- negativas iam parar ao banco de horas como dívida.
create or replace function _duracao_turno(p_entrada time, p_saida time)
returns numeric
language sql
immutable
as $$
  select round(
    (
      extract(epoch from (p_saida - p_entrada))
      -- Saída menor ou igual à entrada = o turno passa a meia-noite.
      + case when p_saida <= p_entrada then 86400 else 0 end
    ) / 3600.0
  , 2);
$$;

revoke all on function _duracao_turno(time, time) from public, anon;
grant execute on function _duracao_turno(time, time) to authenticated;

-- =====================================================================
-- CÁLCULO DE HORAS DE UM PERÍODO
-- =====================================================================
-- Fonte única de verdade para "quantas horas é que esta pessoa fez".
-- É usada pelo relatório mensal e pelo fecho do banco de horas, para que
-- os dois nunca possam divergir.
--
-- Tempo de trabalho = intervalos que começam numa 'entrada' ou num
-- 'fim_pausa' e terminam no evento seguinte. As pausas ficam de fora.
create or replace function _horas_do_periodo(
  p_empresa_id uuid,
  p_inicio date,
  p_fim date,          -- exclusivo
  p_tz text
)
returns table (
  funcionario_id uuid,
  horas_trabalhadas numeric,
  horas_esperadas numeric,
  dias_com_entrada integer,
  dias_sem_registo_nem_justificacao integer
)
language sql
stable
security definer
set search_path = public
as $$
  with func as (
    select * from funcionarios where empresa_id = p_empresa_id
  ),
  ord as (
    select
      r.funcionario_id,
      r.tipo,
      r."timestamp",
      lead(r."timestamp") over (
        partition by r.funcionario_id order by r."timestamp"
      ) as proximo
    from registos_ponto r
    join func f on f.id = r.funcionario_id
    where (r."timestamp" at time zone p_tz)::date >= p_inicio
      and (r."timestamp" at time zone p_tz)::date <  p_fim
  ),
  trabalhado as (
    select o.funcionario_id, sum(extract(epoch from (o.proximo - o."timestamp")) / 3600.0) as horas
    from ord o
    where o.tipo in ('entrada','fim_pausa') and o.proximo is not null
    group by o.funcionario_id
  ),
  entradas as (
    select o.funcionario_id, count(*)::int as dias
    from ord o
    where o.tipo = 'entrada'
    group by o.funcionario_id
  ),
  dias as (
    select d::date as dia, extract(dow from d)::int as dow
    from generate_series(p_inicio, p_fim - 1, interval '1 day') d
  ),
  -- Um dia esperado por cada dia do período em que o funcionário tem
  -- horário definido para aquele dia da semana.
  esperado_dia as (
    select
      h.funcionario_id,
      dias.dia,
      _duracao_turno(h.hora_entrada, h.hora_saida) as horas
    from dias
    join horarios_esperados h on h.dia_semana = dias.dow
    join func f on f.id = h.funcionario_id
    where h.hora_entrada is not null and h.hora_saida is not null
  ),
  esperado as (
    select e.funcionario_id, sum(e.horas) as horas
    from esperado_dia e
    group by e.funcionario_id
  ),
  -- Falta a sério: dia com horário, sem qualquer registo, e sem pedido
  -- de justificação por decidir ou aprovado. Um saldo negativo por si só
  -- não é falta — é apenas dívida de horas.
  faltas as (
    select e.funcionario_id, count(*)::int as dias
    from esperado_dia e
    where not exists (
      select 1 from registos_ponto r
      where r.funcionario_id = e.funcionario_id
        and (r."timestamp" at time zone p_tz)::date = e.dia
    )
    and not exists (
      select 1 from faltas_justificacoes j
      where j.funcionario_id = e.funcionario_id
        and j.data = e.dia
        and j.status <> 'rejeitado'
    )
    group by e.funcionario_id
  )
  select
    f.id,
    round(coalesce(t.horas, 0)::numeric, 2),
    round(coalesce(
      e.horas,
      -- Sem horário definido, estima-se a partir das horas semanais.
      f.horas_semanais_esperadas * ((p_fim - p_inicio) / 7.0)
    )::numeric, 2),
    coalesce(en.dias, 0),
    coalesce(fa.dias, 0)
  from func f
  left join trabalhado t on t.funcionario_id = f.id
  left join esperado e   on e.funcionario_id = f.id
  left join entradas en  on en.funcionario_id = f.id
  left join faltas fa    on fa.funcionario_id = f.id;
$$;

revoke all on function _horas_do_periodo(uuid, date, date, text) from public, anon, authenticated;

-- =====================================================================
-- ADMIN — RELATÓRIO MENSAL (horas trabalhadas vs. esperadas)
-- =====================================================================
create or replace function admin_relatorio_mensal(p_ano int, p_mes int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_empresa_id uuid;
  v_tz text;
  v_politica text;
  v_inicio date;
  v_fim date;
  v_resultado jsonb;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  if p_mes < 1 or p_mes > 12 then
    raise exception 'Mês inválido: %', p_mes using errcode = '22023';
  end if;

  v_empresa_id := auth_empresa_id();
  select timezone, politica_banco_horas into v_tz, v_politica
  from empresas where id = v_empresa_id;

  v_inicio := make_date(p_ano, p_mes, 1);
  v_fim := (v_inicio + interval '1 month')::date;

  with horas as (
    select * from _horas_do_periodo(v_empresa_id, v_inicio, v_fim, v_tz)
  ),
  faltas as (
    select j.funcionario_id,
           count(*) filter (where j.status = 'aprovado') as justificadas,
           count(*) filter (where j.status = 'pendente') as pendentes
    from faltas_justificacoes j
    join funcionarios f on f.id = j.funcionario_id
    where f.empresa_id = v_empresa_id
      and j.data >= v_inicio and j.data < v_fim
    group by j.funcionario_id
  ),
  linhas as (
    select
      f.id as funcionario_id,
      f.nome,
      f.email,
      f.cargo,
      f.ativo,
      h.horas_trabalhadas,
      h.horas_esperadas,
      round((h.horas_trabalhadas - h.horas_esperadas)::numeric, 2) as saldo_horas,
      h.dias_com_entrada,
      h.dias_sem_registo_nem_justificacao,
      coalesce(fa.justificadas, 0) as faltas_justificadas,
      coalesce(fa.pendentes, 0) as faltas_pendentes,
      -- Saldo acumulado do banco de horas, para lá deste mês
      round(f.saldo_banco_horas::numeric, 2) as saldo_banco_horas
    from funcionarios f
    join horas h on h.funcionario_id = f.id
    left join faltas fa on fa.funcionario_id = f.id
  )
  select jsonb_build_object(
    'ano', p_ano,
    'mes', p_mes,
    'inicio', v_inicio,
    'fim', v_fim - 1,
    'timezone', v_tz,
    'politica_banco_horas', v_politica,
    'total_horas_trabalhadas', (select round(coalesce(sum(horas_trabalhadas),0), 2) from linhas),
    'total_horas_esperadas', (select round(coalesce(sum(horas_esperadas),0), 2) from linhas),
    'total_saldo_banco_horas', (select round(coalesce(sum(saldo_banco_horas),0), 2) from linhas),
    'linhas', coalesce((select jsonb_agg(to_jsonb(l) order by l.nome) from linhas l), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$$;

-- =====================================================================
-- GRANTS
-- =====================================================================
revoke all on function registar_ponto_qrcode(text, text, double precision, double precision, text, text) from public, anon;
revoke all on function registar_ponto_gps(text, double precision, double precision, text, text) from public, anon;
revoke all on function meu_estado_atual() from public, anon;
revoke all on function admin_obter_qr_token() from public, anon;
revoke all on function admin_regenerar_qr_token() from public, anon;
revoke all on function admin_criar_funcionario(text, text, text, numeric) from public, anon;
revoke all on function admin_atualizar_funcionario(uuid, text, text, numeric, boolean) from public, anon;
revoke all on function admin_definir_horario(uuid, jsonb) from public, anon;
revoke all on function admin_rever_justificacao(uuid, text) from public, anon;
revoke all on function admin_dashboard_hoje() from public, anon;
revoke all on function admin_relatorio_mensal(int, int) from public, anon;

grant execute on function registar_ponto_qrcode(text, text, double precision, double precision, text, text) to authenticated;
grant execute on function registar_ponto_gps(text, double precision, double precision, text, text) to authenticated;
grant execute on function meu_estado_atual() to authenticated;
grant execute on function admin_obter_qr_token() to authenticated;
grant execute on function admin_regenerar_qr_token() to authenticated;
grant execute on function admin_criar_funcionario(text, text, text, numeric) to authenticated;
grant execute on function admin_atualizar_funcionario(uuid, text, text, numeric, boolean) to authenticated;
grant execute on function admin_definir_horario(uuid, jsonb) to authenticated;
grant execute on function admin_rever_justificacao(uuid, text) to authenticated;
grant execute on function admin_dashboard_hoje() to authenticated;
grant execute on function admin_relatorio_mensal(int, int) to authenticated;
