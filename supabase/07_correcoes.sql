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
