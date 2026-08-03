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
  timezone, qr_token_atualizado_em, created_at
) on empresas to authenticated;
grant update (
  nome, morada, latitude, longitude, raio_metros,
  metodo_qrcode_ativo, metodo_gps_ativo, foto_obrigatoria, timezone
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
