import { dashboardHoje } from '../api.js';
import { esc, etiquetaEstado } from '../ui.js';

export default async function renderDashboard(container, ctx) {
  const dados = await dashboardHoje();
  const tz = dados.timezone || ctx.timezone;

  // Em regime rotativo só se sabe se um dia sem ponto era folga ou falta
  // no fim do próprio dia — enquanto está a decorrer, pode ser só que a
  // pessoa ainda não chegou, ou que calhou ser o dia de folga dela.
  const rotativo = dados.regime_folgas === 'rotativo';

  const metricas = [
    { valor: dados.dentro, rotulo: 'Ao serviço agora', cor: 'var(--sucesso)' },
    { valor: dados.em_pausa, rotulo: 'Em pausa', cor: 'var(--aviso)' },
    { valor: dados.fora, rotulo: 'Fora de serviço', cor: 'var(--neutro)' },
    { valor: dados.atrasos, rotulo: 'Atrasos hoje', cor: dados.atrasos > 0 ? 'var(--erro)' : 'var(--texto)' },
    {
      valor: dados.ausentes_com_horario,
      rotulo: rotativo ? 'Sem entrada hoje (pode ser folga)' : 'Sem entrada hoje',
      cor: 'var(--texto)',
    },
    { valor: dados.registos_fora_do_raio, rotulo: 'Registos fora do raio', cor: dados.registos_fora_do_raio > 0 ? 'var(--aviso)' : 'var(--texto)' },
    { valor: dados.justificacoes_pendentes, rotulo: 'Justificações pendentes', cor: dados.justificacoes_pendentes > 0 ? 'var(--aviso)' : 'var(--texto)' },
  ];

  container.innerHTML = `
    <div class="pagina-cabecalho">
      <div>
        <h1>Dashboard</h1>
        <p>${esc(ctx.empresa.nome)} · ${dados.total_ativos} funcionário(s) activo(s) · hoje</p>
      </div>
      <div class="accoes">
        <button type="button" class="botao botao-secundario" id="actualizar">Actualizar</button>
      </div>
    </div>

    <div class="grelha-metricas">
      ${metricas.map((m) => `
        <div class="metrica">
          <div class="metrica-valor" style="color:${m.cor}">${m.valor ?? 0}</div>
          <div class="metrica-rotulo">${esc(m.rotulo)}</div>
        </div>
      `).join('')}
    </div>

    <h2>Estado dos funcionários</h2>
    <div class="tabela-wrapper">
      <table>
        <thead>
          <tr>
            <th>Funcionário</th>
            <th>Cargo</th>
            <th>Estado</th>
            <th>Último registo</th>
            <th>Entrada hoje</th>
            <th>Prevista</th>
            <th class="numero">Atraso</th>
          </tr>
        </thead>
        <tbody>
          ${(dados.funcionarios ?? []).map((f) => linha(f, tz)).join('')
            || '<tr><td colspan="7" class="vazio">Ainda não há funcionários activos.</td></tr>'}
        </tbody>
      </table>
    </div>
  `;

  container.querySelector('#actualizar').addEventListener('click', () => renderDashboard(container, ctx));
}

function linha(f, tz) {
  const atraso = f.atraso_minutos;
  const corAtraso = atraso > 0 ? 'color:var(--erro);font-weight:700' : 'color:var(--texto-suave)';

  return `
    <tr>
      <td><strong>${esc(f.nome)}</strong></td>
      <td>${esc(f.cargo) || '—'}</td>
      <td>${etiquetaEstado(f.estado)}</td>
      <td>${f.ultimo_registo ? esc(f.ultimo_registo_hora) : '—'}</td>
      <td>${f.entrada_hoje ? esc(f.entrada_hoje_hora) : '<span style="color:var(--texto-suave)">sem entrada</span>'}</td>
      <td>${f.hora_entrada_esperada ? esc(String(f.hora_entrada_esperada).slice(0, 5)) : '—'}</td>
      <td class="numero" style="${corAtraso}">${atraso > 0 ? `${atraso} min` : '—'}</td>
    </tr>
  `;
}
