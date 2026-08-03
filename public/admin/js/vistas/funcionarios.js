import {
  actualizarFuncionario,
  criarFuncionario,
  definirHorario,
  listarFuncionarios,
  mensagemDeErro,
  obterHorario,
} from '../api.js';
import { DIAS_SEMANA, abrirModal, confirmar, esc, fecharModal, notificar } from '../ui.js';

export default async function renderFuncionarios(container, ctx) {
  const funcionarios = await listarFuncionarios();

  container.innerHTML = `
    <div class="pagina-cabecalho">
      <div>
        <h1>Funcionários</h1>
        <p>${funcionarios.filter((f) => f.ativo).length} activo(s) de ${funcionarios.length}</p>
      </div>
      <div class="accoes">
        <button type="button" class="botao botao-primario" id="novo">Novo funcionário</button>
      </div>
    </div>

    <div class="tabela-wrapper">
      <table>
        <thead>
          <tr>
            <th>Nome</th>
            <th>Email</th>
            <th>Cargo</th>
            <th class="numero">Horas/semana</th>
            <th>Conta</th>
            <th>Estado</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${funcionarios.map(linha).join('')
            || '<tr><td colspan="7" class="vazio">Ainda não há funcionários.</td></tr>'}
        </tbody>
      </table>
    </div>
  `;

  container.querySelector('#novo').addEventListener('click', () => formularioNovo(container, ctx));

  container.querySelectorAll('[data-editar]').forEach((b) =>
    b.addEventListener('click', () => {
      const f = funcionarios.find((x) => x.id === b.dataset.editar);
      formularioEditar(f, container, ctx);
    })
  );

  container.querySelectorAll('[data-horario]').forEach((b) =>
    b.addEventListener('click', () => {
      const f = funcionarios.find((x) => x.id === b.dataset.horario);
      formularioHorario(f, container, ctx);
    })
  );

  container.querySelectorAll('[data-alternar]').forEach((b) =>
    b.addEventListener('click', async () => {
      const f = funcionarios.find((x) => x.id === b.dataset.alternar);
      const desactivar = f.ativo;

      const ok = await confirmar(
        desactivar ? 'Desactivar funcionário' : 'Reactivar funcionário',
        desactivar
          ? `${f.nome} deixa de conseguir bater ponto. O histórico é mantido.`
          : `${f.nome} volta a poder bater ponto.`,
        desactivar ? 'Desactivar' : 'Reactivar'
      );
      if (!ok) return;

      try {
        await actualizarFuncionario(f.id, { ativo: !f.ativo });
        notificar(desactivar ? 'Funcionário desactivado.' : 'Funcionário reactivado.', 'sucesso');
        renderFuncionarios(container, ctx);
      } catch (e) {
        notificar(mensagemDeErro(e), 'erro');
      }
    })
  );
}

function linha(f) {
  return `
    <tr class="${f.ativo ? '' : 'inactivo'}">
      <td><strong>${esc(f.nome)}</strong></td>
      <td>${esc(f.email)}</td>
      <td>${esc(f.cargo) || '—'}</td>
      <td class="numero">${f.horas_semanais_esperadas ?? 40}</td>
      <td>${f.user_id
        ? '<span class="etiqueta etiqueta-dentro">Activada</span>'
        : '<span class="etiqueta etiqueta-fora">Por activar</span>'}</td>
      <td>${f.ativo
        ? '<span class="etiqueta etiqueta-primaria">Activo</span>'
        : '<span class="etiqueta etiqueta-fora">Inactivo</span>'}</td>
      <td class="accoes">
        <button type="button" class="botao botao-texto botao-pequeno" data-editar="${f.id}">Editar</button>
        <button type="button" class="botao botao-texto botao-pequeno" data-horario="${f.id}">Horário</button>
        <button type="button" class="botao botao-texto botao-pequeno" data-alternar="${f.id}">
          ${f.ativo ? 'Desactivar' : 'Reactivar'}
        </button>
      </td>
    </tr>
  `;
}

// ---------------------------------------------------------------------
// Criar
// ---------------------------------------------------------------------
function formularioNovo(container, ctx) {
  const modal = abrirModal(`
    <h2>Novo funcionário</h2>
    <form class="formulario" id="form-func">
      <label>Nome <input type="text" name="nome" required /></label>
      <label>Email <input type="email" name="email" required /></label>
      <label>Cargo <input type="text" name="cargo" /></label>
      <label>Horas por semana <input type="number" name="horas" value="40" min="0" max="80" step="0.5" /></label>
      <p class="nota">
        O funcionário fica associado assim que criar conta na app com este email.
        Crie-lhe a conta em Supabase → Authentication → Users, ou peça-lhe que use
        "Esqueci-me da palavra-passe" para a definir.
      </p>
      <div class="alerta alerta-erro oculto" id="erro-func"></div>
      <div class="modal-accoes">
        <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Criar</button>
      </div>
    </form>
  `);

  modal.querySelector('#form-func').addEventListener('submit', async (e) => {
    e.preventDefault();
    const dados = Object.fromEntries(new FormData(e.target));
    const erro = modal.querySelector('#erro-func');
    erro.classList.add('oculto');

    try {
      await criarFuncionario({
        nome: dados.nome,
        email: dados.email,
        cargo: dados.cargo,
        horasSemanais: Number(dados.horas) || 40,
      });
      fecharModal();
      notificar('Funcionário criado.', 'sucesso');
      renderFuncionarios(container, ctx);
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2);
      erro.classList.remove('oculto');
    }
  });
}

