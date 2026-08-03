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
  created_at timestamptz default now()
);

comment on column empresas.qr_code_token is
  'Token secreto do QR code da empresa. Nunca exposto a funcionários (ver grants em 02_rls.sql).';

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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function trg_ligar_conta_auth();
