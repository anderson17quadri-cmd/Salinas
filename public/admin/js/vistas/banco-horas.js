import {
  bancoHoras,
  fecharPeriodoBancoHoras,
  liquidarMovimentoBancoHoras,
  mensagemDeErro,
  movimentosBancoHoras,
  registarMovimentoBancoHoras,
} from '../api.js';
import {
  MESES,
  abrirModal,
  confirmar,
  descarregarCsv,
  duracao,
  esc,
  fecharModal,
  notificar,
} from '../ui.js';

const ROTULOS_POLITICA = {
  apenas_reportar: 'Apenas reportar',
  compensar_folga: 'Compensar com folga',
  desconto_automatico: 'Descontar no salário',
  pagar_extra: 'Pagar como horas extra',
};

const DESCRICOES_POLITICA = {
  apenas_reportar: 'O saldo é apenas informativo — nenhuma acção automática.',
  compensar_folga: 'O crédito de horas pode ser convertido em dias de folga.',
  desconto_automatico: 'A dívida de horas é descontada no relatório de salário.',
  pagar_extra: 'O crédito de horas é sinalizado para pagamento de horas extra.',
};

const ROTULOS_ESTADO = {
  aberto: 'Aberto',
  compensado: 'Compensado',
  pago: 'Pago',
  descontado: 'Descontado',
};

const CLASSES_ESTADO = {
  aberto: 'etiqueta-primaria',
  compensado: 'etiqueta-dentro',
  pago: 'etiqueta-dentro',
  descontado: 'etiqueta-fora',
};

export default async function renderBancoHoras(container, ctx) {
  const dados = await bancoHoras();

  const mesAnterior = new Date();
  mesAnterior.setDate(1);
  mesAnterior.setMonth(mesAnterior.getMonth() - 1);

  container.innerHTML = `
    <div class="pagina-cabecalho">
      <div>
        <h1>Banco de Horas</h1>
        <p>
          Política: <strong>${esc(ROTULOS_POLITICA[dados.politica] ?? dados.politica)}</strong>
          · limite de compensação: ${dados.limite_compensacao_meses} meses
        </p>
      </div>
      <div class="accoes">
        <button type="button" class="botao botao-secundario" id="exportar-csv">Exportar CSV</button>
        <button type="button" class="botao botao-primario" id="fechar-periodo">Fechar período</button>
      </div>
    </div>

    <p class="nota" style="margin:-8px 0 18px">
      ${esc(DESCRICOES_POLITICA[dados.politica] ?? '')}
      A política muda-se em <strong>Definições</strong>.
    </p>

    ${dados.fora_do_prazo > 0 ? `
      <div class="alerta alerta-aviso" style="margin-bottom:18px">
        ${dados.fora_do_prazo} funcionário(s) com saldo acumulado há mais de
        ${dados.limite_compensacao_meses} meses. Estes saldos têm de ser decididos —
        pagos, compensados ou renegociados.
      </div>` : ''}

    <div class="grelha-metricas">
      <div class="metrica">
        <div class="metrica-valor" style="color:var(--sucesso)">${duracao(dados.total_credito)}</div>
        <div class="metrica-rotulo">Crédito total</div>
      </div>
      <div class="metrica">
        <div class="metrica-valor" style="color:var(--erro)">${duracao(dados.total_divida)}</div>
        <div class="metrica-rotulo">Dívida total</div>
      </div>
      <div class="metrica">
        <div class="metrica-valor" style="color:${Number(dados.total_saldo) < 0 ? 'var(--erro)' : 'var(--sucesso)'}">
          ${duracao(dados.total_saldo)}
        </div>
        <div class="metrica-rotulo">Saldo líquido</div>
      </div>
      <div class="metrica">
        <div class="metrica-valor" style="color:${dados.fora_do_prazo > 0 ? 'var(--aviso)' : 'var(--texto)'}">
          ${dados.fora_do_prazo}
        </div>
        <div class="metrica-rotulo">Fora do prazo</div>
      </div>
    </div>

    <div class="tabela-wrapper">
      <table>
        <thead>
          <tr>
            <th>Funcionário</th>
            <th>Cargo</th>
            <th class="numero">Saldo</th>
            <th class="numero">Crédito</th>
            <th class="numero">Dívida</th>
            <th class="numero">Movimentos</th>
            <th>Mais antigo</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${dados.linhas.map(linha).join('')
            || '<tr><td colspan="8" class="vazio">Ainda não há funcionários.</td></tr>'}
        </tbody>
      </table>
    </div>
  `;

  container.querySelector('#fechar-periodo')
    .addEventListener('click', () => formularioFecho(container, ctx, mesAnterior));

  container.querySelector('#exportar-csv').addEventListener('click', () => {
    if (!dados.linhas.length) {
      notificar('Não há dados para exportar.', 'erro');
      return;
    }
    descarregarCsv(
      `salinas-banco-horas-${new Date().toISOString().slice(0, 10)}.csv`,
      ['Funcionário', 'Cargo', 'Saldo (h)', 'Crédito (h)', 'Dívida (h)', 'Movimentos abertos', 'Período mais antigo', 'Fora do prazo'],
      dados.linhas.map((l) => [
        l.nome,
        l.cargo ?? '',
        String(l.saldo).replace('.', ','),
        String(l.credito).replace('.', ','),
        String(l.divida).replace('.', ','),
        l.movimentos_abertos,
        l.periodo_mais_antigo ?? '',
        l.fora_do_prazo ? 'Sim' : 'Não',
      ])
    );
  });

  container.querySelectorAll('[data-historico]').forEach((b) =>
    b.addEventListener('click', () => verHistorico(b.dataset.historico, container, ctx))
  );

  container.querySelectorAll('[data-lancar]').forEach((b) =>
    b.addEventListener('click', () => {
      const l = dados.linhas.find((x) => x.funcionario_id === b.dataset.lancar);
      formularioMovimento(l, container, ctx);
    })
  );
}

