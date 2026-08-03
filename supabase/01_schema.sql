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
  created_at timestamptz default now()
);

-- Colunas acrescentadas depois da primeira instalação. O ficheiro é para
-- poder correr outra vez sobre uma base já criada, e o `create table if
-- not exists` acima não acrescenta colunas novas a uma tabela existente.
alter table empresas
  add column if not exists regime_folgas text not null default 'fixo';
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
  metodo text check (metodo in ('qrcode','geolocalizacao')) not null,
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
