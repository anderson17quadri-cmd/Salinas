// =====================================================================
// Salinas — PWA de registo de ponto
// Arranque, autenticação, encaminhamento e instalação no ecrã principal
// =====================================================================

import { criarConta, definirPalavraPasse, entrar, mensagemDeErro, recuperarPalavraPasse, reiniciarCliente, sair, sessaoActual } from './api.js';
import { configFoiInjectada, guardarConfig, limparConfig, obterConfig } from './config.js';
import { notificar, pintarLogo } from './ui.js';

import renderFaltas from './ecrans/faltas.js';
import renderHistorico from './ecrans/historico.js';
import renderInicio from './ecrans/inicio.js';
import renderPerfil from './ecrans/perfil.js';

const ECRAS = {
  inicio: renderInicio,
  historico: renderHistorico,
  faltas: renderFaltas,
  perfil: renderPerfil,
};

const ecra = {
  splash: document.getElementById('ecra-splash'),
  config: document.getElementById('ecra-config'),
  login: document.getElementById('ecra-login'),
  criarConta: document.getElementById('ecra-criar-conta'),
  novaPw: document.getElementById('ecra-nova-pw'),
  app: document.getElementById('app'),
};

// Partilhado entre ecrãs — evita repetir o RPC de estado a cada separador.
const contexto = { estado: null };

function mostrar(qual) {
  Object.entries(ecra).forEach(([nome, el]) => el.classList.toggle('oculto', nome !== qual));
}

pintarLogo(
  document.getElementById('splash-logo'),
  document.getElementById('config-logo'),
  document.getElementById('login-logo'),
  document.getElementById('nova-pw-logo'),
  document.getElementById('criar-conta-logo')
);

// ---------------------------------------------------------------------
// Configuração inicial
// ---------------------------------------------------------------------
document.getElementById('form-config').addEventListener('submit', async (e) => {
  e.preventDefault();
  const erro = document.getElementById('config-erro');
  erro.classList.add('oculto');

  const url = document.getElementById('config-url').value.trim().replace(/\/$/, '');
  const chaveAnon = document.getElementById('config-chave').value.trim();

  if (chaveAnon.includes('service_role')) {
    erro.textContent = 'Essa é a chave service_role. Use a chave anon (public).';
    erro.classList.remove('oculto');
    return;
  }

  guardarConfig({ url, chaveAnon });
  reiniciarCliente();
  await arrancar();
});

// Com a configuração embutida, mudar de projecto não faz sentido nenhum.
if (configFoiInjectada()) {
  document.getElementById('mudar-projecto').closest('.nota').classList.add('oculto');
}

document.getElementById('mudar-projecto').addEventListener('click', () => {
  limparConfig();
  reiniciarCliente();
  mostrar('config');
});

// ---------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------
document.getElementById('form-login').addEventListener('submit', async (e) => {
  e.preventDefault();
  const botao = document.getElementById('login-submeter');
  const erro = document.getElementById('login-erro');

  erro.classList.add('oculto');
  botao.disabled = true;
  botao.textContent = 'A entrar…';

  try {
    await entrar(
      document.getElementById('login-email').value,
      document.getElementById('login-palavra-passe').value
    );
    await arrancar();
  } catch (e2) {
    erro.textContent = mensagemDeErro(e2, 'Não foi possível entrar.');
    erro.classList.remove('oculto');
  } finally {
    botao.disabled = false;
    botao.textContent = 'Entrar';
  }
});

document.getElementById('login-recuperar').addEventListener('click', async () => {
  const email = document.getElementById('login-email').value;
  const erro = document.getElementById('login-erro');

  if (!email.trim()) {
    erro.textContent = 'Escreva o seu email para receber o link de recuperação.';
    erro.classList.remove('oculto');
    return;
  }

  try {
    await recuperarPalavraPasse(email);
    notificar('Email de recuperação enviado.', 'sucesso');
  } catch (e) {
    erro.textContent = mensagemDeErro(e);
    erro.classList.remove('oculto');
  }
});

// ---------------------------------------------------------------------
// Criar conta
// ---------------------------------------------------------------------
document.getElementById('ir-criar-conta').addEventListener('click', () => {
  document.getElementById('criar-email').value =
    document.getElementById('login-email').value;
  mostrar('criarConta');
});

document.getElementById('voltar-login').addEventListener('click', () => mostrar('login'));