// ---------------------------------------------------------------------
// Editar
// ---------------------------------------------------------------------
function formularioEditar(f, container, ctx) {
  const modal = abrirModal(`
    <h2>Editar funcionário</h2>
    <form class="formulario" id="form-func">
      <label>Nome <input type="text" name="nome" value="${esc(f.nome)}" required /></label>
      <label>Email <input type="email" value="${esc(f.email)}" disabled /></label>
      <label>Cargo <input type="text" name="cargo" value="${esc(f.cargo ?? '')}" /></label>
      <label>Horas por semana
        <input type="number" name="horas" value="${f.horas_semanais_esperadas ?? 40}" min="0" max="80" step="0.5" />
      </label>
      <div class="alerta alerta-erro oculto" id="erro-func"></div>
      <div class="modal-accoes">
        <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Guardar</button>
      </div>
    </form>
  `);

  modal.querySelector('#form-func').addEventListener('submit', async (e) => {
    e.preventDefault();
    const dados = Object.fromEntries(new FormData(e.target));
    const erro = modal.querySelector('#erro-func');
    erro.classList.add('oculto');

    try {
      await actualizarFuncionario(f.id, {
        nome: dados.nome,
        cargo: dados.cargo,
        horasSemanais: Number(dados.horas) || null,
      });
      fecharModal();
      notificar('Funcionário actualizado.', 'sucesso');
      renderFuncionarios(container, ctx);
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2);
      erro.classList.remove('oculto');
    }
  });
}

// ---------------------------------------------------------------------
// Horário esperado
// ---------------------------------------------------------------------
async function formularioHorario(f, container, ctx) {
  const actual = await obterHorario(f.id);
  const porDia = Object.fromEntries(actual.map((h) => [h.dia_semana, h]));

  const modal = abrirModal(`
    <h2>Horário de ${esc(f.nome)}</h2>
    <p class="nota">Deixe vazio um dia para o marcar como folga.</p>
    <form class="formulario" id="form-horario">
      <div class="grelha-horario">
        ${DIAS_SEMANA.map((dia, i) => `
          <div class="linha-horario">
            <span>${dia}</span>
            <input type="time" name="entrada-${i}" value="${(porDia[i]?.hora_entrada ?? '').slice(0, 5)}" />
            <input type="time" name="saida-${i}" value="${(porDia[i]?.hora_saida ?? '').slice(0, 5)}" />
          </div>
        `).join('')}
      </div>
      <div class="alerta alerta-erro oculto" id="erro-horario"></div>
      <div class="modal-accoes">
        <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
        <button type="button" class="botao botao-secundario" id="preencher">Seg–Sex 09–18</button>
        <button type="submit" class="botao botao-primario">Guardar</button>
      </div>
    </form>
  `);

  modal.querySelector('#preencher').addEventListener('click', () => {
    [1, 2, 3, 4, 5].forEach((i) => {
      modal.querySelector(`[name="entrada-${i}"]`).value = '09:00';
      modal.querySelector(`[name="saida-${i}"]`).value = '18:00';
    });
  });

  modal.querySelector('#form-horario').addEventListener('submit', async (e) => {
    e.preventDefault();
    const erro = modal.querySelector('#erro-horario');
    erro.classList.add('oculto');

    const horarios = [];
    for (let i = 0; i < 7; i += 1) {
      const entrada = modal.querySelector(`[name="entrada-${i}"]`).value;
      const saida = modal.querySelector(`[name="saida-${i}"]`).value;
      if (!entrada || !saida) continue;

      if (saida <= entrada) {
        erro.textContent = `${DIAS_SEMANA[i]}: a hora de saída tem de ser depois da entrada.`;
        erro.classList.remove('oculto');
        return;
      }
      horarios.push({ dia_semana: i, hora_entrada: entrada, hora_saida: saida });
    }

    try {
      await definirHorario(f.id, horarios);
      fecharModal();
      notificar('Horário guardado.', 'sucesso');
      renderFuncionarios(container, ctx);
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2);
      erro.classList.remove('oculto');
    }
  });
}
