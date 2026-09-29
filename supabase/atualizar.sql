-- =====================================================================
-- Salinas — actualização do projecto Supabase
-- =====================================================================
-- GERADO por tools/gerar-atualizacao.sh — não editar à mão.
-- Como usar: Supabase → SQL Editor → colar tudo → Run.
-- Pode correr mais do que uma vez; não apaga dados.
-- =====================================================================

begin;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 01_schema.sql
-- =====================================================================
-- Salinas — Registo de Ponto
-- 01_schema.sql — Tabelas, tipos, índices e triggers
-- =====================================================================
-- Executar por ordem: 01_schema → 02_rls → 03_functions → 04_storage → 05_seed
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- Empresas
-- ---------------------------------------------------------------------
create table if not exists empresas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  morada text,
  latitude double precision,
  longitude double precision,
  raio_metros integer default 100 check (raio_metros > 0),
  qr_code_token text unique default gen_random_uuid()::text,
  -- Métodos de check-in activos (o admin escolhe um ou ambos)
  metodo_qrcode_ativo boolean not null default true,
  metodo_gps_ativo boolean not null default true,
  -- Foto de confirmação de identidade no check-in por GPS
  foto_obrigatoria boolean not null default false,
  timezone text not null default 'Europe/Lisbon',
  qr_token_atualizado_em timestamptz default now(),
  -- Política de banco de horas (ver 06_banco_horas.sql)
  politica_banco_horas text not null default 'apenas_reportar'
    check (politica_banco_horas in
      ('apenas_reportar','compensar_folga','desconto_automatico','pagar_extra')),
  -- Em Portugal o prazo de compensação vai tipicamente até 12 meses.
  limite_compensacao_meses integer not null default 12
    check (limite_compensacao_meses between 1 and 60),
  -- Como se sabe que um dia foi folga (ver _horas_do_periodo em 03_functions.sql)
  regime_folgas text not null default 'fixo'
    check (regime_folgas in ('fixo','rotativo')),
  -- A entrada exige o QR code (prova que a pessoa está na loja); o GPS
  -- fica para a saída e as pausas. Resolve quem mora perto do trabalho:
  -- estar "dentro do raio" em casa deixa de chegar para entrar ao serviço.
  gps_so_saida boolean not null default false,
  created_at timestamptz default now()
);

-- Colunas acrescentadas depois da primeira instalação. O ficheiro é para
-- poder correr outra vez sobre uma base já criada, e o `create table if
-- not exists` acima não acrescenta colunas novas a uma tabela existente.
alter table empresas
  add column if not exists regime_folgas text not null default 'fixo';
alter table empresas
  add column if not exists gps_so_saida boolean not null default false;
do $$
begin
  alter table empresas add constraint empresas_regime_folgas_check
    check (regime_folgas in ('fixo','rotativo'));
exception when duplicate_object then null;
end $$;

comment on column empresas.qr_code_token is
  'Token secreto do QR code da empresa. Nunca exposto a funcionários (ver grants em 02_rls.sql).';

comment on column empresas.regime_folgas is
  'fixo = o horário semanal define as folgas (dia sem horário = folga). '
  'rotativo = escala 6x2 ou parecida, em que as folgas mudam de semana para '
  'semana: um dia sem qualquer registo e sem justificação é folga, não é falta.';

-- ---------------------------------------------------------------------
-- Funcionários
-- ---------------------------------------------------------------------
create table if not exists funcionarios (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid references empresas(id) on delete cascade,
  -- Ligação à conta Supabase Auth. Nulo enquanto o funcionário não activar a conta.
  user_id uuid unique references auth.users(id) on delete set null,
  nome text not null,
  email text unique not null,
  cargo text,
  foto_perfil_url text,
  horas_semanais_esperadas numeric default 40 check (horas_semanais_esperadas >= 0),
  -- Saldo acumulado do banco de horas, em horas decimais. Nunca é escrito
  -- à mão: é sempre recalculado a partir de banco_horas_movimentos pela
  -- função _recalcular_saldo_banco_horas() (06_banco_horas.sql).
  saldo_banco_horas numeric not null default 0,
  ativo boolean default true,
  created_at timestamptz default now()
);

