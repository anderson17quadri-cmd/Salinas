-- =====================================================================
-- Salinas — Registo de Ponto
-- 00_stubs_teste.sql — Emulação mínima do Supabase para testes locais
-- =====================================================================
-- NÃO EXECUTAR NO SUPABASE. Este ficheiro só existe para poder correr o
-- schema num Postgres normal (CI, desenvolvimento local sem Supabase):
-- recria os objectos que o Supabase já fornece — os papéis `anon` e
-- `authenticated`, o schema `auth` com `auth.uid()` e `auth.users`, e o
-- schema `storage` com `buckets`, `objects` e `storage.foldername()`.
--
-- Uso:
--   psql -f supabase/00_stubs_teste.sql \
--        -f supabase/01_schema.sql \
--        -f supabase/02_rls.sql \
--        -f supabase/03_functions.sql \
--        -f supabase/04_storage.sql
-- =====================================================================

create extension if not exists "pgcrypto";

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end
$$;

create schema if not exists auth;
create schema if not exists storage;

grant usage on schema public to anon, authenticated;
grant usage on schema auth to anon, authenticated;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  created_at timestamptz default now()
);

-- No Supabase, auth.uid() lê o JWT. Aqui lê uma definição de sessão,
-- o que permite "fazer login" nos testes com:
--   set local request.jwt.claim.sub = '<uuid>';
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean default false
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text not null,
  owner uuid,
  created_at timestamptz default now()
);

alter table storage.objects enable row level security;

-- Divide "empresa/funcionario/ficheiro.jpg" em {empresa,funcionario}.
create or replace function storage.foldername(name text)
returns text[]
language sql
immutable
as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1];
$$;
