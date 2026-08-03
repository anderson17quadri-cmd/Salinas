import { listarFuncionarios, listarRegistos, mensagemDeErro, urlAssinado } from '../api.js';
import {
  ROTULOS_METODO,
  ROTULOS_TIPO,
  dataHora,
  descarregarCsv,
  esc,
  exportarPdf,
  hojeIso,
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
        de: `${filtros.de}T00:00:00`,
        ate: `${filtros.ate}T23:59:59.999`,
        funcionarioId: filtros.funcionarioId || null,
        tipo: filtros.tipo || null,
      });

      resultado.innerHTML = tabela(registos, porId, ctx.timezone);
      ligarAnexos(resultado);
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

function primeiroDiaDoMes() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
}
