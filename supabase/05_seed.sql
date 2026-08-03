-- =====================================================================
-- Salinas — Registo de Ponto
-- 05_seed.sql — Dados de arranque (opcional, para desenvolvimento)
-- =====================================================================
-- Executar DEPOIS de criar as contas em Authentication → Users.
-- Substitua os emails pelos reais antes de correr.
-- =====================================================================

-- 1) Empresa de exemplo (coordenadas: Praça do Comércio, Lisboa)
insert into empresas (nome, morada, latitude, longitude, raio_metros, timezone)
values (
  'Salinas Demo, Lda.',
  'Praça do Comércio, 1100-148 Lisboa',
  38.707751, -9.136592,
  150,
  'Europe/Lisbon'
)
on conflict do nothing;

-- 2) Administrador da empresa
--    O user_id é preenchido automaticamente quando a conta com este email
--    fizer signup (ver trigger on_auth_user_created em 01_schema.sql).
insert into admins (empresa_id, nome, email)
select id, 'Administrador', 'admin@exemplo.pt'
from empresas
where nome = 'Salinas Demo, Lda.'
on conflict (user_id) do nothing;

-- 3) Funcionários de exemplo
insert into funcionarios (empresa_id, nome, email, cargo, horas_semanais_esperadas)
select e.id, v.nome, v.email, v.cargo, v.horas
from empresas e,
  (values
    ('Ana Ferreira',   'ana@exemplo.pt',   'Operadora de Caixa', 40),
    ('Bruno Martins',  'bruno@exemplo.pt', 'Armazém',            40),
    ('Carla Sousa',    'carla@exemplo.pt', 'Atendimento',        20)
  ) as v(nome, email, cargo, horas)
where e.nome = 'Salinas Demo, Lda.'
on conflict (email) do nothing;

-- 4) Horário padrão de segunda a sexta, 09:00–18:00, para todos
insert into horarios_esperados (funcionario_id, dia_semana, hora_entrada, hora_saida)
select f.id, d.dia, time '09:00', time '18:00'
from funcionarios f
join empresas e on e.id = f.empresa_id
cross join (values (1),(2),(3),(4),(5)) as d(dia)
where e.nome = 'Salinas Demo, Lda.'
on conflict (funcionario_id, dia_semana) do nothing;

-- 5) Token do QR code para colar no gerador (tools/gerar-qrcode.js)
select nome, qr_code_token from empresas where nome = 'Salinas Demo, Lda.';