create index if not exists idx_funcionarios_empresa on funcionarios(empresa_id);
create index if not exists idx_funcionarios_user on funcionarios(user_id);
create index if not exists idx_funcionarios_email on funcionarios(lower(email));

-- ---------------------------------------------------------------------
-- Administradores de empresa
-- ---------------------------------------------------------------------
create table if not exists admins (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  -- Nulo enquanto o admin não activar a conta (é ligado por email no signup)
  user_id uuid unique references auth.users(id) on delete cascade,
  nome text,
  email text not null,
  created_at timestamptz default now()
);

create index if not exists idx_admins_empresa on admins(empresa_id);

-- ---------------------------------------------------------------------
-- Registos de ponto
-- ---------------------------------------------------------------------
create table if not exists registos_ponto (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid references funcionarios(id) on delete cascade,
  empresa_id uuid references empresas(id) on delete cascade,
  tipo text check (tipo in ('entrada','saida','inicio_pausa','fim_pausa')) not null,
  metodo text check (metodo in ('qrcode','geolocalizacao','manual')) not null,
  timestamp timestamptz default now(),
  latitude double precision,
  longitude double precision,
  dentro_do_raio boolean,
  distancia_metros numeric,
  foto_url text,
  observacao text
);

create index if not exists idx_registos_funcionario_ts
  on registos_ponto(funcionario_id, "timestamp" desc);
create index if not exists idx_registos_empresa_ts
  on registos_ponto(empresa_id, "timestamp" desc);

-- ---------------------------------------------------------------------
-- Horários esperados (por funcionário, por dia da semana)
-- dia_semana: 0 = domingo ... 6 = sábado (compatível com EXTRACT(DOW))
-- ---------------------------------------------------------------------
create table if not exists horarios_esperados (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid references funcionarios(id) on delete cascade,
  dia_semana integer check (dia_semana between 0 and 6),
  hora_entrada time,
  hora_saida time,
  unique (funcionario_id, dia_semana)
);

create index if not exists idx_horarios_funcionario on horarios_esperados(funcionario_id);

-- ---------------------------------------------------------------------
-- Justificações de falta / atraso
-- ---------------------------------------------------------------------
create table if not exists faltas_justificacoes (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid references funcionarios(id) on delete cascade,
  data date not null,
  motivo text,
  status text check (status in ('pendente','aprovado','rejeitado')) default 'pendente',
  anexo_url text,
  revisto_por uuid references auth.users(id) on delete set null,
  revisto_em timestamptz,
  created_at timestamptz default now()
);

create index if not exists idx_faltas_funcionario on faltas_justificacoes(funcionario_id, data desc);

-- ---------------------------------------------------------------------
-- Banco de horas — movimentos por período
-- ---------------------------------------------------------------------
-- Conta corrente de horas: cada linha fecha um período (normalmente um
-- mês) e guarda o que foi trabalhado, o que era esperado e a diferença.
--
-- Enquanto o `status` é 'aberto', o saldo conta para o acumulado do
-- funcionário. Passar a 'compensado', 'pago' ou 'descontado' liquida o
-- movimento e tira-o do acumulado, deixando o histórico intacto.
create table if not exists banco_horas_movimentos (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid references funcionarios(id) on delete cascade,
  -- Primeiro dia do período a que o movimento se refere
  periodo_referencia date not null,
  horas_trabalhadas numeric not null,
  horas_esperadas numeric not null,
  -- horas_trabalhadas - horas_esperadas (negativo = dívida de horas)
  saldo numeric not null,
  status text check (status in ('aberto','compensado','pago','descontado')) default 'aberto',
  observacao text,
  -- Movimentos manuais (compensações, pagamentos) não vêm do fecho do mês
  -- e por isso não são substituídos quando um período é refechado.
  manual boolean not null default false,
  revisto_por uuid references auth.users(id) on delete set null,
  created_at timestamptz default now()
);

-- Um único movimento automático por funcionário e período; os manuais
-- podem ser vários (várias compensações no mesmo mês).
create unique index if not exists idx_banco_horas_periodo_automatico
  on banco_horas_movimentos (funcionario_id, periodo_referencia)
  where manual is false;