function linha(l) {
  const saldo = Number(l.saldo);
  const cor = saldo < 0 ? 'var(--erro)' : saldo > 0 ? 'var(--sucesso)' : 'var(--texto-suave)';

  return `
    <tr class="${l.ativo ? '' : 'inactivo'}">
      <td>
        <strong>${esc(l.nome)}</strong>
        ${l.fora_do_prazo ? '<br /><span class="etiqueta etiqueta-pausa">fora do prazo</span>' : ''}
      </td>
      <td>${esc(l.cargo) || '—'}</td>
      <td class="numero" style="color:${cor};font-weight:700">${duracao(l.saldo)}</td>
      <td class="numero" style="color:var(--sucesso)">${Number(l.credito) ? duracao(l.credito) : '—'}</td>
      <td class="numero" style="color:var(--erro)">${Number(l.divida) ? duracao(l.divida) : '—'}</td>
      <td class="numero">${l.movimentos_abertos}</td>
      <td>${l.periodo_mais_antigo ? esc(periodoLegivel(l.periodo_mais_antigo)) : '—'}</td>
      <td class="accoes">
        <button type="button" class="botao botao-texto botao-pequeno" data-historico="${l.funcionario_id}">Histórico</button>
        <button type="button" class="botao botao-texto botao-pequeno" data-lancar="${l.funcionario_id}">Lançar</button>
      </td>
    </tr>
  `;
}

function periodoLegivel(data) {
  const [ano, mes] = String(data).split('-');
  return `${MESES[Number(mes) - 1]} ${ano}`;
}

