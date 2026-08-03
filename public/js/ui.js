// =====================================================================
// Helpers partilhados pelos ecrãs da PWA
// =====================================================================

export const TIMEZONE_PADRAO = 'Europe/Lisbon';
const LOCALE = 'pt-PT';

export const ROTULOS_TIPO = {
  entrada: 'Entrada',
  saida: 'Saída',
  inicio_pausa: 'Início de pausa',
  fim_pausa: 'Fim de pausa',
};

export const ROTULOS_METODO = {
  qrcode: 'QR code',
  geolocalizacao: 'Geolocalização',
};

export const ROTULOS_ESTADO = {
  dentro: 'Ao serviço',
  pausa: 'Em pausa',
  fora: 'Fora de serviço',
};

export const CLASSES_ESTADO = {
  dentro: 'etiqueta-dentro',
  pausa: 'etiqueta-pausa',
  fora: 'etiqueta-fora',
};

export const DIAS_SEMANA = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado'];

export const MESES = [
  'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
  'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro',
];

/** Escapa texto vindo da base de dados antes de o injectar em HTML. */
export function esc(valor) {
  if (valor == null) return '';
  return String(valor)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

// --------------------------- Datas e horas ---------------------------
// A base de dados guarda tudo em UTC; aqui converte-se para o fuso da empresa.

export function horas(iso, tz = TIMEZONE_PADRAO) {
  if (!iso) return '—';
  return new Date(iso).toLocaleTimeString(LOCALE, { hour: '2-digit', minute: '2-digit', timeZone: tz });
}

export function dataCurta(valor) {
  if (!valor) return '—';
  if (/^\d{4}-\d{2}-\d{2}$/.test(valor)) {
    const [a, m, d] = valor.split('-');
    return `${d}/${m}/${a}`;
  }
  return new Date(valor).toLocaleDateString(LOCALE, { day: '2-digit', month: '2-digit', year: 'numeric' });
}

export function dataExtenso(iso, tz = TIMEZONE_PADRAO) {
  if (!iso) return '—';
  const texto = new Date(iso).toLocaleDateString(LOCALE, {
    weekday: 'long', day: 'numeric', month: 'long', timeZone: tz,
  });
  // Em português só a primeira letra leva maiúscula: "segunda-feira, 3 de
  // agosto". O `text-transform: capitalize` do CSS punha maiúscula em cada
  // palavra e dava "Segunda-Feira, 3 De Agosto".
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

/** Chave AAAA-MM-DD no fuso indicado, para agrupar registos por dia. */
export function chaveDia(iso, tz = TIMEZONE_PADRAO) {
  return new Intl.DateTimeFormat('en-CA', {
    year: 'numeric', month: '2-digit', day: '2-digit', timeZone: tz,
  }).format(new Date(iso));
}

export function hojeIso() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// ------------------------------ Marca --------------------------------
/** Coloca o logo da Pastelaria Salinas nos contentores indicados. */
export function pintarLogo(...contentores) {
  contentores.filter(Boolean).forEach((el) => {
    el.innerHTML = '<img src="assets/logo.png" alt="Pastelaria Salinas" />';
  });
}

// ---------------------------- Notificações ---------------------------
let temporizador = null;

export function notificar(mensagem, tom = 'info') {
  const el = document.getElementById('notificacao');
  el.textContent = mensagem;
  el.className = `notificacao ${tom === 'info' ? '' : `notificacao-${tom}`}`.trim();
  clearTimeout(temporizador);
  temporizador = setTimeout(() => el.classList.add('oculto'), 3600);
}

// ------------------------------- Modal -------------------------------
export function abrirModal(html) {
  const fundo = document.getElementById('modal-fundo');
  const modal = document.getElementById('modal');

  modal.innerHTML = `<div class="modal-puxador"></div>${html}`;
  fundo.classList.remove('oculto');

  const porFundo = (e) => { if (e.target === fundo) fecharModal(); };
  const porEsc = (e) => { if (e.key === 'Escape') fecharModal(); };

  fundo.addEventListener('click', porFundo);
  document.addEventListener('keydown', porEsc);
  fundo._limpar = () => {
    fundo.removeEventListener('click', porFundo);
    document.removeEventListener('keydown', porEsc);
  };

  modal.querySelectorAll('[data-fechar]').forEach((b) => b.addEventListener('click', fecharModal));
  return modal;
}

export function fecharModal() {
  const fundo = document.getElementById('modal-fundo');
  fundo._limpar?.();
  fundo.classList.add('oculto');
  document.getElementById('modal').innerHTML = '';
}

export function confirmar(titulo, mensagem, textoConfirmar = 'Continuar') {
  return new Promise((resolve) => {
    const modal = abrirModal(`
      <h2>${esc(titulo)}</h2>
      <p class="nota">${esc(mensagem)}</p>
      <button type="button" class="botao botao-primario" data-sim>${esc(textoConfirmar)}</button>
      <button type="button" class="botao botao-secundario" data-nao>Cancelar</button>
    `);

    modal.querySelector('[data-sim]').addEventListener('click', () => { fecharModal(); resolve(true); });
    modal.querySelector('[data-nao]').addEventListener('click', () => { fecharModal(); resolve(false); });
  });
}

// ---------------------- Feedback de check-in -------------------------
/**
 * "Entrada registada às 09:03", com animação de sucesso.
 * Fecha-se sozinho; devolve uma promessa que resolve quando desaparece.
 */
export function mostrarSucesso(resultado) {
  const el = document.getElementById('sucesso');
  const circulo = document.getElementById('sucesso-circulo');
  const simbolo = document.getElementById('sucesso-simbolo');
  const titulo = document.getElementById('sucesso-titulo');
  const nota = document.getElementById('sucesso-nota');

  const foraDoRaio = resultado.dentro_do_raio === false;

  circulo.classList.toggle('aviso', foraDoRaio);
  simbolo.textContent = foraDoRaio ? '!' : '✓';
  titulo.textContent = `${ROTULOS_TIPO[resultado.tipo] ?? 'Registo'} registada às ${resultado.hora_local}`;

  if (foraDoRaio) {
    const dist = resultado.distancia_metros != null
      ? ` (${formatarDistancia(Number(resultado.distancia_metros))})`
      : '';
    nota.textContent = `Registado fora do raio da empresa${dist}. O seu gestor vai rever este registo.`;
    nota.classList.remove('oculto');
  } else {
    nota.classList.add('oculto');
  }

  el.classList.remove('oculto');

  if (navigator.vibrate) navigator.vibrate(foraDoRaio ? [40, 60, 40] : 60);

  return new Promise((resolve) => {
    setTimeout(() => {
      el.classList.add('oculto');
      resolve();
    }, foraDoRaio ? 3400 : 2200);
  });
}

/** Horas decimais em "8h30", com sinal quando é negativo. */
export function duracao(horasDecimais) {
  if (horasDecimais == null) return '—';
  const total = Math.round(Number(horasDecimais) * 60);
  const sinal = total < 0 ? '−' : total > 0 ? '+' : '';
  const h = Math.floor(Math.abs(total) / 60);
  const m = Math.abs(total) % 60;
  return `${sinal}${h}h${String(m).padStart(2, '0')}`;
}

export function formatarDistancia(metros) {
  if (metros == null) return '—';
  if (metros < 1000) return `${Math.round(metros)} m`;
  return `${(metros / 1000).toFixed(1)} km`;
}

export function etiquetaEstado(estado) {
  return `<span class="etiqueta ${CLASSES_ESTADO[estado] ?? 'etiqueta-fora'}">${ROTULOS_ESTADO[estado] ?? estado}</span>`;
}

export function vazio(titulo, descricao = '') {
  return `<div class="vazio"><strong>${esc(titulo)}</strong>${descricao ? esc(descricao) : ''}</div>`;
}
