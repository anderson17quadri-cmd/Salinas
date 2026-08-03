import {
  actualizarPerfil,
  carregarFicheiro,
  estadoAtual,
  mensagemDeErro,
  obterHorario,
  sair,
  sessaoActual,
  urlPublico,
} from '../api.js';
import { DIAS_SEMANA, confirmar, esc, notificar } from '../ui.js';

export default async function renderPerfil(container, ctx) {
  const estado = await estadoAtual();
  ctx.estado = estado;

  const { funcionario, empresa } = estado;
  const [horario, sessao] = await Promise.all([obterHorario(funcionario.id), sessaoActual()]);

  container.innerHTML = `
    <div class="cabecalho-app">
      <h1 class="titulo">Perfil</h1>
    </div>

    <div class="bloco-foto">
      <button type="button" class="avatar" id="botao-foto" aria-label="Mudar foto de perfil">
        ${funcionario.foto_perfil_url
          ? `<img src="${esc(funcionario.foto_perfil_url)}" alt="" />`
          : esc(iniciais(funcionario.nome))}
      </button>
      <button type="button" class="ligacao" id="mudar-foto">Mudar foto</button>
    </div>

    <form class="cartao" id="form-perfil" style="margin-bottom:16px">
      <div class="formulario">
        <label>Nome
          <input type="text" name="nome" value="${esc(funcionario.nome)}" required />
        </label>
      </div>

      <div class="linha-info" style="margin-top:14px">
        <span class="rotulo">Email</span>
        <span class="valor">${esc(sessao?.user?.email ?? '—')}</span>
      </div>
      <div class="linha-info">
        <span class="rotulo">Cargo</span>
        <span class="valor">${esc(funcionario.cargo) || '—'}</span>
      </div>
      <div class="linha-info">
        <span class="rotulo">Empresa</span>
        <span class="valor">${esc(empresa.nome)}</span>
      </div>
      <div class="linha-info">
        <span class="rotulo">Horas por semana</span>
        <span class="valor">${esc(String(funcionario.horas_semanais_esperadas ?? 40))} h</span>
      </div>

      <div class="alerta alerta-erro oculto" id="erro" style="margin-top:14px"></div>
      <button type="submit" class="botao botao-primario" id="guardar" style="margin-top:16px">Guardar</button>
    </form>

    <div class="cartao" style="margin-bottom:16px">
      <h2 class="subtitulo">Horário esperado</h2>
      ${horario.length
        ? horario.map((h) => `
            <div class="linha-info">
              <span class="rotulo">${DIAS_SEMANA[h.dia_semana]}</span>
              <span class="valor">${esc((h.hora_entrada ?? '').slice(0, 5))} – ${esc((h.hora_saida ?? '').slice(0, 5))}</span>
            </div>
          `).join('')
        : '<p class="nota">Ainda não tem horário definido pelo seu gestor.</p>'}
    </div>

    <button type="button" class="botao botao-secundario" id="terminar-sessao">Terminar sessão</button>
  `;

  const form = container.querySelector('#form-perfil');
  const erro = container.querySelector('#erro');

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    erro.classList.add('oculto');

    const nome = form.nome.value.trim();
    if (!nome) {
      erro.textContent = 'O nome não pode ficar vazio.';
      erro.classList.remove('oculto');
      return;
    }

    const botao = container.querySelector('#guardar');
    botao.disabled = true;

    try {
      await actualizarPerfil(funcionario.id, { nome });
      notificar('Perfil actualizado.', 'sucesso');
      renderPerfil(container, ctx);
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2, 'Não foi possível guardar.');
      erro.classList.remove('oculto');
    } finally {
      botao.disabled = false;
    }
  });

  const mudarFoto = () => escolherFoto(funcionario, empresa, () => renderPerfil(container, ctx));
  container.querySelector('#botao-foto').addEventListener('click', mudarFoto);
  container.querySelector('#mudar-foto').addEventListener('click', mudarFoto);

  container.querySelector('#terminar-sessao').addEventListener('click', async () => {
    const ok = await confirmar('Terminar sessão', 'Quer mesmo sair da sua conta?', 'Sair');
    if (!ok) return;
    await sair();
    location.reload();
  });
}

function escolherFoto(funcionario, empresa, aoTerminar) {
  const campo = document.createElement('input');
  campo.type = 'file';
  campo.accept = 'image/*';

  campo.addEventListener('change', async () => {
    const ficheiro = campo.files?.[0];
    if (!ficheiro) return;

    if (ficheiro.size > 5 * 1024 * 1024) {
      notificar('A foto não pode exceder 5 MB.', 'erro');
      return;
    }

    try {
      const caminho = await carregarFicheiro({
        bucket: 'perfis',
        empresaId: empresa.id,
        funcionarioId: funcionario.id,
        ficheiro,
      });
      await actualizarPerfil(funcionario.id, { foto_perfil_url: urlPublico('perfis', caminho) });
      notificar('Foto actualizada.', 'sucesso');
      aoTerminar();
    } catch (e) {
      notificar(mensagemDeErro(e, 'Não foi possível carregar a foto.'), 'erro');
    }
  });

  campo.click();
}

function iniciais(nome) {
  return (nome || '?')
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0].toUpperCase())
    .join('');
}