// ---------------------------------------------------------------------
// Fechar um período
// ---------------------------------------------------------------------
function formularioFecho(container, ctx, sugestao) {
  const anoActual = new Date().getFullYear();

  const modal = abrirModal(`
    <h2>Fechar período</h2>
    <p class="nota">
      Calcula, para cada funcionário, as horas trabalhadas e as esperadas no mês
      escolhido e grava o saldo no banco de horas. Pode voltar a correr para o
      mesmo mês — o movimento é actualizado em vez de duplicado. Períodos já
      pagos ou compensados não são tocados.
    </p>
    <form class="formulario" id="form-fecho" style="margin-top:16px">
      <div class="filtros" style="padding:0;border:none;background:none;margin:0">
        <label>Mês
          <select name="mes">
            ${MESES.map((m, i) =>
              `<option value="${i + 1}" ${sugestao.getMonth() === i ? 'selected' : ''}>${m}</option>`
            ).join('')}
          </select>
        </label>
        <label>Ano
          <select name="ano">
            ${[anoActual, anoActual - 1, anoActual - 2].map((a) =>
              `<option value="${a}" ${sugestao.getFullYear() === a ? 'selected' : ''}>${a}</option>`
            ).join('')}
          </select>
        </label>
      </div>
      <div class="alerta alerta-erro oculto" id="erro-fecho"></div>
      <div class="modal-accoes">
        <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Fechar período</button>
      </div>
    </form>
  `);

  modal.querySelector('#form-fecho').addEventListener('submit', async (e) => {
    e.preventDefault();
    const erro = modal.querySelector('#erro-fecho');
    erro.classList.add('oculto');

    try {
      const res = await fecharPeriodoBancoHoras(Number(e.target.ano.value), Number(e.target.mes.value));
      fecharModal();

      const ignorados = res.ignorados_nomes ?? [];
      notificar(
        `${res.gravados} movimento(s) gravado(s)`
          + (res.ignorados ? `; ${res.ignorados} ignorado(s) por já estarem liquidados: ${ignorados.join(', ')}` : '.'),
        res.ignorados ? 'info' : 'sucesso'
      );
      renderBancoHoras(container, ctx);
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2);
      erro.classList.remove('oculto');
    }
  });
}

// ---------------------------------------------------------------------
// Histórico de movimentos
// ---------------------------------------------------------------------
async function verHistorico(funcionarioId, container, ctx) {
  const dados = await movimentosBancoHoras(funcionarioId);

  const modal = abrirModal(`
    <h2>${esc(dados.nome)}</h2>
    <p class="nota" style="text-align:center;margin-bottom:16px">
      Saldo actual: <strong style="color:${Number(dados.saldo) < 0 ? 'var(--erro)' : 'var(--sucesso)'}">
        ${duracao(dados.saldo)}
      </strong>
    </p>

    <div class="tabela-wrapper">
      <table>
        <thead>
          <tr>
            <th>Período</th>
            <th class="numero">Trabalhado</th>
            <th class="numero">Esperado</th>
            <th class="numero">Saldo</th>
            <th>Estado</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${dados.movimentos.map((m) => `
            <tr>
              <td>
                ${esc(periodoLegivel(m.periodo_referencia))}
                ${m.manual ? '<br /><span class="nota">manual</span>' : ''}
                ${m.observacao ? `<br /><span class="nota">${esc(m.observacao)}</span>` : ''}
              </td>
              <td class="numero">${m.manual ? '—' : duracao(m.horas_trabalhadas)}</td>
              <td class="numero">${m.manual ? '—' : duracao(m.horas_esperadas)}</td>
              <td class="numero" style="color:${Number(m.saldo) < 0 ? 'var(--erro)' : 'var(--sucesso)'};font-weight:700">
                ${duracao(m.saldo)}
              </td>
              <td><span class="etiqueta ${CLASSES_ESTADO[m.status]}">${ROTULOS_ESTADO[m.status]}</span></td>
              <td class="accoes">
                ${m.status === 'aberto' ? `
                  <select class="liquidar-estado" data-movimento="${m.id}" style="margin:0;min-width:130px">
                    <option value="">Liquidar…</option>
                    <option value="compensado">Compensado</option>
                    <option value="pago">Pago</option>
                    <option value="descontado">Descontado</option>
                  </select>` : `
                  <button type="button" class="botao botao-texto botao-pequeno" data-reabrir="${m.id}">Reabrir</button>`}
              </td>
            </tr>
          `).join('') || '<tr><td colspan="6" class="vazio">Sem movimentos.</td></tr>'}
        </tbody>
      </table>
    </div>

    <div class="modal-accoes">
      <button type="button" class="botao botao-secundario" data-fechar>Fechar</button>
    </div>
  `);

  modal.querySelectorAll('.liquidar-estado').forEach((sel) =>
    sel.addEventListener('change', async () => {
      if (!sel.value) return;
      const rotulo = ROTULOS_ESTADO[sel.value].toLowerCase();

      const ok = await confirmar(
        'Liquidar movimento',
        `Marcar como ${rotulo}. O saldo deixa de contar para o acumulado, `
          + 'mas o movimento continua no histórico.',
        'Liquidar'
      );
      if (!ok) {
        sel.value = '';
        return;
      }

      try {
        await liquidarMovimentoBancoHoras(sel.dataset.movimento, sel.value);
        fecharModal();
        notificar('Movimento liquidado.', 'sucesso');
        renderBancoHoras(container, ctx);
      } catch (e) {
        notificar(mensagemDeErro(e), 'erro');
      }
    })
  );

  modal.querySelectorAll('[data-reabrir]').forEach((b) =>
    b.addEventListener('click', async () => {
      const ok = await confirmar(
        'Reabrir movimento',
        'O saldo volta a contar para o acumulado do funcionário.',
        'Reabrir'
      );
      if (!ok) return;

      try {
        await liquidarMovimentoBancoHoras(b.dataset.reabrir, 'aberto');
        fecharModal();
        notificar('Movimento reaberto.', 'sucesso');
        renderBancoHoras(container, ctx);
      } catch (e) {
        notificar(mensagemDeErro(e), 'erro');
      }
    })
  );
}

