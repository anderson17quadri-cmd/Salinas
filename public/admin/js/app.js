// =====================================================================
// Salinas — Painel de Administração
// Arranque, autenticação e encaminhamento entre vistas
// =====================================================================

import {
  contextoAdmin,
  entrar,
  mensagemDeErro,
  recuperarPalavraPasse,
  reiniciarCliente,
  sair,
  sessaoActual,
} from './api.js';
import { guardarConfig, limparConfig, obterConfig } from './config.js';
import { fecharModal, notificar } from './ui.js';

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
  relatorio: renderRelatorio,
  definicoes: renderDefinicoes,
};

const ecra = {
  config: document.getElementById('ecra-config'),
  login: document.getElementById('ecra-login'),
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
