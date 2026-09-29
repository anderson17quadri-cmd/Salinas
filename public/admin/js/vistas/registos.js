import {
  adicionarRegisto,
  apagarRegisto,
  listarFuncionarios,
  listarRegistos,
  mensagemDeErro,
  urlAssinado,
} from '../api.js';
import {
  ROTULOS_METODO,
  ROTULOS_TIPO,
  abrirModal,
  dataHora,
  descarregarCsv,
  diaSeguinte,
  esc,
  exportarPdf,
  fecharModal,
  hojeIso,
  instanteNoFuso,
  notificar,
} from '../ui.js';

// Estado dos filtros, preservado entre re-renderizações da vista.
const filtros = {
  de: primeiroDiaDoMes(),
  ate: hojeIso(),
  funcionarioId: '',
  tipo: '',
};

export default async function renderRegistos(container, ctx) {
  const funcionarios = await listarFuncionarios();
  const porId = Object.fromEntries(funcionarios.map((f) => [f.id, f]));

  container.innerHTML = `
    <div class="pagina-cabecalho">
      <div>
        <h1>Registos de ponto</h1>
        <p>Horas apresentadas no fuso ${esc(ctx.timezone)}.</p>
      </div>
      <div class="accoes">
        <button type="button" class="botao botao-primario" id="acrescentar">Acrescentar registo</button>
        <button type="button" class="botao botao-secundario" id="exportar-csv">Exportar CSV</button>
        <button type="button" class="botao botao-secundario" id="exportar-pdf">Exportar PDF</button>
      </div>
    </div>

    <div class="filtros">
      <label>De <input type="date" id="f-de" value="${filtros.de}" /></label>
      <label>Até <input type="date" id="f-ate" value="${filtros.ate}" /></label>
      <label>Funcionário
        <select id="f-funcionario">
          <option value="">Todos</option>
          ${funcionarios.map((f) =>
            `<option value="${f.id}" ${filtros.funcionarioId === f.id ? 'selected' : ''}>${esc(f.nome)}</option>`
          ).join('')}
        </select>
      </label>
      <label>Tipo
        <select id="f-tipo">
          <option value="">Todos</option>
          ${Object.entries(ROTULOS_TIPO).map(([v, r]) =>
            `<option value="${v}" ${filtros.tipo === v ? 'selected' : ''}>${r}</option>`
          ).join('')}
        </select>
      </label>
      <button type="button" class="botao botao-primario" id="aplicar">Aplicar</button>
    </div>

    <div id="resultado"><div class="carregando">A carregar…</div></div>
  `;

  const resultado = container.querySelector('#resultado');

  async function carregar() {
    resultado.innerHTML = '<div class="carregando">A carregar…</div>';
    try {
      const registos = await listarRegistos({
        de: instanteNoFuso(filtros.de, '00:00', ctx.timezone),
        ate: instanteNoFuso(diaSeguinte(filtros.ate), '00:00', ctx.timezone),
        funcionarioId: filtros.funcionarioId || null,
        tipo: filtros.tipo || null,
      });

      resultado.innerHTML = tabela(registos, porId, ctx.timezone);
      ligarAnexos(resultado);
      ligarApagar(resultado, registos, porId, ctx, carregar);
      resultado._registos = registos;
    } catch (e) {
      resultado.innerHTML = `<div class="alerta alerta-erro">${esc(mensagemDeErro(e))}</div>`;
    }
  }

  container.querySelector('#aplicar').addEventListener('click', () => {
    filtros.de = container.querySelector('#f-de').value;
    filtros.ate = container.querySelector('#f-ate').value;
    filtros.funcionarioId = container.querySelector('#f-funcionario').value;
    filtros.tipo = container.querySelector('#f-tipo').value;
    carregar();
  });

  container.querySelector('#exportar-csv').addEventListener('click', () => {
    const registos = resultado._registos ?? [];
    if (!registos.length) {
      notificar('Não há registos para exportar.', 'erro');
      return;
    }

    descarregarCsv(
      `salinas-registos-${filtros.de}-a-${filtros.ate}.csv`,
      ['Funcionário', 'Email', 'Data e hora', 'Tipo', 'Método', 'Dentro do raio', 'Distância (m)', 'Latitude', 'Longitude', 'Observação'],
      registos.map((r) => {
        const f = porId[r.funcionario_id];
        return [
          f?.nome ?? '—',
          f?.email ?? '',
          dataHora(r.timestamp, ctx.timezone),
          ROTULOS_TIPO[r.tipo] ?? r.tipo,
          ROTULOS_METODO[r.metodo] ?? r.metodo,
          r.dentro_do_raio == null ? '' : r.dentro_do_raio ? 'Sim' : 'Não',
          r.distancia_metros ?? '',
          r.latitude ?? '',
          r.longitude ?? '',
          r.observacao ?? '',
        ];
      })
    );
  });

  container.querySelector('#exportar-pdf').addEventListener('click', exportarPdf);

  container.querySelector('#acrescentar').addEventListener('click', () =>
    formularioAcrescentar(funcionarios, ctx, carregar)
  );

  await carregar();
}

