#!/usr/bin/env bash
# Junta num só ficheiro tudo o que é preciso para pôr o projecto Supabase
# em dia: supabase/atualizar.sql. Cola-se no SQL Editor e corre-se uma vez.
#
# Todos os ficheiros incluídos podem correr sobre uma base já instalada
# (create or replace, add column if not exists, drop policy if exists…),
# e vai tudo numa transacção: se algo falhar, nada fica meio aplicado.
#
# O 00_stubs_teste.sql fica de fora — só existe para os testes locais — e
# o 04_storage.sql também, porque os buckets já estão criados.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINO="${1:-${RAIZ}/supabase/atualizar.sql}"

{
  echo "-- ====================================================================="
  echo "-- Salinas — actualização do projecto Supabase"
  echo "-- ====================================================================="
  echo "-- GERADO por tools/gerar-atualizacao.sh — não editar à mão."
  echo "-- Como usar: Supabase → SQL Editor → colar tudo → Run."
  echo "-- Pode correr mais do que uma vez; não apaga dados."
  echo "-- ====================================================================="
  echo
  echo "begin;"
  for f in 01_schema 02_rls 03_functions 06_banco_horas 07_correcoes; do
    echo
    echo "-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> ${f}.sql"
    cat "${RAIZ}/supabase/${f}.sql"
  done
  echo
  echo "commit;"
} > "${DESTINO}"

echo "Gerado: ${DESTINO} ($(wc -l < "${DESTINO}") linhas)"