create index if not exists idx_banco_horas_funcionario
  on banco_horas_movimentos (funcionario_id, periodo_referencia desc);

-- ---------------------------------------------------------------------
-- Trigger: preenche empresa_id do registo a partir do funcionário
-- (defesa em profundidade — o RPC já o faz, isto impede divergências)
-- ---------------------------------------------------------------------
create or replace function trg_registos_empresa_id()
returns trigger
language plpgsql
as $$
begin
  select empresa_id into new.empresa_id
  from funcionarios
  where id = new.funcionario_id;
  return new;
end;
$$;

-- O Postgres dá EXECUTE ao público por omissão. Uma função de trigger não
-- é chamável directamente, mas deixar a permissão aberta faz com que, no
-- dia em que alguém a converta em função normal, ela fique exposta sem
-- ninguém reparar.
revoke all on function trg_registos_empresa_id() from public, anon, authenticated;

drop trigger if exists set_empresa_id on registos_ponto;
create trigger set_empresa_id
  before insert or update of funcionario_id on registos_ponto
  for each row execute function trg_registos_empresa_id();

-- ---------------------------------------------------------------------
-- Trigger: liga automaticamente auth.users → funcionarios/admins por email
-- Permite convidar o funcionário antes de ele criar a conta.
-- ---------------------------------------------------------------------
create or replace function trg_ligar_conta_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update funcionarios
     set user_id = new.id
   where lower(email) = lower(new.email)
     and user_id is null;

  update admins
     set user_id = new.id
   where lower(email) = lower(new.email)
     and user_id is null;

  return new;
end;
$$;

-- Esta é SECURITY DEFINER: corre com os privilégios do dono. Fechar a
-- permissão é defesa em profundidade.
revoke all on function trg_ligar_conta_auth() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function trg_ligar_conta_auth();

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 02_rls.sql
-- =====================================================================
-- Salinas — Registo de Ponto
-- 02_rls.sql — Row Level Security, helpers de identidade e grants
-- =====================================================================
-- Princípio: nenhuma tabela é exposta sem policy. Cada funcionário vê
-- apenas os seus próprios dados; o admin vê tudo o que pertence ao seu
-- empresa_id. Escritas sensíveis passam por RPC SECURITY DEFINER (03).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helpers de identidade
-- SECURITY DEFINER para evitar recursão infinita: as policies de
-- `funcionarios` chamam estas funções, que por sua vez lêem `funcionarios`.
-- ---------------------------------------------------------------------
create or replace function auth_funcionario_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from funcionarios where user_id = auth.uid() limit 1;
$$;

create or replace function auth_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

-- empresa_id do utilizador autenticado, seja ele admin ou funcionário
create or replace function auth_empresa_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select empresa_id from admins where user_id = auth.uid() limit 1),
    (select empresa_id from funcionarios where user_id = auth.uid() limit 1)
  );
$$;

revoke all on function auth_funcionario_id() from public;
revoke all on function auth_is_admin() from public;
revoke all on function auth_empresa_id() from public;
grant execute on function auth_funcionario_id() to authenticated;
grant execute on function auth_is_admin() to authenticated;
grant execute on function auth_empresa_id() to authenticated;

-- ---------------------------------------------------------------------
-- Activar RLS em todas as tabelas
-- ---------------------------------------------------------------------
alter table empresas             enable row level security;
alter table funcionarios         enable row level security;
alter table admins               enable row level security;
alter table registos_ponto       enable row level security;
alter table horarios_esperados   enable row level security;
alter table faltas_justificacoes enable row level security;
alter table banco_horas_movimentos enable row level security;

-- =====================================================================
-- EMPRESAS
-- =====================================================================
drop policy if exists empresas_select on empresas;
create policy empresas_select on empresas
  for select to authenticated
  using (id = auth_empresa_id());

drop policy if exists empresas_update_admin on empresas;
create policy empresas_update_admin on empresas
  for update to authenticated
  using (id = auth_empresa_id() and auth_is_admin())
  with check (id = auth_empresa_id() and auth_is_admin());

