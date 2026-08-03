// =====================================================================
// Helpers de UI partilhados pelas vistas do painel
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

export const DIAS_SEMANA = [
  'Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado',
];

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

// ------------------------------ Datas -------------------------------
// A base de dados guarda tudo em UTC; aqui converte-se para o fuso da empresa.

export function horas(iso, tz = TIMEZONE_PADRAO) {
  if (!iso) return '—';
  return new Date(iso).toLocaleTimeString(LOCALE, {
    hour: '2-digit', minute: '2-digit', timeZone: tz,
  });
}

export function dataHora(iso, tz = TIMEZONE_PADRAO) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString(LOCALE, {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', timeZone: tz,
  });
}

export function dataCurta(valor, tz = TIMEZONE_PADRAO) {
  if (!valor) return '—';
  // Datas puras (AAAA-MM-DD) não devem sofrer conversão de fuso.
  if (/^\d{4}-\d{2}-\d{2}$/.test(valor)) {
    const [a, m, d] = valor.split('-');
    return `${d}/${m}/${a}`;
  }
  return new Date(valor).toLocaleDateString(LOCALE, {
    day: '2-digit', month: '2-digit', year: 'numeric', timeZone: tz,
  });
}

export function duracao(horasDecimais) {
  if (horasDecimais == null) return '—';
  const total = Math.round(Number(horasDecimais) * 60);
  const sinal = total < 0 ? '−' : '';
  const h = Math.floor(Math.abs(total) / 60);
  const m = Math.abs(total) % 60;
  return `${sinal}${h}h${String(m).padStart(2, '0')}`;
}

/** Primeiro e último instante de um dia local, em ISO/UTC. */
export function intervaloDoDia(dataIso) {
  const inicio = new Date(`${dataIso}T00:00:00`);
  const fim = new Date(`${dataIso}T23:59:59.999`);
  return { de: inicio.toISOString(), ate: fim.toISOString() };
}

export function hojeIso() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// ------------------------------ Notificações ------------------------
let temporizadorNotificacao = null;

export function notificar(mensagem, tom = 'info') {
  const el = document.getElementById('notificacao');
  el.textContent = mensagem;
  el.className = `notificacao ${tom === 'info' ? '' : `notificacao-${tom}`}`.trim();
  clearTimeout(temporizadorNotificacao);
  temporizadorNotificacao = setTimeout(() => el.classList.add('oculto'), 3600);
}

// ------------------------------ Modal -------------------------------
export function abrirModal(html) {
  const fundo = document.getElementById('modal-fundo');
  const modal = document.getElementById('modal');
  modal.innerHTML = html;
  fundo.classList.remove('oculto');

  const fecharPorFundo = (e) => {
    if (e.target === fundo) fecharModal();
  };
  const fecharPorEsc = (e) => {
    if (e.key === 'Escape') fecharModal();
  };

  fundo.addEventListener('click', fecharPorFundo);
  document.addEventListener('keydown', fecharPorEsc);

  fundo._limpar = () => {
    fundo.removeEventListener('click', fecharPorFundo);
    document.removeEventListener('keydown', fecharPorEsc);
  };

  modal.querySelectorAll('[data-fechar]').forEach((b) =>
    b.addEventListener('click', fecharModal)
  );

  return modal;
}

export function fecharModal() {
  const fundo = document.getElementById('modal-fundo');
  fundo._limpar?.();
  fundo.classList.add('oculto');
  document.getElementById('modal').innerHTML = '';
}

export function confirmar(titulo, mensagem, textoConfirmar = 'Confirmar') {
  return new Promise((resolve) => {
    const modal = abrirModal(`
      <h2>${esc(titulo)}</h2>
      <p>${esc(mensagem)}</p>
      <div class="modal-accoes">
        <button type="button" class="botao botao-secundario" data-cancelar>Cancelar</button>
        <button type="button" class="botao botao-perigo" data-confirmar>${esc(textoConfirmar)}</button>
      </div>
    `);

    modal.querySelector('[data-cancelar]').addEventListener('click', () => {
      fecharModal();
      resolve(false);
    });
    modal.querySelector('[data-confirmar]').addEventListener('click', () => {
      fecharModal();
      resolve(true);
    });
  });
}

// ------------------------------ Exportação --------------------------
export function descarregarCsv(nomeFicheiro, cabecalhos, linhas) {
  const celula = (v) => {
    const texto = v == null ? '' : String(v);
    return /[";\n]/.test(texto) ? `"${texto.replaceAll('"', '""')}"` : texto;
  };

  // Ponto-e-vírgula + BOM: é o que o Excel em português abre correctamente.
  const csv = [cabecalhos, ...linhas].map((l) => l.map(celula).join(';')).join('\r\n');
  const blob = new Blob([`﻿${csv}`], { type: 'text/csv;charset=utf-8;' });

  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = nomeFicheiro;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

/** Exportação para PDF através da caixa de impressão do navegador. */
export function exportarPdf() {
  window.print();
}

export function etiquetaEstado(estado) {
  const classe = { dentro: 'etiqueta-dentro', pausa: 'etiqueta-pausa', fora: 'etiqueta-fora' }[estado] ?? 'etiqueta-fora';
  return `<span class="etiqueta ${classe}">${ROTULOS_ESTADO[estado] ?? estado}</span>`;
}
