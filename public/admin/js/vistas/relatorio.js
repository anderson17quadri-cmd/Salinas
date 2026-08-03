import { mensagemDeErro, relatorioMensal } from '../api.js';
import { MESES, descarregarCsv, duracao, esc, exportarPdf, notificar } from '../ui.js';

const agora = new Date();
const seleccao = { ano: agora.getFullYear(), mes: agora.getMonth() + 1 };

export default async function renderRelatorio(container, ctx) {
  container.innerHTML = `
    <div class="pagina-cabecalho">
      <div>
        <h1>Relatório mensal</h1>
        <p>Horas trabalhadas vs. esperadas — base para a folha de salários.</p>
      </div>
      <div class="accoes">
        <button type="button" class="botao botao-secundario" id="exportar-csv">Exportar CSV</button>
        <button type="button" class="botao botao-secundario" id="exportar-pdf">Exportar PDF</button>
      </div>
    </div>

    <div class="filtros">
      <label>Mês
        <select id="f-mes">
          ${MESES.map((m, i) =>
            `<option value="${i + 1}" ${seleccao.mes === i + 1 ? 'selected' : ''}>${m}</option>`
          ).join('')}
        </select>
      </label>
      <label>Ano
        <select id="f-ano">
          ${anosDisponiveis().map((a) =>
            `<option value="${a}" ${seleccao.ano === a ? 'selected' : ''}>${a}</option>`
          ).join('')}
        </select>
      </label>
      <button type="button" class="botao botao-primario" id="aplicar">Ver relatório</button>
    </div>

    <div id="resultado"><div class="carregando">A carregar…</div></div>
  `;

  const resultado = container.querySelector('#resultado');

  async function carregar() {
    resultado.innerHTML = '<div class="carregando">A carregar…</div>';
    try {
      const dados = await relatorioMensal(seleccao.ano, seleccao.mes);
      resultado.innerHTML = corpo(dados, ctx);
      resultado._dados = dados;
    } catch (e) {
      resultado.innerHTML = `<div class="alerta alerta-erro">${esc(mensagemDeErro(e))}</div>`;
    }
  }

  container.querySelector('#aplicar').addEventListener('click', () => {
    seleccao.mes = Number(container.querySelector('#f-mes').value);
    seleccao.ano = Number(container.querySelector('#f-ano').value);
    carregar();
  });

  container.querySelector('#exportar-csv').addEventListener('click', () => {
    const dados = resultado._dados;
    if (!dados?.linhas?.length) {
      notificar('Não há dados para exportar.', 'erro');
      return;
    }

    descarregarCsv(
      `salinas-relatorio-${dados.ano}-${String(dados.mes).padStart(2, '0')}.csv`,
      ['Funcionário', 'Email', 'Cargo', 'Horas trabalhadas', 'Horas esperadas', 'Saldo do mês', 'Banco de horas acumulado', 'Dias com entrada', 'Faltas sem justificação', 'Faltas justificadas', 'Faltas pendentes'],
      dados.linhas.map((l) => [
        l.nome,
        l.email,
        l.cargo ?? '',
        formatarNumero(l.horas_trabalhadas),
        formatarNumero(l.horas_esperadas),
        formatarNumero(l.saldo_horas),
        formatarNumero(l.saldo_banco_horas),
        l.dias_com_entrada,
        l.dias_sem_registo_nem_justificacao,
        l.faltas_justificadas,
        l.faltas_pendentes,
      ])
    );
  });

  container.querySelector('#exportar-pdf').addEventListener('click', exportarPdf);

  await carregar();
}

function corpo(dados, ctx) {
  const saldoTotal = Number(dados.total_horas_trabalhadas) - Number(dados.total_horas_esperadas);

  return `
    <h2>${MESES[dados.mes - 1]} de ${dados.ano} — ${esc(ctx.empresa.nome)}</h2>

    <div class="grelha-metricas">
      <div class="metrica">
        <div class="metrica-valor">${duracao(dados.total_horas_trabalhadas)}</div>
        <div class="metrica-rotulo">Total trabalhado</div>
      </div>
      <div class="metrica">
        <div class="metrica-valor">${duracao(dados.total_horas_esperadas)}</div>
        <div class="metrica-rotulo">Total esperado</div>
      </div>
      <div class="metrica">
        <div class="metrica-valor" style="color:${saldoTotal < 0 ? 'var(--erro)' : 'var(--sucesso)'}">
          ${duracao(saldoTotal)}
        </div>
        <div class="metrica-rotulo">Saldo do mês</div>
      </div>
      <div class="metrica">
        <div class="metrica-valor" style="color:${Number(dados.total_saldo_banco_horas) < 0 ? 'var(--erro)' : 'var(--sucesso)'}">
          ${duracao(dados.total_saldo_banco_horas)}
        </div>
        <div class="metrica-rotulo">Banco de horas acumulado</div>
      </div>
    </div>

    <div class="tabela-wrapper">
      <table>
        <thead>
          <tr>
            <th>Funcionário</th>
            <th>Cargo</th>
            <th class="numero">Trabalhado</th>
            <th class="numero">Esperado</th>
            <th class="numero">Saldo</th>
            <th class="numero">Dias</th>
            <th class="numero">Faltas s/ just.</th>
            <th class="numero">Banco de horas</th>
          </tr>
        </thead>
        <tbody>
          ${dados.linhas.map((l) => `
            <tr class="${l.ativo ? '' : 'inactivo'}">
              <td><strong>${esc(l.nome)}</strong></td>
              <td>${esc(l.cargo ?? '') || '—'}</td>
              <td class="numero">${duracao(l.horas_trabalhadas)}</td>
              <td class="numero">${duracao(l.horas_esperadas)}</td>
              <td class="numero" style="color:${Number(l.saldo_horas) < 0 ? 'var(--erro)' : 'var(--sucesso)'};font-weight:700">
                ${duracao(l.saldo_horas)}
              </td>
              <td class="numero">${l.dias_com_entrada}</td>
              <td class="numero" style="${l.dias_sem_registo_nem_justificacao > 0 ? 'color:var(--erro);font-weight:700' : ''}">
                ${l.dias_sem_registo_nem_justificacao || '—'}${l.faltas_pendentes > 0 ? ` <span class="etiqueta etiqueta-pausa">${l.faltas_pendentes} pend.</span>` : ''}
              </td>
              <td class="numero" style="color:${Number(l.saldo_banco_horas) < 0 ? 'var(--erro)' : 'var(--sucesso)'}">
                ${duracao(l.saldo_banco_horas)}
              </td>
            </tr>
          `).join('') || '<tr><td colspan="7" class="vazio">Sem funcionários.</td></tr>'}
        </tbody>
      </table>
    </div>

    <p class="nota" style="margin-top:14px">
      As horas esperadas vêm do horário definido por funcionário. Quando não há
      horário, estimam-se a partir das horas semanais do contrato. Os intervalos
      de pausa não contam como tempo de trabalho.
      <br />
      O <strong>saldo do mês</strong> é a diferença deste mês; o
      <strong>banco de horas</strong> é o acumulado ainda em aberto, de todos os
      períodos. Um saldo negativo é dívida de horas, não é falta — as faltas são
      contadas à parte, quando não há registo nem justificação num dia com horário.
    </p>
  `;
}

function formatarNumero(valor) {
  // Vírgula decimal — é o que o Excel em português espera.
  return String(valor ?? 0).replace('.', ',');
}

function anosDisponiveis() {
  const actual = new Date().getFullYear();
  return [actual, actual - 1, actual - 2];
}
