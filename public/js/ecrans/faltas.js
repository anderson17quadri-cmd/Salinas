import {
  carregarFicheiro,
  criarJustificacoes,
  estadoAtual,
  listarJustificacoes,
  mensagemDeErro,
} from '../api.js';
import { dataCurta, esc, hojeIso, notificar, vazio } from '../ui.js';

const ROTULOS_ESTADO = { pendente: 'Pendente', aprovado: 'Aprovado', rejeitado: 'Rejeitado' };
const CLASSES_ESTADO = {
  pendente: 'etiqueta-pausa',
  aprovado: 'etiqueta-dentro',
  rejeitado: 'etiqueta-erro',
};

export default async function renderFaltas(container, ctx) {
  const estado = ctx.estado ?? (ctx.estado = await estadoAtual());
  const pedidos = await listarJustificacoes(estado.funcionario.id);

  container.innerHTML = `
    <div class="cabecalho-app">
      <h1 class="titulo">Justificar falta</h1>
    </div>

    <form class="cartao" id="form-falta" style="margin-bottom:22px">
      <div class="formulario">
        <div class="linha-datas">
          <label>Dia
            <input type="date" name="data" value="${hojeIso()}" required />
          </label>
          <label>Até (opcional)
            <input type="date" name="ate" />
          </label>
        </div>
        <p class="nota" style="margin:-4px 0 0">Para férias ou vários dias seguidos, preencha também «Até». Pode pedir com antecedência.</p>

        <label>Motivo
          <textarea name="motivo" placeholder="Consulta médica, doença, assunto pessoal…" required></textarea>
        </label>

        <label>Comprovativo (opcional)
          <input type="file" name="anexo" accept="image/*,application/pdf" />
        </label>

        <div class="alerta alerta-erro oculto" id="erro"></div>
        <button type="submit" class="botao botao-primario" id="submeter">Enviar pedido</button>
      </div>
    </form>

    <h2 class="subtitulo">Pedidos anteriores</h2>
    <div id="lista">
      ${pedidos.length
        ? pedidos.map(cartaoPedido).join('')
        : vazio('Sem pedidos', 'Ainda não submeteu nenhuma justificação.')}
    </div>
  `;

  const form = container.querySelector('#form-falta');
  const erro = container.querySelector('#erro');
  const botao = container.querySelector('#submeter');

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    erro.classList.add('oculto');

    const dataFalta = form.data.value;
    const ate = form.ate.value || dataFalta;
    const motivo = form.motivo.value.trim();

    if (!dataFalta) {
      mostrarErro('Escolha a data da falta.');
      return;
    }
    if (ate < dataFalta) {
      mostrarErro('A data «Até» não pode ser antes do primeiro dia.');
      return;
    }
    const datas = diasEntre(dataFalta, ate);
    if (datas.length > 62) {
      mostrarErro('Um pedido pode ter no máximo 62 dias. Divida em dois pedidos.');
      return;
    }
    if (!motivo) {
      mostrarErro('Descreva o motivo da falta.');
      return;
    }

    botao.disabled = true;
    botao.textContent = 'A enviar…';

    try {
      let anexoUrl = null;
      const ficheiro = form.anexo.files?.[0];

      if (ficheiro) {
        if (ficheiro.size > 10 * 1024 * 1024) {
          mostrarErro('O comprovativo não pode exceder 10 MB.');
          return;
        }
        anexoUrl = await carregarFicheiro({
          bucket: 'justificacoes',
          empresaId: estado.empresa.id,
          funcionarioId: estado.funcionario.id,
          ficheiro,
        });
      }

      await criarJustificacoes({
        funcionarioId: estado.funcionario.id,
        datas,
        motivo,
        anexoUrl,
      });

      notificar(
        datas.length > 1
          ? `Pedido enviado para ${datas.length} dias. O seu gestor vai analisá-lo.`
          : 'Pedido enviado. O seu gestor vai analisá-lo.',
        'sucesso'
      );
      renderFaltas(container, ctx);
    } catch (e2) {
      mostrarErro(mensagemDeErro(e2, 'Não foi possível enviar o pedido.'));
    } finally {
      botao.disabled = false;
      botao.textContent = 'Enviar pedido';
    }
  });

  function mostrarErro(texto) {
    erro.textContent = texto;
    erro.classList.remove('oculto');
    botao.disabled = false;
    botao.textContent = 'Enviar pedido';
  }
}

function cartaoPedido(p) {
  return `
    <div class="cartao" style="margin-bottom:10px">
      <div class="linha-estado">
        <strong>${esc(dataCurta(p.data))}</strong>
        <span class="etiqueta ${CLASSES_ESTADO[p.status]}">${ROTULOS_ESTADO[p.status]}</span>
      </div>
      <p class="nota" style="margin:10px 0 0">${esc(p.motivo ?? '')}</p>
      ${p.anexo_url ? '<p class="nota" style="margin:6px 0 0">Com comprovativo anexado.</p>' : ''}
    </div>
  `;
}

/** Todas as datas "AAAA-MM-DD" de `de` a `ate`, inclusive. */
function diasEntre(de, ate) {
  const datas = [];
  const d = new Date(`${de}T12:00:00Z`);
  const fim = new Date(`${ate}T12:00:00Z`);
  while (d <= fim && datas.length <= 62) {
    datas.push(d.toISOString().slice(0, 10));
    d.setUTCDate(d.getUTCDate() + 1);
  }
  return datas;
}
