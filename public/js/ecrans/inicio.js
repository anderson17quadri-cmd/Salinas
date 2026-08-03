import { carregarFicheiro, estadoAtual, mensagemDeErro, registarPorGps, registarPorQrCode } from '../api.js';
import { distanciaMetros, localizacaoOpcional, obterLocalizacao } from '../geo.js';
import { lerQrCode } from '../scanner.js';
import {
  ROTULOS_TIPO,
  abrirModal,
  confirmar,
  dataExtenso,
  esc,
  etiquetaEstado,
  fecharModal,
  formatarDistancia,
  horas,
  mostrarSucesso,
  notificar,
} from '../ui.js';

export default async function renderInicio(container, ctx) {
  const estado = await estadoAtual();
  ctx.estado = estado;

  const { empresa, funcionario } = estado;
  const proximos = estado.proximos_tipos ?? ['entrada'];
  const tz = empresa.timezone;

  container.innerHTML = `
    <div class="cabecalho-app">
      <div>
        <h1 class="titulo">Olá, ${esc(primeiroNome(funcionario.nome))}</h1>
        <p class="data-hoje">${esc(dataExtenso(new Date().toISOString(), tz))}</p>
      </div>
    </div>

    <div id="zona-instalar"></div>

    <div class="cartao" style="margin-bottom:16px">
      <div class="linha-estado">
        ${etiquetaEstado(estado.estado)}
        <span class="empresa-nome">${esc(empresa.nome)}</span>
      </div>
      <p style="margin:12px 0 0;font-size:15px">
        ${estado.ultimo_registo
          ? `Último registo: <strong>${esc(ROTULOS_TIPO[estado.ultimo_registo.tipo])}</strong> às
             ${esc(horas(estado.ultimo_registo.timestamp, tz))}`
          : 'Ainda não tem registos.'}
      </p>
    </div>

    <button type="button" class="botao-ponto" id="bater-ponto">
      <span class="rotulo">Bater Ponto</span>
      <span class="sub">${proximos.map((t) => esc(ROTULOS_TIPO[t])).join('  ·  ')}</span>
    </button>

    <div class="chips" style="margin-top:14px">
      ${empresa.metodo_qrcode_ativo ? '<button type="button" class="chip" data-metodo="qrcode">Ler QR code</button>' : ''}
      ${empresa.metodo_gps_ativo ? '<button type="button" class="chip" data-metodo="gps">Usar GPS</button>' : ''}
    </div>

    <div class="cartao" style="margin-top:16px">
      <h2 class="subtitulo">O seu contrato</h2>
      <div class="linha-info">
        <span class="rotulo">Cargo</span>
        <span class="valor">${esc(funcionario.cargo) || '—'}</span>
      </div>
      <div class="linha-info">
        <span class="rotulo">Horas por semana</span>
        <span class="valor">${esc(String(funcionario.horas_semanais_esperadas ?? 40))} h</span>
      </div>
      ${empresa.metodo_gps_ativo ? `
        <div class="linha-info">
          <span class="rotulo">Raio permitido</span>
          <span class="valor">${esc(String(empresa.raio_metros))} m${empresa.foto_obrigatoria ? ' · com foto' : ''}</span>
        </div>` : ''}
    </div>
  `;

  const botao = container.querySelector('#bater-ponto');

  botao.addEventListener('click', () => escolherTipo(null));
  container.querySelectorAll('[data-metodo]').forEach((b) =>
    b.addEventListener('click', () => escolherTipo(b.dataset.metodo))
  );

  // ------------------------------------------------------------------
  // Escolha de tipo → escolha de método → registo
  // ------------------------------------------------------------------
  function escolherTipo(metodoForcado) {
    if (proximos.length === 1) {
      escolherMetodo(proximos[0], metodoForcado);
      return;
    }

    const modal = abrirModal(`
      <h2>O que quer registar?</h2>
      ${proximos.map((t) => `
        <button type="button" class="botao botao-primario" data-tipo="${t}">${esc(ROTULOS_TIPO[t])}</button>
      `).join('')}
      <button type="button" class="botao botao-secundario" data-fechar>Cancelar</button>
    `);

    modal.querySelectorAll('[data-tipo]').forEach((b) =>
      b.addEventListener('click', () => {
        fecharModal();
        escolherMetodo(b.dataset.tipo, metodoForcado);
      })
    );
  }

  function escolherMetodo(tipo, metodoForcado) {
    if (metodoForcado === 'qrcode') return registarQr(tipo);
    if (metodoForcado === 'gps') return registarGps(tipo);

    const qr = empresa.metodo_qrcode_ativo;
    const gps = empresa.metodo_gps_ativo;

    if (qr && gps) {
      const modal = abrirModal(`
        <h2>Como quer registar?</h2>
        <button type="button" class="botao botao-primario" data-qr>Ler QR code da empresa</button>
        <button type="button" class="botao botao-secundario" data-gps>Usar a minha localização</button>
        <button type="button" class="botao botao-texto" data-fechar>Cancelar</button>
      `);
      modal.querySelector('[data-qr]').addEventListener('click', () => { fecharModal(); registarQr(tipo); });
      modal.querySelector('[data-gps]').addEventListener('click', () => { fecharModal(); registarGps(tipo); });
      return undefined;
    }

    if (qr) return registarQr(tipo);
    if (gps) return registarGps(tipo);

    notificar('A sua empresa não tem nenhum método de registo activo.', 'erro');
    return undefined;
  }

  // ------------------------------------------------------------------
  // Check-in por QR code
  // ------------------------------------------------------------------
  async function registarQr(tipo) {
    const token = await lerQrCode(tipo);
    if (!token) return;

    ocupado(true);
    try {
      const coords = await localizacaoOpcional();
      const resultado = await registarPorQrCode({
        token,
        tipo,
        latitude: coords?.latitude,
        longitude: coords?.longitude,
      });

      await mostrarSucesso(resultado);
      renderInicio(container, ctx);
    } catch (e) {
      notificar(mensagemDeErro(e, 'Não foi possível registar o ponto.'), 'erro');
    } finally {
      ocupado(false);
    }
  }

  // ------------------------------------------------------------------
  // Check-in por geolocalização
  // ------------------------------------------------------------------
  async function registarGps(tipo) {
    ocupado(true);
    try {
      const coords = await obterLocalizacao();

      // Aviso antecipado; o servidor volta a validar de qualquer forma.
      if (empresa.latitude != null && empresa.longitude != null) {
        const distancia = distanciaMetros(
          coords.latitude, coords.longitude, empresa.latitude, empresa.longitude
        );

        if (distancia > empresa.raio_metros) {
          const continuar = await confirmar(
            'Está fora do local de trabalho',
            `Encontra-se a ${formatarDistancia(distancia)} da empresa (limite: ${empresa.raio_metros} m). `
              + 'O registo fica gravado e assinalado para o seu gestor rever.',
            'Registar mesmo assim'
          );
          if (!continuar) return;
        }
      }

      let fotoUrl = null;
      if (empresa.foto_obrigatoria) {
        fotoUrl = await tirarFoto();
        if (!fotoUrl) {
          notificar('Esta empresa exige uma foto de confirmação no registo.', 'erro');
          return;
        }
      }

      const resultado = await registarPorGps({
        tipo,
        latitude: coords.latitude,
        longitude: coords.longitude,
        fotoUrl,
      });

      await mostrarSucesso(resultado);
      renderInicio(container, ctx);
    } catch (e) {
      notificar(mensagemDeErro(e, 'Não foi possível registar o ponto.'), 'erro');
    } finally {
      ocupado(false);
    }
  }

  /** Abre a câmara frontal do telemóvel e carrega a foto para o Storage. */
  function tirarFoto() {
    return new Promise((resolve) => {
      const campo = document.createElement('input');
      campo.type = 'file';
      campo.accept = 'image/*';
      // `capture` faz o telemóvel abrir a câmara em vez da galeria.
      campo.capture = 'user';

      campo.addEventListener('change', async () => {
        const ficheiro = campo.files?.[0];
        if (!ficheiro) {
          resolve(null);
          return;
        }
        try {
          resolve(await carregarFicheiro({
            bucket: 'registos-ponto',
            empresaId: empresa.id,
            funcionarioId: funcionario.id,
            ficheiro,
          }));
        } catch (e) {
          notificar(mensagemDeErro(e, 'Não foi possível carregar a foto.'), 'erro');
          resolve(null);
        }
      });

      // Se o utilizador fechar a câmara sem tirar foto, o evento `change`
      // nunca chega — o `cancel` (onde existe) desbloqueia a promessa.
      campo.addEventListener('cancel', () => resolve(null));
      campo.click();
    });
  }

  function ocupado(sim) {
    botao.disabled = sim;
    botao.querySelector('.rotulo').textContent = sim ? 'A registar…' : 'Bater Ponto';
  }
}

function primeiroNome(nome) {
  return (nome || '').split(' ')[0] || 'colega';
}
