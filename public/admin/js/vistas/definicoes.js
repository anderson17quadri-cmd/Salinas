import { actualizarEmpresa, mensagemDeErro } from '../api.js';
import { esc, notificar } from '../ui.js';

export default async function renderDefinicoes(container, ctx) {
  const e = ctx.empresa;

  container.innerHTML = `
    <div class="pagina-cabecalho">
      <div>
        <h1>Definições da empresa</h1>
        <p>Local de trabalho, raio permitido e métodos de registo activos.</p>
      </div>
    </div>

    <form class="cartao" id="form-empresa" style="max-width:640px">
      <div class="formulario">
        <label>Nome da empresa
          <input type="text" name="nome" value="${esc(e.nome)}" required />
        </label>

        <label>Morada
          <input type="text" name="morada" value="${esc(e.morada ?? '')}" />
        </label>

        <div class="filtros" style="padding:0;border:none;background:none;margin:0">
          <label>Latitude
            <input type="number" name="latitude" step="any" value="${e.latitude ?? ''}" placeholder="38.707751" />
          </label>
          <label>Longitude
            <input type="number" name="longitude" step="any" value="${e.longitude ?? ''}" placeholder="-9.136592" />
          </label>
          <label>Raio permitido (m)
            <input type="number" name="raio_metros" min="10" max="5000" value="${e.raio_metros ?? 100}" />
          </label>
        </div>

        <p class="nota">
          Para obter as coordenadas: abra o Google Maps, clique com o botão direito
          no local de trabalho e copie os dois números que aparecem.
          <button type="button" class="ligacao" id="usar-minha">Usar a minha localização actual</button>
        </p>

        <label>Fuso horário
          <select name="timezone">
            ${['Europe/Lisbon', 'Atlantic/Madeira', 'Atlantic/Azores', 'UTC'].map((tz) =>
              `<option value="${tz}" ${e.timezone === tz ? 'selected' : ''}>${tz}</option>`
            ).join('')}
          </select>
        </label>

        <h3 style="margin-top:8px">Escala e folgas</h3>

        <label>Regime de folgas
          <select name="regime_folgas">
            <option value="fixo" ${e.regime_folgas !== 'rotativo' ? 'selected' : ''}>
              Fixo — a folga é sempre o(s) mesmo(s) dia(s) da semana
            </option>
            <option value="rotativo" ${e.regime_folgas === 'rotativo' ? 'selected' : ''}>
              Rotativo — escala com dias de folga que vão mudando (ex.: 6 dias de trabalho, 2 de folga)
            </option>
          </select>
        </label>

        <p class="nota">
          Em regime <strong>fixo</strong>, um dia com horário definido e sem
          ponto conta como falta. Em regime <strong>rotativo</strong>, o
          horário fica igual todas as semanas mas a folga muda — por isso um
          dia sem ponto e sem justificação passa a contar como
          <strong>folga</strong>, não como falta.
        </p>

        <h3 style="margin-top:8px">Banco de horas</h3>

        <label>Política
          <select name="politica_banco_horas">
            <option value="apenas_reportar" ${e.politica_banco_horas === 'apenas_reportar' ? 'selected' : ''}>
              Apenas reportar — o saldo é só informativo
            </option>
            <option value="compensar_folga" ${e.politica_banco_horas === 'compensar_folga' ? 'selected' : ''}>
              Compensar com folga — o crédito vira dias de folga
            </option>
            <option value="desconto_automatico" ${e.politica_banco_horas === 'desconto_automatico' ? 'selected' : ''}>
              Descontar no salário — a dívida é descontada
            </option>
            <option value="pagar_extra" ${e.politica_banco_horas === 'pagar_extra' ? 'selected' : ''}>
              Pagar como horas extra — o crédito é pago
            </option>
          </select>
        </label>

        <label>Limite de compensação (meses)
          <input type="number" name="limite_compensacao_meses" min="1" max="60"
                 value="${e.limite_compensacao_meses ?? 12}" />
        </label>

        <p class="nota">
          Passado este prazo, os saldos ainda em aberto ficam assinalados no
          Banco de Horas para decisão. Em Portugal o prazo de compensação vai
          tipicamente até 12 meses.
        </p>

        <h3 style="margin-top:8px">Métodos de registo</h3>

        <label style="font-weight:400">
          <input type="checkbox" name="metodo_qrcode_ativo" ${e.metodo_qrcode_ativo ? 'checked' : ''}
                 style="width:auto;margin-right:8px" />
          Permitir registo por QR code
        </label>

        <label style="font-weight:400">
          <input type="checkbox" name="metodo_gps_ativo" ${e.metodo_gps_ativo ? 'checked' : ''}
                 style="width:auto;margin-right:8px" />
          Permitir registo por geolocalização
        </label>

        <label style="font-weight:400">
          <input type="checkbox" name="foto_obrigatoria" ${e.foto_obrigatoria ? 'checked' : ''}
                 style="width:auto;margin-right:8px" />
          Exigir foto de confirmação no registo por GPS
        </label>

        <div class="alerta alerta-erro oculto" id="erro"></div>
        <button type="submit" class="botao botao-primario" id="guardar">Guardar definições</button>
      </div>
    </form>
  `;

  const form = container.querySelector('#form-empresa');
  const erro = container.querySelector('#erro');

  container.querySelector('#usar-minha').addEventListener('click', () => {
    if (!navigator.geolocation) {
      notificar('Este navegador não suporta geolocalização.', 'erro');
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        form.latitude.value = pos.coords.latitude.toFixed(6);
        form.longitude.value = pos.coords.longitude.toFixed(6);
        notificar('Coordenadas preenchidas. Reveja e guarde.', 'sucesso');
      },
      () => notificar('Não foi possível obter a sua localização.', 'erro')
    );
  });

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    erro.classList.add('oculto');

    const qr = form.metodo_qrcode_ativo.checked;
    const gps = form.metodo_gps_ativo.checked;

    if (!qr && !gps) {
      erro.textContent = 'Active pelo menos um método de registo, senão ninguém consegue bater ponto.';
      erro.classList.remove('oculto');
      return;
    }

    const latitude = form.latitude.value === '' ? null : Number(form.latitude.value);
    const longitude = form.longitude.value === '' ? null : Number(form.longitude.value);

    if (gps && (latitude === null || longitude === null)) {
      erro.textContent = 'O registo por geolocalização precisa das coordenadas da empresa.';
      erro.classList.remove('oculto');
      return;
    }

    const campos = {
      nome: form.nome.value.trim(),
      morada: form.morada.value.trim() || null,
      latitude,
      longitude,
      raio_metros: Number(form.raio_metros.value) || 100,
      timezone: form.timezone.value,
      regime_folgas: form.regime_folgas.value,
      politica_banco_horas: form.politica_banco_horas.value,
      limite_compensacao_meses: Number(form.limite_compensacao_meses.value) || 12,
      metodo_qrcode_ativo: qr,
      metodo_gps_ativo: gps,
      foto_obrigatoria: form.foto_obrigatoria.checked,
    };

    const botao = container.querySelector('#guardar');
    botao.disabled = true;

    try {
      await actualizarEmpresa(e.id, campos);
      Object.assign(ctx.empresa, campos);
      ctx.timezone = campos.timezone;
      document.getElementById('barra-empresa').textContent = campos.nome;
      notificar('Definições guardadas.', 'sucesso');
    } catch (e2) {
      erro.textContent = mensagemDeErro(e2);
      erro.classList.remove('oculto');
    } finally {
      botao.disabled = false;
    }
  });
}
