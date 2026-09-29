#!/usr/bin/env bash
# =====================================================================
# Salinas — corre os testes do schema num Postgres descartável.
#
#   ./supabase/testes/correr.sh
#
# Precisa de um Postgres local (>= 14). Não toca no projecto Supabase:
# cria uma base de dados temporária, aplica os stubs + o schema completo
# e corre supabase/testes/testes.sql.
#
# Variáveis opcionais: PGHOST, PGPORT, PGUSER, BASE_DADOS
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_DADOS="${BASE_DADOS:-salinas_testes}"

export PGUSER="${PGUSER:-postgres}"

echo "→ A recriar a base de dados '${BASE_DADOS}'…"
psql -q -d postgres -c "drop database if exists ${BASE_DADOS}" >/dev/null
psql -q -d postgres -c "create database ${BASE_DADOS}" >/dev/null

for ficheiro in 00_stubs_teste 01_schema 02_rls 03_functions 04_storage 06_banco_horas 07_correcoes; do
  echo "→ ${ficheiro}.sql"
  psql -q -v ON_ERROR_STOP=1 -d "${BASE_DADOS}" \
       -f "${RAIZ}/supabase/${ficheiro}.sql" 2>&1 \
    | grep -v 'does not exist, skipping' \
    | grep -v 'already exists, skipping' || true
done

for suite in testes testes_banco_horas testes_correcoes; do
  echo "→ testes/${suite}.sql"
  psql -v ON_ERROR_STOP=1 -d "${BASE_DADOS}" -f "${RAIZ}/supabase/testes/${suite}.sql"
done

# O atualizar.sql é o que se cola no Supabase: tem de corresponder ao SQL
# que acabou de ser testado.
TEMP="$(mktemp)"
bash "${RAIZ}/tools/gerar-atualizacao.sh" "${TEMP}" >/dev/null
if ! cmp -s "${TEMP}" "${RAIZ}/supabase/atualizar.sql"; then
  rm -f "${TEMP}"
  echo "✗ supabase/atualizar.sql está desactualizado. Corra: tools/gerar-atualizacao.sh" >&2
  exit 1
fi
rm -f "${TEMP}"
echo "✓ supabase/atualizar.sql em dia com o SQL testado."