-- Grants ao nível da coluna: `qr_code_token` NUNCA é legível via API.
-- Só o admin lhe acede através do RPC admin_obter_qr_token() (03_functions.sql).
revoke all on empresas from authenticated, anon;
grant select (
  id, nome, morada, latitude, longitude, raio_metros,
  metodo_qrcode_ativo, metodo_gps_ativo, foto_obrigatoria,
  timezone, qr_token_atualizado_em, created_at,
  politica_banco_horas, limite_compensacao_meses, regime_folgas, gps_so_saida
) on empresas to authenticated;
grant update (
  nome, morada, latitude, longitude, raio_metros,
  metodo_qrcode_ativo, metodo_gps_ativo, foto_obrigatoria, timezone,
  politica_banco_horas, limite_compensacao_meses, regime_folgas, gps_so_saida
) on empresas to authenticated;

-- =====================================================================
-- FUNCIONÁRIOS
-- =====================================================================
drop policy if exists funcionarios_select on funcionarios;
create policy funcionarios_select on funcionarios
  for select to authenticated
  using (
    user_id = auth.uid()
    or (empresa_id = auth_empresa_id() and auth_is_admin())
  );

-- O funcionário pode editar o seu perfil; o admin gere toda a empresa.
drop policy if exists funcionarios_update on funcionarios;
create policy funcionarios_update on funcionarios
  for update to authenticated
  using (
    user_id = auth.uid()
    or (empresa_id = auth_empresa_id() and auth_is_admin())
  )
  with check (
    user_id = auth.uid()
    or (empresa_id = auth_empresa_id() and auth_is_admin())
  );

drop policy if exists funcionarios_insert_admin on funcionarios;
create policy funcionarios_insert_admin on funcionarios
  for insert to authenticated
  with check (empresa_id = auth_empresa_id() and auth_is_admin());

drop policy if exists funcionarios_delete_admin on funcionarios;
create policy funcionarios_delete_admin on funcionarios
  for delete to authenticated
  using (empresa_id = auth_empresa_id() and auth_is_admin());

-- O funcionário não pode mudar de empresa, auto-promover-se nem
-- reatribuir a conta: essas colunas ficam fora do grant de UPDATE.
revoke all on funcionarios from authenticated, anon;
grant select on funcionarios to authenticated;
grant insert on funcionarios to authenticated;
grant delete on funcionarios to authenticated;
grant update (nome, cargo, foto_perfil_url) on funcionarios to authenticated;

-- Colunas de gestão: apenas via RPC de admin (03_functions.sql).

-- =====================================================================
-- ADMINS
-- =====================================================================
drop policy if exists admins_select on admins;
create policy admins_select on admins
  for select to authenticated
  using (user_id = auth.uid() or (empresa_id = auth_empresa_id() and auth_is_admin()));

revoke all on admins from authenticated, anon;
grant select on admins to authenticated;

-- =====================================================================
-- REGISTOS DE PONTO
-- =====================================================================
drop policy if exists registos_select on registos_ponto;
create policy registos_select on registos_ponto
  for select to authenticated
  using (
    funcionario_id = auth_funcionario_id()
    or (empresa_id = auth_empresa_id() and auth_is_admin())
  );

-- INSERT/UPDATE/DELETE só por RPC SECURITY DEFINER — as regras de negócio
-- (sequência entrada/saída, validação de token, raio) não podem ser
-- contornadas pelo cliente.
revoke all on registos_ponto from authenticated, anon;
grant select on registos_ponto to authenticated;

-- =====================================================================
-- HORÁRIOS ESPERADOS
-- =====================================================================
drop policy if exists horarios_select on horarios_esperados;
create policy horarios_select on horarios_esperados
  for select to authenticated
  using (
    funcionario_id = auth_funcionario_id()
    or exists (
      select 1 from funcionarios f
      where f.id = horarios_esperados.funcionario_id
        and f.empresa_id = auth_empresa_id()
        and auth_is_admin()
    )
  );

drop policy if exists horarios_write_admin on horarios_esperados;
create policy horarios_write_admin on horarios_esperados
  for all to authenticated
  using (
    exists (
      select 1 from funcionarios f
      where f.id = horarios_esperados.funcionario_id
        and f.empresa_id = auth_empresa_id()
        and auth_is_admin()
    )
  )
  with check (
    exists (
      select 1 from funcionarios f
      where f.id = horarios_esperados.funcionario_id
        and f.empresa_id = auth_empresa_id()
        and auth_is_admin()
    )
  );