function tabela(registos, porId, tz) {
  if (!registos.length) {
    return '<div class="tabela-wrapper"><div class="vazio">Nenhum registo neste intervalo.</div></div>';
  }

  return `
    <p class="nota nao-imprimir">${registos.length} registo(s).</p>
    <div class="tabela-wrapper">
      <table>
        <thead>
          <tr>
            <th>Funcionário</th>
            <th>Data e hora</th>
            <th>Tipo</th>
            <th>Método</th>
            <th>Localização</th>
            <th>Observação</th>
            <th class="nao-imprimir"></th>
          </tr>
        </thead>
        <tbody>
          ${registos.map((r) => {
            const f = porId[r.funcionario_id];
            return `
              <tr>
                <td><strong>${esc(f?.nome ?? '—')}</strong></td>
                <td>${esc(dataHora(r.timestamp, tz))}</td>
                <td>${esc(ROTULOS_TIPO[r.tipo] ?? r.tipo)}</td>
                <td>
                  ${esc(ROTULOS_METODO[r.metodo] ?? r.metodo)}
                  ${r.foto_url ? `<br /><button type="button" class="ligacao nao-imprimir" data-anexo="${esc(r.foto_url)}">ver foto</button>` : ''}
                </td>
                <td>${localizacao(r)}</td>
                <td>${esc(r.observacao ?? '') || '—'}</td>
                <td class="accoes nao-imprimir">
                  <button type="button" class="ligacao" data-apagar="${esc(r.id)}">Apagar</button>
                </td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  `;
}

function localizacao(r) {
  if (r.dentro_do_raio === false) {
    const dist = r.distancia_metros != null ? ` (${Math.round(r.distancia_metros)} m)` : '';
    return `<span class="etiqueta etiqueta-erro">Fora do raio${esc(dist)}</span>`;
  }
  if (r.dentro_do_raio === true) {
    return '<span class="etiqueta etiqueta-dentro">Dentro do raio</span>';
  }
  return '<span style="color:var(--texto-suave)">—</span>';
}

function ligarAnexos(raiz) {
  raiz.querySelectorAll('[data-anexo]').forEach((b) =>
    b.addEventListener('click', async () => {
      try {
        window.open(await urlAssinado('registos-ponto', b.dataset.anexo), '_blank', 'noopener');
      } catch (e) {
        notificar(mensagemDeErro(e, 'Não foi possível abrir a foto.'), 'erro');
      }
    })
  );
}

// ---------------------------------------------------------------------
// Correcções
// ---------------------------------------------------------------------
// Caso típico: alguém esqueceu-se de bater a saída e hoje a app não o
// deixa entrar. Acrescenta-se a saída em falta à hora certa. O servidor
// recusa qualquer correcção que deixe a sequência errada.
function formularioAcrescentar(funcionarios, ctx, aoGravar) {
  const activos = funcionarios.filter((f) => f.ativo);
  const modal = abrirModal(`
    <h2>Acrescentar registo</h2>
    <p class="nota">Por exemplo, a saída que alguém se esqueceu de bater.
      Fica marcado como «${esc(ROTULOS_METODO.manual)}», com o motivo.</p>
    <form class="formulario" id="form-acrescentar">
      <label>Funcionário
        <select name="funcionario" required>
          <option value="">Escolher…</option>
          ${activos.map((f) => `<option value="${esc(f.id)}">${esc(f.nome)}</option>`).join('')}
        </select>
      </label>
      <label>Tipo
        <select name="tipo" required>
          ${Object.entries(ROTULOS_TIPO).map(([v, r]) =>
            `<option value="${v}" ${v === 'saida' ? 'selected' : ''}>${esc(r)}</option>`
          ).join('')}
        </select>
      </label>
      <div class="filtros" style="padding:0;border:none;background:none;margin:0">
        <label>Dia <input type="date" name="data" value="${hojeIso()}" max="${hojeIso()}" required /></label>
        <label>Hora <input type="time" name="hora" required /></label>
      </div>
      <label>Motivo
        <input type="text" name="motivo" maxlength="200" required
               placeholder="Ex.: esqueceu-se de bater a saída" />
      </label>
      <div class="alerta alerta-erro oculto" id="erro-acrescentar"></div>
      <div class="modal-accoes">
        <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Gravar</button>
      </div>
    </form>
  `);

  const form = modal.querySelector('#form-acrescentar');
  const erro = modal.querySelector('#erro-acrescentar');

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    erro.classList.add('oculto');
    const botao = form.querySelector('[type="submit"]');
    botao.disabled = true;
    try {
      await adicionarRegisto({
        funcionarioId: form.funcionario.value,
        tipo: form.tipo.value,
        timestamp: instanteNoFuso(form.data.value, form.hora.value, ctx.timezone),
        motivo: form.motivo.value.trim(),
      });
      fecharModal();
      notificar('Registo acrescentado.', 'sucesso');
      aoGravar();
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2);
      erro.classList.remove('oculto');
    } finally {
      botao.disabled = false;
    }
  });
}

function ligarApagar(raiz, registos, porId, ctx, aoApagar) {
  const porRegisto = Object.fromEntries(registos.map((r) => [r.id, r]));

  raiz.querySelectorAll('[data-apagar]').forEach((b) =>
    b.addEventListener('click', () => {
      const r = porRegisto[b.dataset.apagar];
      const modal = abrirModal(`
        <h2>Apagar registo</h2>
        <p><strong>${esc(porId[r.funcionario_id]?.nome ?? '—')}</strong> ·
          ${esc(ROTULOS_TIPO[r.tipo] ?? r.tipo)} ·
          ${esc(dataHora(r.timestamp, ctx.timezone))}</p>
        <p class="nota">O registo sai das contas, mas fica guardado no histórico
          de correcções, com o motivo.</p>
        <form class="formulario" id="form-apagar">
          <label>Motivo
            <input type="text" name="motivo" maxlength="200" required
                   placeholder="Ex.: entrada batida por engano" />
          </label>
          <div class="alerta alerta-erro oculto" id="erro-apagar"></div>
          <div class="modal-accoes">
            <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
            <button type="submit" class="botao botao-perigo">Apagar</button>
          </div>
        </form>
      `);

      const form = modal.querySelector('#form-apagar');
      const erro = modal.querySelector('#erro-apagar');
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        erro.classList.add('oculto');
        try {
          await apagarRegisto(r.id, form.motivo.value.trim());
          fecharModal();
          notificar('Registo apagado.', 'sucesso');
          aoApagar();
        } catch (e2) {
          erro.textContent = mensagemDeErro(e2);
          erro.classList.remove('oculto');
        }
      });
    })
  );
}

function primeiroDiaDoMes() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
}