document.getElementById('form-criar-conta').addEventListener('submit', async (e) => {
  e.preventDefault();
  const erro = document.getElementById('criar-erro');
  const sucesso = document.getElementById('criar-sucesso');
  const botao = document.getElementById('criar-submeter');

  erro.classList.add('oculto');
  sucesso.classList.add('oculto');

  const email = document.getElementById('criar-email').value;
  const pw = document.getElementById('criar-pw').value;
  const pw2 = document.getElementById('criar-pw2').value;

  if (pw.length < 8) {
    erro.textContent = 'A palavra-passe tem de ter pelo menos 8 caracteres.';
    erro.classList.remove('oculto');
    return;
  }
  if (pw !== pw2) {
    erro.textContent = 'As duas palavras-passe não coincidem.';
    erro.classList.remove('oculto');
    return;
  }

  botao.disabled = true;
  botao.textContent = 'A criar…';

  try {
    const { precisaConfirmar } = await criarConta(email, pw);

    if (precisaConfirmar) {
      sucesso.innerHTML =
        'Conta criada. Enviámos um email para <strong>' + email.trim() + '</strong>. '
        + 'Abra-o e clique no link para confirmar — depois já pode entrar. '
        + 'Veja também a pasta de spam.';
      sucesso.classList.remove('oculto');
      document.getElementById('form-criar-conta').reset();
    } else {
      await arrancar();
    }
  } catch (e2) {
    const msg = mensagemDeErro(e2, 'Não foi possível criar a conta.');
    // O plano gratuito do Supabase só deixa enviar 2 emails por hora.
    erro.textContent = /rate limit|too many|segundos|seconds/i.test(msg)
      ? 'Já foram enviados muitos emails nesta hora. Espere um pouco e tente de novo.'
      : msg;
    erro.classList.remove('oculto');
  } finally {
    botao.disabled = false;
    botao.textContent = 'Criar conta';
  }
});

// ---------------------------------------------------------------------
// Recuperação de palavra-passe
// ---------------------------------------------------------------------
/**
 * O link do email traz `#access_token=…&type=recovery`. O supabase-js
 * converte-o em sessão sozinho, mas essa sessão só serve para uma coisa:
 * definir a nova palavra-passe. Sem este ecrã, quem clicasse no link
 * entrava na app com a palavra-passe antiga — ou nenhuma — e nunca
 * chegava a defini-la.
 */
function pedidoDeRecuperacao() {
  const hash = new URLSearchParams(location.hash.replace(/^#/, ''));
  // Tem de ser `type=recovery` e mais nada: a confirmação de conta
  // (`type=signup`) também traz um access_token, e apanhá-la aqui mandava
  // quem acabou de confirmar o email para o ecrã de mudar a palavra-passe.
  return hash.get('type') === 'recovery';
}

async function tratarRecuperacao() {
  mostrar('novaPw');

  const form = document.getElementById('form-nova-pw');
  const erro = document.getElementById('nova-pw-erro');
  const botao = document.getElementById('nova-pw-submeter');

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    erro.classList.add('oculto');

    const nova = document.getElementById('nova-pw').value;
    const repetir = document.getElementById('nova-pw2').value;

    if (nova.length < 8) {
      erro.textContent = 'A palavra-passe tem de ter pelo menos 8 caracteres.';
      erro.classList.remove('oculto');
      return;
    }
    if (nova !== repetir) {
      erro.textContent = 'As duas palavras-passe não coincidem.';
      erro.classList.remove('oculto');
      return;
    }

    botao.disabled = true;
    botao.textContent = 'A guardar…';

    try {
      await definirPalavraPasse(nova);
      // Limpa o token do endereço antes de seguir.
      history.replaceState(null, '', location.pathname);
      notificar('Palavra-passe definida.', 'sucesso');
      await arrancar();
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2, 'Não foi possível guardar.');
      erro.classList.remove('oculto');
    } finally {
      botao.disabled = false;
      botao.textContent = 'Guardar';
    }
  });
}

