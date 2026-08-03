// =====================================================================
// Salinas — Painel de Administração
// Arranque, autenticação e encaminhamento entre vistas
// =====================================================================

import {
  contextoAdmin,
  definirPalavraPasse,
  entrar,
  mensagemDeErro,
  recuperarPalavraPasse,
  reiniciarCliente,
  sair,
  sessaoActual,
} from './api.js';
import { configFoiInjectada, guardarConfig, limparConfig, obterConfig } from './config.js';
import { fecharModal, notificar } from './ui.js';

import renderBancoHoras from './vistas/banco-horas.js';
import renderDashboard from './vistas/dashboard.js';
import renderDefinicoes from './vistas/definicoes.js';
import renderFuncionarios from './vistas/funcionarios.js';
import renderJustificacoes from './vistas/justificacoes.js';
import renderQrCode from './vistas/qrcode.js';
import renderRegistos from './vistas/registos.js';
import renderRelatorio from './vistas/relatorio.js';

const VISTAS = {
  dashboard: renderDashboard,
  funcionarios: renderFuncionarios,
  registos: renderRegistos,
  qrcode: renderQrCode,
  justificacoes: renderJustificacoes,
  'banco-horas': renderBancoHoras,
  relatorio: renderRelatorio,
  definicoes: renderDefinicoes,
};

const ecra = {
  config: document.getElementById('ecra-config'),
  login: document.getElementById('ecra-login'),
  novaPw: document.getElementById('ecra-nova-pw'),
  app: document.getElementById('app'),
};

// Contexto partilhado com todas as vistas (admin + empresa + recarregar).
export const contexto = {
  admin: null,
  empresa: null,
  timezone: 'Europe/Lisbon',
  recarregar: () => encaminhar(),
};

function mostrar(qual) {
  Object.entries(ecra).forEach(([nome, el]) => el.classList.toggle('oculto', nome !== qual));
}

// ---------------------------------------------------------------------
// Ecrã de configuração
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
// Ecrã de login
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

document.getElementById('terminar-sessao').addEventListener('click', async () => {
  await sair();
  location.hash = '';
  mostrar('login');
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
  return hash.get('type') === 'recovery' || hash.has('access_token');
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
// Encaminhamento
// ---------------------------------------------------------------------
async function encaminhar() {
  const rota = (location.hash.replace('#/', '') || 'dashboard').split('/')[0];
  const render = VISTAS[rota] ?? VISTAS.dashboard;

  document.querySelectorAll('[data-nav]').forEach((a) =>
    a.classList.toggle('activo', a.dataset.nav === rota)
  );

  const conteudo = document.getElementById('conteudo');
  conteudo.innerHTML = '<div class="carregando">A carregar…</div>';
  fecharModal();

  try {
    await render(conteudo, contexto);
  } catch (e) {
    conteudo.innerHTML = `<div class="alerta alerta-erro">${mensagemDeErro(e)}</div>`;
  }
}

window.addEventListener('hashchange', encaminhar);

// ---------------------------------------------------------------------
// Arranque
// ---------------------------------------------------------------------
async function arrancar() {
  if (!obterConfig()) {
    mostrar('config');
    return;
  }

  // Antes de olhar para a sessão: o link de recuperação cria uma sessão
  // válida, e sem isto entrava-se no painel sem definir a palavra-passe.
  if (pedidoDeRecuperacao()) {
    await tratarRecuperacao();
    return;
  }

  let sessao;
  try {
    sessao = await sessaoActual();
  } catch (e) {
    document.getElementById('config-erro').textContent = mensagemDeErro(e);
    document.getElementById('config-erro').classList.remove('oculto');
    mostrar('config');
    return;
  }

  if (!sessao) {
    mostrar('login');
    return;
  }

  const ctx = await contextoAdmin().catch(() => null);

  if (!ctx) {
    // Autenticado mas sem registo em `admins` — provavelmente um funcionário.
    await sair();
    mostrar('login');
    const erro = document.getElementById('login-erro');
    erro.textContent = 'Esta conta não é administradora de nenhuma empresa.';
    erro.classList.remove('oculto');
    return;
  }

  contexto.admin = ctx.admin;
  contexto.empresa = ctx.empresa;
  contexto.timezone = ctx.empresa.timezone || 'Europe/Lisbon';

  document.getElementById('barra-empresa').textContent = ctx.empresa.nome;
  document.getElementById('barra-utilizador').textContent = sessao.user.email;

  mostrar('app');
  if (!location.hash) location.hash = '#/dashboard';
  await encaminhar();
}

arrancar();