// ---------------------------------------------------------------------
// Lançar um movimento manual
// ---------------------------------------------------------------------
function formularioMovimento(funcionario, container, ctx) {
  const modal = abrirModal(`
    <h2>Lançar movimento — ${esc(funcionario.nome)}</h2>
    <p class="nota">
      Para acertos fora do fecho automático: pagar horas extra, dar uma folga a
      partir do crédito, ou corrigir um acerto combinado.
      <strong>Positivo</strong> acrescenta crédito, <strong>negativo</strong> desconta —
      uma folga de 8 h lança-se como <code>-8</code>.
    </p>

    <form class="formulario" id="form-movimento" style="margin-top:16px">
      <label>Horas
        <input type="number" name="saldo" step="0.25" placeholder="-8" required />
      </label>

      <label>Estado
        <select name="estado">
          <option value="aberto">Aberto — conta para o saldo</option>
          <option value="compensado">Compensado — já resolvido com folga</option>
          <option value="pago">Pago — já liquidado em dinheiro</option>
          <option value="descontado">Descontado — já reflectido no salário</option>
        </select>
      </label>

      <label>Observação
        <input type="text" name="observacao" placeholder="Folga de 8 h a 14/08" />
      </label>

      <div class="alerta alerta-erro oculto" id="erro-movimento"></div>
      <div class="modal-accoes">
        <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Lançar</button>
      </div>
    </form>
  `);

  modal.querySelector('#form-movimento').addEventListener('submit', async (e) => {
    e.preventDefault();
    const erro = modal.querySelector('#erro-movimento');
    erro.classList.add('oculto');

    const saldo = Number(e.target.saldo.value);
    if (!saldo) {
      erro.textContent = 'Indique quantas horas quer lançar (positivo ou negativo).';
      erro.classList.remove('oculto');
      return;
    }

    try {
      await registarMovimentoBancoHoras({
        funcionarioId: funcionario.funcionario_id,
        saldo,
        estado: e.target.estado.value,
        observacao: e.target.observacao.value.trim() || null,
      });
      fecharModal();
      notificar('Movimento lançado.', 'sucesso');
      renderBancoHoras(container, ctx);
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2);
      erro.classList.remove('oculto');
    }
  });
}