revoke all on horarios_esperados from authenticated, anon;
grant select, insert, update, delete on horarios_esperados to authenticated;

-- =====================================================================
-- FALTAS / JUSTIFICAÇÕES
-- =====================================================================
drop policy if exists faltas_select on faltas_justificacoes;
create policy faltas_select on faltas_justificacoes
  for select to authenticated
  using (
    funcionario_id = auth_funcionario_id()
    or exists (
      select 1 from funcionarios f
      where f.id = faltas_justificacoes.funcionario_id
        and f.empresa_id = auth_empresa_id()
        and auth_is_admin()
    )
  );

-- O funcionário submete pedidos apenas para si próprio e sempre em 'pendente'.
drop policy if exists faltas_insert_proprio on faltas_justificacoes;
create policy faltas_insert_proprio on faltas_justificacoes
  for insert to authenticated
  with check (funcionario_id = auth_funcionario_id() and status = 'pendente');

-- Aprovar/rejeitar é feito pelo RPC admin_rever_justificacao().
revoke all on faltas_justificacoes from authenticated, anon;
grant select on faltas_justificacoes to authenticated;
grant insert (funcionario_id, data, motivo, status, anexo_url) on faltas_justificacoes to authenticated;

-- =====================================================================
-- BANCO DE HORAS
-- =====================================================================
drop policy if exists banco_horas_select on banco_horas_movimentos;
create policy banco_horas_select on banco_horas_movimentos
  for select to authenticated
  using (
    funcionario_id = auth_funcionario_id()
    or exists (
      select 1 from funcionarios f
      where f.id = banco_horas_movimentos.funcionario_id
        and f.empresa_id = auth_empresa_id()
        and auth_is_admin()
    )
  );

