/**
 * Configuração do projecto Supabase para a PWA.
 *
 * Nada de credenciais commitadas. Os valores chegam por uma de três vias,
 * nesta ordem:
 *
 *   1. Injectados no deploy — o workflow do GitHub Pages substitui os
 *      placeholders abaixo pelos secrets do repositório.
 *   2. Link de instalação — a empresa partilha
 *      `https://.../?supabase=<url>&key=<anon>`; a PWA guarda os valores e
 *      limpa o endereço. É o caminho normal para o funcionário.
 *   3. Ecrã de configuração manual, como último recurso.
 *
 * A chave usada é sempre a `anon`, pública por desenho e limitada pelo RLS.
 * A `service_role` nunca pode aparecer aqui: ignora o RLS por completo.
 */

const INJECTADO = {
  url: '__SUPABASE_URL__',
  chaveAnon: '__SUPABASE_ANON_KEY__',
};

const CHAVE_ARMAZENAMENTO = 'salinas.config';

// Os placeholders continuam por substituir quando se corre localmente.
const foiInjectado = (valor) => valor && !valor.startsWith('__');

/** Lê `?supabase=…&key=…` do link de instalação e guarda-o. */
function lerDoEndereco() {
  const params = new URLSearchParams(location.search);
  const url = params.get('supabase');
  const chaveAnon = params.get('key');

  if (!url || !chaveAnon) return null;

  const config = { url: url.replace(/\/$/, ''), chaveAnon };
  guardarConfig(config);

  // Tira as credenciais da barra de endereço para não ficarem no histórico
  // nem serem partilhadas por engano num screenshot.
  history.replaceState(null, '', location.pathname + location.hash);

  return config;
}

export function obterConfig() {
  if (foiInjectado(INJECTADO.url) && foiInjectado(INJECTADO.chaveAnon)) {
    return { ...INJECTADO };
  }

  const doEndereco = lerDoEndereco();
  if (doEndereco) return doEndereco;

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
