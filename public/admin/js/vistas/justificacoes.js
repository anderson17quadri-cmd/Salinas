import {
  listarFuncionarios,
  listarJustificacoes,
  mensagemDeErro,
  reverJustificacao,
  urlAssinado,
} from '../api.js';
import { confirmar, dataCurta, dataHora, esc, notificar } from '../ui.js';

const ROTULOS_ESTADO = {
  pendente: 'Pendente',
  aprovado: 'Aprovado',
  rejeitado: 'Rejeitado',
};

const CLASSES_ESTADO = {
  pendente: 'etiqueta-pausa',
  aprovado: 'etiqueta-dentro',
  rejeitado: 'etiqueta-erro',
};

let filtroEstado = 'pendente';

export default async function renderJustificacoes(container, ctx) {
  const [funcionarios, pedidos] = await Promise.all([
    listarFuncionarios(),
    listarJustificacoes(filtroEstado || null),
  ]);
  const porId = Object.fromEntries(funcionarios.map((f) => [f.id, f]));

  container.innerHTML = `
    <div class="pagina-cabecalho">
      <div>
        <h1>Justificações</h1>
        <p>Pedidos de justificação de falta ou atraso submetidos pelos funcionários.</p>
      </div>
    </div>

    <div class="filtros">
      <label>Estado
        <select id="f-estado">
          <option value="pendente" ${filtroEstado === 'pendente' ? 'selected' : ''}>Pendentes</option>
          <option value="aprovado" ${filtroEstado === 'aprovado' ? 'selected' : ''}>Aprovados</option>
          <option value="rejeitado" ${filtroEstado === 'rejeitado' ? 'selected' : ''}>Rejeitados</option>
          <option value="" ${filtroEstado === '' ? 'selected' : ''}>Todos</option>
        </select>
      </label>
    </div>

    <div class="tabela-wrapper">
      <table>
        <thead>
          <tr>
            <th>Funcionário</th>
            <th>Data da falta</th>
            <th>Motivo</th>
            <th>Submetido</th>
            <th>Anexo</th>
            <th>Estado</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${pedidos.map((p) => linha(p, porId, ctx.timezone)).join('')
            || '<tr><td colspan="7" class="vazio">Nenhum pedido nesta categoria.</td></tr>'}
        </tbody>
      </table>
    </div>
  `;

  container.querySelector('#f-estado').addEventListener('change', (e) => {
    filtroEstado = e.target.value;
    renderJustificacoes(container, ctx);
  });

  container.querySelectorAll('[data-anexo]').forEach((b) =>
    b.addEventListener('click', async () => {
      try {
        window.open(await urlAssinado('justificacoes', b.dataset.anexo), '_blank', 'noopener');
      } catch (e) {
        notificar(mensagemDeErro(e, 'Não foi possível abrir o anexo.'), 'erro');
      }
    })
  );

  container.querySelectorAll('[data-decidir]').forEach((b) =>
    b.addEventListener('click', async () => {
      const { decidir: id, estado } = b.dataset;
      const p = pedidos.find((x) => x.id === id);
      const nome = porId[p.funcionario_id]?.nome ?? 'funcionário';

      const ok = await confirmar(
        estado === 'aprovado' ? 'Aprovar justificação' : 'Rejeitar justificação',
        `${nome} — falta de ${dataCurta(p.data)}.`,
        estado === 'aprovado' ? 'Aprovar' : 'Rejeitar'
      );
      if (!ok) return;

      try {
        await reverJustificacao(id, estado);
        notificar(estado === 'aprovado' ? 'Justificação aprovada.' : 'Justificação rejeitada.', 'sucesso');
        renderJustificacoes(container, ctx);
      } catch (e) {
        notificar(mensagemDeErro(e), 'erro');
      }
    })
  );
}

function linha(p, porId, tz) {
  const f = porId[p.funcionario_id];
  return `
    <tr>
      <td><strong>${esc(f?.nome ?? '—')}</strong></td>
      <td>${esc(dataCurta(p.data))}</td>
      <td style="max-width:320px">${esc(p.motivo ?? '') || '—'}</td>
      <td>${esc(dataHora(p.created_at, tz))}</td>
      <td>${p.anexo_url
        ? `<button type="button" class="ligacao" data-anexo="${esc(p.anexo_url)}">ver</button>`
        : '—'}</td>
      <td><span class="etiqueta ${CLASSES_ESTADO[p.status]}">${ROTULOS_ESTADO[p.status]}</span></td>
      <td class="accoes">
        ${p.status === 'pendente' ? `
          <button type="button" class="botao botao-texto botao-pequeno" data-decidir="${p.id}" data-estado="aprovado">Aprovar</button>
          <button type="button" class="botao botao-texto botao-pequeno" data-decidir="${p.id}" data-estado="rejeitado">Rejeitar</button>
        ` : `<span class="nota">${esc(dataHora(p.revisto_em, tz))}</span>`}
      </td>
    </tr>
  `;
}