-- Só de leitura pela API. Fechar períodos, compensar e pagar passa pelos
-- RPC de 06_banco_horas.sql, que recalculam o saldo acumulado — deixar
-- escrever à mão aqui daria saldos que não batem certo com o histórico.
revoke all on banco_horas_movimentos from authenticated, anon;
grant select on banco_horas_movimentos to authenticated;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 03_functions.sql
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

  -- Com o QR code activo, a entrada tem de ser feita na loja. Só com GPS,
  -- quem mora dentro do raio podia entrar ao serviço sem sair de casa.
  if p_tipo = 'entrada' and e.gps_so_saida and e.metodo_qrcode_ativo then
    raise exception 'A entrada faz-se com o QR code da loja. O GPS serve para a saída e as pausas.'
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
      'gps_so_saida', e.gps_so_saida,
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
  v_regime text;
  v_hoje date;
  v_resultado jsonb;
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  v_empresa_id := auth_empresa_id();
  select timezone, regime_folgas into v_tz, v_regime
  from empresas where id = v_empresa_id;
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
    -- Em regime rotativo, quem não bateu ponto hoje pode estar de folga —
    -- o painel muda o rótulo em vez de lhe chamar ausência.
    'regime_folgas', v_regime,
    'total_ativos', (select count(*) from ativos),
    'dentro', (select count(*) from detalhe where estado = 'dentro'),
    'em_pausa', (select count(*) from detalhe where estado = 'pausa'),
    'fora', (select count(*) from detalhe where estado = 'fora'),
    'atrasos', (select count(*) from detalhe where coalesce(atraso_minutos, 0) > 0),
    'ausentes_com_horario', (
      -- Quem ainda está no turno da noite de ontem não é ausente, e quem
      -- só começa mais logo ainda não faltou a nada.
      select count(*) from detalhe
      where entrada_hoje is null
        and estado = 'fora'
        and hora_entrada_esperada is not null
        and hora_entrada_esperada <= (now() at time zone v_tz)::time
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
--
-- Folgas, conforme `empresas.regime_folgas`:
--
--   'fixo'      — a folga é o dia da semana sem horário definido. Um dia
--                 com horário e sem ponto é falta.
--   'rotativo'  — escala 6x2 e afins: as folgas mudam de semana para
--                 semana, por isso não há como as ter no horário semanal.
--                 A regra passa a ser a do Anderson: **o dia sem ponto é o
--                 dia de folga**. Não conta horas esperadas nem falta, e
--                 por isso também não gera dívida no banco de horas. Um dia
--                 com justificação (doença, férias) continua a contar como
--                 dia de trabalho previsto — a justificação prova que não
--                 era folga.
--
-- Sai `dias_folga` para o relatório poder dizer quantos dias de descanso a
-- pessoa teve, em vez de os apresentar como ausências.
--
-- Um dia "foi trabalhado" quando tem uma **entrada**. Não basta ter um
-- registo qualquer: o turno da noite deixa a saída das 02:00 no dia
-- seguinte, e esse dia seguinte pode muito bem ser folga.
--
-- Um turno conta inteiro no dia (e no mês) em que começou, mesmo que a
-- saída caia no mês seguinte.
--
-- Num período que ainda está a decorrer só contam os dias que já
-- terminaram. Hoje só conta se já houve entrada — antes disso não é falta,
-- nem folga, nem horas em dívida: o dia ainda não acabou.
drop function if exists _horas_do_periodo(uuid, date, date, text);
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
  dias_sem_registo_nem_justificacao integer,
  dias_folga integer
)
language sql
stable
security definer
set search_path = public
as $$
  with regime as (
    select coalesce(regime_folgas, 'fixo') as modo
    from empresas where id = p_empresa_id
  ),
  func as (
    select * from funcionarios where empresa_id = p_empresa_id
  ),
  hoje as (
    select (now() at time zone p_tz)::date as dia
  ),
  -- O evento seguinte é procurado também um pouco para lá do fim do
  -- período, para o turno que atravessa a meia-noite do último dia.
  ord_janela as (
    select
      r.funcionario_id,
      r.tipo,
      r."timestamp",
      lead(r."timestamp") over (
        partition by r.funcionario_id order by r."timestamp"
      ) as proximo
    from registos_ponto r
    join func f on f.id = r.funcionario_id
    where r."timestamp" >= ((p_inicio - 1)::timestamp at time zone p_tz)
      and r."timestamp" <  ((p_fim + 2)::timestamp at time zone p_tz)
  ),
  ord as (
    select * from ord_janela o
    where (o."timestamp" at time zone p_tz)::date >= p_inicio
      and (o."timestamp" at time zone p_tz)::date <  p_fim
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
    from hoje, generate_series(p_inicio, least(p_fim - 1, hoje.dia), interval '1 day') d
  ),
  -- Um dia esperado por cada dia do período em que o funcionário tem
  -- horário definido para aquele dia da semana.
  previsto_dia_todos as (
    select
      h.funcionario_id,
      dias.dia,
      _duracao_turno(h.hora_entrada, h.hora_saida) as horas,
      exists (
        select 1 from registos_ponto r
        where r.funcionario_id = h.funcionario_id
          and r.tipo = 'entrada'
          and (r."timestamp" at time zone p_tz)::date = dias.dia
      ) as tem_registo,
      exists (
        select 1 from faltas_justificacoes j
        where j.funcionario_id = h.funcionario_id
          and j.data = dias.dia
          and j.status <> 'rejeitado'
      ) as tem_justificacao
    from dias
    join horarios_esperados h on h.dia_semana = dias.dow
    join func f on f.id = h.funcionario_id
    where h.hora_entrada is not null and h.hora_saida is not null
  ),
  previsto_dia as (
    select p.* from previsto_dia_todos p, hoje
    where p.dia < hoje.dia or p.tem_registo
  ),
  -- Em regime rotativo, o dia sem ponto e sem justificação é folga: sai
  -- de cena por completo, não conta horas nem falta.
  esperado_dia as (
    select p.*
    from previsto_dia p, regime
    where regime.modo <> 'rotativo'
       or p.tem_registo
       or p.tem_justificacao
  ),
  folgas as (
    select p.funcionario_id, count(*)::int as dias
    from previsto_dia p, regime
    where regime.modo = 'rotativo'
      and not p.tem_registo
      and not p.tem_justificacao
    group by p.funcionario_id
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
    where not e.tem_registo and not e.tem_justificacao
    group by e.funcionario_id
  ),
  -- Ter horário definido é diferente de ter horas previstas no período:
  -- em regime rotativo, quem tem horário mas esteve de folga o mês
  -- inteiro tem zero horas previstas — não é caso de estimar pelas horas
  -- semanais, senão apareciam horas em dívida que ninguém devia.
  com_horario as (
    select distinct h.funcionario_id
    from horarios_esperados h
    join func f on f.id = h.funcionario_id
    where h.hora_entrada is not null and h.hora_saida is not null
  )
  select
    f.id,
    round(coalesce(t.horas, 0)::numeric, 2),
    round(
      case when ch.funcionario_id is not null then coalesce(e.horas, 0)
      -- Sem horário definido, estima-se a partir das horas semanais,
      -- só sobre os dias já decorridos.
      else f.horas_semanais_esperadas
           * (greatest(0, least(p_fim, (select dia from hoje)) - p_inicio) / 7.0)
      end::numeric
    , 2),
    coalesce(en.dias, 0),
    coalesce(fa.dias, 0),
    coalesce(fo.dias, 0)
  from func f
  left join trabalhado t  on t.funcionario_id = f.id
  left join esperado e    on e.funcionario_id = f.id
  left join entradas en   on en.funcionario_id = f.id
  left join faltas fa     on fa.funcionario_id = f.id
  left join folgas fo     on fo.funcionario_id = f.id
  left join com_horario ch on ch.funcionario_id = f.id;
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
  v_regime text;
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
  select timezone, politica_banco_horas, regime_folgas
    into v_tz, v_politica, v_regime
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
      h.dias_folga,
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
    'regime_folgas', v_regime,
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 06_banco_horas.sql
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 07_correcoes.sql
-- =====================================================================
-- Salinas — Registo de Ponto
-- 07_correcoes.sql — Correcção de registos pelo gestor
-- =====================================================================
-- Executar depois de 06_banco_horas.sql.
--
-- Porquê: se alguém se esquece de bater a saída, no dia seguinte a app
-- recusa a entrada (a sequência diz que ainda há um turno aberto). Só o
-- gestor pode desbloquear — acrescentando a saída em falta, ou apagando
-- um registo errado.
--
-- Regras:
--   * Só o admin da própria empresa corrige, e sempre com um motivo.
--   * Depois da correcção a sequência (entrada → pausas → saída) tem de
--     continuar válida; se não ficar, nada é gravado.
--   * Cada correcção fica em `correcoes_registos`, com uma cópia do
--     registo, o motivo e quem a fez. Registos acrescentados ficam com
--     método 'manual', para nunca se confundirem com um ponto batido.
-- =====================================================================