// ---------------------------------------------------------------------
// Encaminhamento entre separadores
// ---------------------------------------------------------------------
async function encaminhar() {
  // Um `hashchange` pode chegar com a app escondida — por exemplo se a
  // sessão expirar e o utilizador carregar em "voltar" no ecrã de login.
  // Sem esta guarda, os ecrãs desenhavam-se por baixo e disparavam
  // chamadas à API que só podiam falhar.
  if (ecra.app.classList.contains('oculto')) return;

  const rota = (location.hash.replace('#/', '') || 'inicio').split('/')[0];
  const render = ECRAS[rota] ?? ECRAS.inicio;

  document.querySelectorAll('[data-tab]').forEach((a) =>
    a.classList.toggle('activo', a.dataset.tab === rota)
  );

  const conteudo = document.getElementById('conteudo');
  conteudo.innerHTML = '<div class="carregando">A carregar…</div>';

  try {
    await render(conteudo, contexto);
    conteudo.scrollTo?.(0, 0);
    window.scrollTo(0, 0);
    if (rota === 'inicio') mostrarConviteInstalacao();
  } catch (e) {
    const msg = mensagemDeErro(e);

    // Sessão válida mas sem funcionário associado: não vale a pena
    // deixar a pessoa presa num ecrã de erro.
    if (msg.includes('não está associado a nenhum funcionário')) {
      await sair();
      mostrar('login');
      const erro = document.getElementById('login-erro');
      erro.textContent = 'Esta conta ainda não está associada a nenhum funcionário. Contacte o seu gestor.';
      erro.classList.remove('oculto');
      return;
    }

    conteudo.innerHTML = `<div class="alerta alerta-erro">${msg}</div>`;
  }
}

window.addEventListener('hashchange', encaminhar);

// ---------------------------------------------------------------------
// Estado de ligação
// ---------------------------------------------------------------------
const barraOffline = document.getElementById('barra-offline');
const actualizarLigacao = () => barraOffline.classList.toggle('oculto', navigator.onLine);

window.addEventListener('online', actualizarLigacao);
window.addEventListener('offline', actualizarLigacao);
actualizarLigacao();

// ---------------------------------------------------------------------
// Instalação no ecrã principal
// ---------------------------------------------------------------------
let promptInstalacao = null;

window.addEventListener('beforeinstallprompt', (e) => {
  // O Chrome deixa adiar o convite para o momento certo; o Safari não
  // dispara este evento, daí as instruções manuais para iOS mais abaixo.
  e.preventDefault();
  promptInstalacao = e;
});

const CHAVE_CONVITE = 'salinas.convite-instalacao';

function jaInstalada() {
  return window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
}

function ehIos() {
  return /iphone|ipad|ipod/i.test(navigator.userAgent);
}

function mostrarConviteInstalacao() {
  const zona = document.getElementById('zona-instalar');
  if (!zona || jaInstalada() || localStorage.getItem(CHAVE_CONVITE) === 'dispensado') return;
  if (!promptInstalacao && !ehIos()) return;

  zona.innerHTML = `
    <div class="instalar">
      <button type="button" class="fechar" id="fechar-convite" aria-label="Dispensar">×</button>
      <strong>Instale a Salinas no telemóvel</strong>
      ${promptInstalacao
        ? 'Fica com ícone no ecrã principal e abre como uma app normal.'
          + '<button type="button" class="botao botao-primario" id="instalar">Instalar</button>'
        : 'No Safari: toque em <strong>Partilhar</strong> e depois em '
          + '<strong>“Adicionar ao Ecrã Principal”</strong>.'}
    </div>
  `;

  zona.querySelector('#fechar-convite').addEventListener('click', () => {
    localStorage.setItem(CHAVE_CONVITE, 'dispensado');
    zona.innerHTML = '';
  });

  zona.querySelector('#instalar')?.addEventListener('click', async () => {
    if (!promptInstalacao) return;
    promptInstalacao.prompt();
    const { outcome } = await promptInstalacao.userChoice;
    promptInstalacao = null;
    zona.innerHTML = '';
    if (outcome === 'accepted') notificar('Salinas instalada no ecrã principal.', 'sucesso');
  });
}

// ---------------------------------------------------------------------
// Service worker
// ---------------------------------------------------------------------
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(() => {
      // Sem service worker a app continua a funcionar; só perde a
      // instalação e o arranque offline.
    });
  });
}

// ---------------------------------------------------------------------
// Arranque
// ---------------------------------------------------------------------
async function arrancar() {
  if (!obterConfig()) {
    mostrar('config');
    return;
  }

  // Tem de ser antes de olhar para a sessão: o link de recuperação cria
  // uma sessão válida, e sem esta verificação entrava-se na app em vez de
  // se definir a palavra-passe.
  if (pedidoDeRecuperacao()) {
    await tratarRecuperacao();
    return;
  }

  let sessao;
  try {
    sessao = await sessaoActual();
  } catch (e) {
    const erro = document.getElementById('config-erro');
    erro.textContent = mensagemDeErro(e);
    erro.classList.remove('oculto');
    mostrar('config');
    return;
  }

  if (!sessao) {
    mostrar('login');
    return;
  }

  mostrar('app');
  if (!location.hash) location.hash = '#/inicio';
  await encaminhar();
}

arrancar();
