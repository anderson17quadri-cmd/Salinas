-- =====================================================================
-- Salinas — Registo de Ponto
-- 04_storage.sql — Buckets e policies de Storage
-- =====================================================================
-- Convenção de caminhos: {empresa_id}/{funcionario_id}/{ficheiro}
-- O primeiro segmento é sempre o empresa_id, o que permite isolar
-- completamente os ficheiros de cada empresa via policy.
-- =====================================================================

insert into storage.buckets (id, name, public)
values
  ('registos-ponto', 'registos-ponto', false),
  ('justificacoes',  'justificacoes',  false),
  ('perfis',         'perfis',         true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- registos-ponto — fotos de confirmação do check-in
-- ---------------------------------------------------------------------
drop policy if exists registos_ponto_insert on storage.objects;
create policy registos_ponto_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'registos-ponto'
    and (storage.foldername(name))[1] = auth_empresa_id()::text
    and (storage.foldername(name))[2] = auth_funcionario_id()::text
  );

drop policy if exists registos_ponto_select on storage.objects;
create policy registos_ponto_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'registos-ponto'
    and (storage.foldername(name))[1] = auth_empresa_id()::text
    and (
      auth_is_admin()
      or (storage.foldername(name))[2] = auth_funcionario_id()::text
    )
  );

-- ---------------------------------------------------------------------
-- justificacoes — anexos dos pedidos de falta
-- ---------------------------------------------------------------------
drop policy if exists justificacoes_insert on storage.objects;
create policy justificacoes_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'justificacoes'
    and (storage.foldername(name))[1] = auth_empresa_id()::text
    and (storage.foldername(name))[2] = auth_funcionario_id()::text
  );

drop policy if exists justificacoes_select on storage.objects;
create policy justificacoes_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'justificacoes'
    and (storage.foldername(name))[1] = auth_empresa_id()::text
    and (
      auth_is_admin()
      or (storage.foldername(name))[2] = auth_funcionario_id()::text
    )
  );

-- ---------------------------------------------------------------------
-- perfis — fotos de perfil (bucket público, leitura livre)
-- ---------------------------------------------------------------------
drop policy if exists perfis_insert on storage.objects;
create policy perfis_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'perfis'
    and (storage.foldername(name))[1] = auth_empresa_id()::text
    and (storage.foldername(name))[2] = auth_funcionario_id()::text
  );

drop policy if exists perfis_update on storage.objects;
create policy perfis_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'perfis'
    and (storage.foldername(name))[2] = auth_funcionario_id()::text
  );

drop policy if exists perfis_select on storage.objects;
create policy perfis_select on storage.objects
  for select to public
  using (bucket_id = 'perfis');
