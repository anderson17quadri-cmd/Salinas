/**
 * Configuração do projecto Supabase para o painel de administração.
 *
 * Nada de credenciais commitadas. Os valores chegam por uma de duas vias:
 *
 *   1. Injectados no deploy — o workflow do GitHub Pages substitui os
 *      placeholders abaixo pelos secrets do repositório.
 *   2. Ecrã de configuração, guardado no localStorage deste navegador.
 *
 * A chave usada é sempre a `anon`, pública por desenho e limitada pelo RLS.
 * A `service_role` nunca pode aparecer aqui: ignora o RLS por completo e
 * daria acesso total à base de dados a qualquer visitante.
 */

const INJECTADO = {
  url: '__SUPABASE_URL__',
  chaveAnon: '__SUPABASE_ANON_KEY__',
};

const CHAVE_ARMAZENAMENTO = 'salinas.config';

// Os placeholders continuam por substituir quando se corre localmente.
const foiInjectado = (valor) => valor && !valor.startsWith('__');

export function obterConfig() {
  if (foiInjectado(INJECTADO.url) && foiInjectado(INJECTADO.chaveAnon)) {
    return { ...INJECTADO };
  }

  try {
    const guardado = JSON.parse(localStorage.getItem(CHAVE_ARMAZENAMENTO) || 'null');
    if (guardado?.url && guardado?.chaveAnon) return guardado;
  } catch {
    // Configuração corrompida — trata-se como inexistente.
  }
  return null;
}

export function guardarConfig({ url, chaveAnon }) {
  localStorage.setItem(CHAVE_ARMAZENAMENTO, JSON.stringify({ url, chaveAnon }));
}

export function limparConfig() {
  localStorage.removeItem(CHAVE_ARMAZENAMENTO);
}