-- Um registo acrescentado pelo gestor não foi batido nem por QR nem por GPS.
alter table registos_ponto drop constraint if exists registos_ponto_metodo_check;
alter table registos_ponto add constraint registos_ponto_metodo_check
  check (metodo in ('qrcode','geolocalizacao','manual'));

create table if not exists correcoes_registos (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  funcionario_id uuid references funcionarios(id) on delete cascade,
  accao text not null check (accao in ('adicionado','apagado')),
  registo jsonb not null,
  motivo text not null,
  admin_id uuid references admins(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_correcoes_empresa
  on correcoes_registos(empresa_id, created_at desc);

alter table correcoes_registos enable row level security;
revoke all on correcoes_registos from anon, authenticated;
grant select on correcoes_registos to authenticated;

drop policy if exists correcoes_select_admin on correcoes_registos;
create policy correcoes_select_admin on correcoes_registos
  for select to authenticated
  using (auth_is_admin() and empresa_id = auth_empresa_id());

-- ---------------------------------------------------------------------
-- A sequência inteira de um funcionário respeita a máquina de estados?
-- ---------------------------------------------------------------------
create or replace function _sequencia_valida(p_funcionario_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1
    from (
      select tipo, lag(tipo) over (order by "timestamp") as anterior
      from registos_ponto
      where funcionario_id = p_funcionario_id
    ) s
    where not (s.tipo = any (_proximos_tipos_validos(s.anterior)))
  );
$$;

revoke all on function _sequencia_valida(uuid) from public, anon, authenticated;

create or replace function _admin_atual_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from admins where user_id = auth.uid() limit 1;
$$;

revoke all on function _admin_atual_id() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Acrescentar um registo em falta (ex.: a saída esquecida)
-- ---------------------------------------------------------------------
create or replace function admin_adicionar_registo(
  p_funcionario_id uuid,
  p_tipo text,
  p_timestamp timestamptz,
  p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_func funcionarios;
  v_reg registos_ponto;
  v_motivo text := btrim(coalesce(p_motivo, ''));
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  select * into v_func from funcionarios
  where id = p_funcionario_id and empresa_id = auth_empresa_id();
  if v_func.id is null then
    raise exception 'Funcionário não encontrado nesta empresa.' using errcode = 'P0001';
  end if;

  if p_tipo is null or p_tipo not in ('entrada','saida','inicio_pausa','fim_pausa') then
    raise exception 'Tipo de registo inválido.' using errcode = '22023';
  end if;

  if p_timestamp is null or p_timestamp > now() then
    raise exception 'A hora do registo não pode ser no futuro.' using errcode = 'P0001';
  end if;

  if v_motivo = '' then
    raise exception 'Indique o motivo da correcção.' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from registos_ponto
    where funcionario_id = v_func.id and "timestamp" = p_timestamp
  ) then
    raise exception 'Já existe um registo desta pessoa a essa hora.' using errcode = 'P0001';
  end if;

  insert into registos_ponto (funcionario_id, empresa_id, tipo, metodo, "timestamp", observacao)
  values (v_func.id, v_func.empresa_id, p_tipo, 'manual', p_timestamp, v_motivo)
  returning * into v_reg;

  -- Se a sequência ficar errada, o erro desfaz também o insert acima.
  if not _sequencia_valida(v_func.id) then
    raise exception 'Com esse registo a sequência fica errada (por exemplo, duas entradas seguidas). Verifique o tipo e a hora.'
      using errcode = 'P0001';
  end if;

  insert into correcoes_registos (empresa_id, funcionario_id, accao, registo, motivo, admin_id)
  values (v_func.empresa_id, v_func.id, 'adicionado', to_jsonb(v_reg), v_motivo, _admin_atual_id());

  return to_jsonb(v_reg);
end;
$$;

-- ---------------------------------------------------------------------
-- Apagar um registo errado
-- ---------------------------------------------------------------------
create or replace function admin_apagar_registo(p_registo_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reg registos_ponto;
  v_motivo text := btrim(coalesce(p_motivo, ''));
begin
  if not auth_is_admin() then
    raise exception 'Apenas administradores.' using errcode = '42501';
  end if;

  select * into v_reg from registos_ponto
  where id = p_registo_id and empresa_id = auth_empresa_id();
  if v_reg.id is null then
    raise exception 'Registo não encontrado nesta empresa.' using errcode = 'P0001';
  end if;

  if v_motivo = '' then
    raise exception 'Indique o motivo da correcção.' using errcode = 'P0001';
  end if;

  delete from registos_ponto where id = v_reg.id;

  if not _sequencia_valida(v_reg.funcionario_id) then
    raise exception 'Sem esse registo a sequência fica errada (por exemplo, duas entradas seguidas). Apague também o registo que o acompanha, ou acrescente o que falta.'
      using errcode = 'P0001';
  end if;

  insert into correcoes_registos (empresa_id, funcionario_id, accao, registo, motivo, admin_id)
  values (v_reg.empresa_id, v_reg.funcionario_id, 'apagado', to_jsonb(v_reg), v_motivo, _admin_atual_id());

  return to_jsonb(v_reg);
end;
$$;

revoke all on function admin_adicionar_registo(uuid, text, timestamptz, text) from public, anon;
revoke all on function admin_apagar_registo(uuid, text) from public, anon;
grant execute on function admin_adicionar_registo(uuid, text, timestamptz, text) to authenticated;
grant execute on function admin_apagar_registo(uuid, text) to authenticated;

commit;
