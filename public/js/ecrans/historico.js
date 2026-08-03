import { estadoAtual, listarRegistos, mensagemDeErro, meuBancoHoras } from '../api.js';
import {
  MESES,
  ROTULOS_METODO,
  ROTULOS_TIPO,
  chaveDia,
  dataExtenso,
  duracao,
  esc,
  formatarDistancia,
  horas,
  vazio,
} from '../ui.js';

const FILTROS = [
  { valor: '', rotulo: 'Todos' },
  { valor: 'entrada', rotulo: 'Entradas' },
  { valor: 'saida', rotulo: 'Saídas' },
  { valor: 'inicio_pausa', rotulo: 'Pausas' },
];

// Preservado entre visitas ao separador.
const filtros = { tipo: '', mesOffset: 0 };

export default async function renderHistorico(container, ctx) {
  const estado = ctx.estado ?? (ctx.estado = await estadoAtual());
  const tz = estado.empresa.timezone;

  container.innerHTML = `
    <div class="cabecalho-app">
      <h1 class="titulo">Histórico</h1>
      <div class="navegacao-mes">
        <button type="button" id="mes-anterior" aria-label="Mês anterior">‹</button>
        <span class="mes" id="mes-rotulo"></span>
        <button type="button" id="mes-seguinte" aria-label="Mês seguinte">›</button>
      </div>
    </div>

    <div id="banco-horas"></div>

    <div class="chips" id="chips">
      ${FILTROS.map((f) => `
        <button type="button" class="chip ${filtros.tipo === f.valor ? 'activo' : ''}"
                data-filtro="${f.valor}">${f.rotulo}</button>
      `).join('')}
    </div>

    <div id="lista"><div class="carregando">A carregar…</div></div>
  `;

  const lista = container.querySelector('#lista');
  desenharBancoHoras(container.querySelector('#banco-horas'));
  const rotuloMes = container.querySelector('#mes-rotulo');
  const seguinte = container.querySelector('#mes-seguinte');

  container.querySelector('#mes-anterior').addEventListener('click', () => {
    filtros.mesOffset -= 1;
    carregar();
  });

  seguinte.addEventListener('click', () => {
    if (filtros.mesOffset >= 0) return;
    filtros.mesOffset += 1;
    carregar();
  });

  container.querySelectorAll('[data-filtro]').forEach((b) =>
    b.addEventListener('click', () => {
      filtros.tipo = b.dataset.filtro;
      container.querySelectorAll('[data-filtro]').forEach((x) =>
        x.classList.toggle('activo', x.dataset.filtro === filtros.tipo)
      );
      carregar();
    })
  );

  async function carregar() {
    const { inicio, fim, etiqueta } = calcularMes(filtros.mesOffset);
    rotuloMes.textContent = etiqueta;
    seguinte.disabled = filtros.mesOffset >= 0;
    lista.innerHTML = '<div class="carregando">A carregar…</div>';

    try {
      const registos = await listarRegistos({
        de: inicio.toISOString(),
        ate: fim.toISOString(),
        tipo: filtros.tipo || null,
      });

      lista.innerHTML = registos.length
        ? desenhar(registos, tz)
        : vazio('Sem registos', `Não há registos${filtros.tipo ? ' deste tipo' : ''} em ${etiqueta}.`);
    } catch (e) {
      lista.innerHTML = `<div class="alerta alerta-erro">${esc(mensagemDeErro(e))}</div>`;
    }
  }

  await carregar();
}

/**
 * Saldo do banco de horas em destaque: verde quando está positivo,
 * vermelho quando está negativo.
 *
 * É carregado à parte da lista para que uma falha aqui não impeça o
 * funcionário de ver os seus registos.
 */
async function desenharBancoHoras(alvo) {
  try {
    const banco = await meuBancoHoras();
    const saldo = Number(banco.saldo);

    if (!saldo && !(banco.movimentos ?? []).length) {
      alvo.innerHTML = '';
      return;
    }

    const negativo = saldo < 0;
    const cor = negativo ? 'var(--erro)' : saldo > 0 ? 'var(--sucesso)' : 'var(--texto-suave)';

    alvo.innerHTML = `
      <div class="cartao banco-cartao">
        <div>
          <div class="banco-rotulo">Banco de horas</div>
          <div class="banco-nota">
            ${esc(negativo
              ? 'Tem horas em dívida — não é falta, é saldo a repor.'
              : saldo > 0
                ? 'Tem horas a seu crédito.'
                : 'Está em dia.')}
          </div>
        </div>
        <div class="banco-saldo" style="color:${cor}">${duracao(saldo)}</div>
      </div>
    `;
  } catch {
    // O banco de horas é informativo — se falhar, o histórico continua.
    alvo.innerHTML = '';
  }
}

function desenhar(registos, tz) {
  const porDia = new Map();

  registos.forEach((r) => {
    const chave = chaveDia(r.timestamp, tz);
    if (!porDia.has(chave)) porDia.set(chave, []);
    porDia.get(chave).push(r);
  });

  return Array.from(porDia.values())
    .map((itens) => `
      <div class="dia-cabecalho">${esc(dataExtenso(itens[0].timestamp, tz))}</div>
      ${itens.map((r) => linha(r, tz)).join('')}
    `)
    .join('');
}

function linha(r, tz) {
  const classe = r.tipo === 'entrada'
    ? 'etiqueta-dentro'
    : r.tipo === 'saida' ? 'etiqueta-laranja' : 'etiqueta-pausa';

  const detalhes = [
    ROTULOS_METODO[r.metodo] ?? r.metodo,
    r.dentro_do_raio === false ? 'fora do raio' : null,
    r.distancia_metros != null ? formatarDistancia(Number(r.distancia_metros)) : null,
  ].filter(Boolean);

  return `
    <div class="registo">
      <span class="hora">${esc(horas(r.timestamp, tz))}</span>
      <div>
        <span class="etiqueta ${classe}">${esc(ROTULOS_TIPO[r.tipo] ?? r.tipo)}</span>
        <div class="detalhe">${esc(detalhes.join(' · '))}</div>
        ${r.observacao ? `<div class="detalhe"><em>${esc(r.observacao)}</em></div>` : ''}
      </div>
    </div>
  `;
}

function calcularMes(offset) {
  const agora = new Date();
  const inicio = new Date(agora.getFullYear(), agora.getMonth() + offset, 1, 0, 0, 0, 0);
  const fim = new Date(agora.getFullYear(), agora.getMonth() + offset + 1, 0, 23, 59, 59, 999);

  return { inicio, fim, etiqueta: `${MESES[inicio.getMonth()]} ${inicio.getFullYear()}` };
}
