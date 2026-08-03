import { Html5Qrcode } from '../vendor/html5-qrcode.js';

import { ROTULOS_TIPO, esc } from './ui.js';

const ID_VIDEO = 'scanner-video';

let leitor = null;
let aLer = false;

/**
 * Abre a câmara e lê um QR code.
 *
 * Resolve com o texto lido, ou com `null` se o funcionário cancelar.
 * A câmara é sempre desligada à saída, seja qual for o caminho — deixá-la
 * ligada em segundo plano é um problema de privacidade e de bateria.
 */
export function lerQrCode(tipo) {
  const ecra = document.getElementById('ecra-scanner');
  const erro = document.getElementById('scanner-erro');
  const cancelar = document.getElementById('scanner-cancelar');

  document.getElementById('scanner-titulo').textContent = ROTULOS_TIPO[tipo] ?? 'Registo';
  erro.classList.add('oculto');
  erro.textContent = '';
  ecra.classList.remove('oculto');

  return new Promise((resolve) => {
    let terminado = false;

    const terminar = async (valor) => {
      if (terminado) return;
      terminado = true;

      cancelar.removeEventListener('click', aoCancelar);
      await pararLeitor();
      ecra.classList.add('oculto');
      resolve(valor);
    };

    function aoCancelar() {
      terminar(null);
    }

    cancelar.addEventListener('click', aoCancelar);

    iniciarLeitor((texto) => terminar(texto)).catch((e) => {
      erro.innerHTML = esc(mensagemDeCamara(e));
      erro.classList.remove('oculto');
    });
  });
}

async function iniciarLeitor(aoLer) {
  if (!window.isSecureContext) {
    throw new Error('inseguro');
  }

  leitor = new Html5Qrcode(ID_VIDEO, { verbose: false });
  aLer = true;

  const config = {
    fps: 10,
    // Caixa de leitura quadrada e proporcional ao ecrã: em telemóveis
    // estreitos uma caixa fixa fica maior do que a área de vídeo.
    qrbox: (larguraVideo, alturaVideo) => {
      const lado = Math.floor(Math.min(larguraVideo, alturaVideo) * 0.7);
      return { width: lado, height: lado };
    },
    aspectRatio: 1.777,
  };

  let jaLido = false;
  const aoSucesso = (texto) => {
    // O html5-qrcode dispara em cada frame enquanto o código estiver
    // visível; só o primeiro interessa.
    if (jaLido) return;
    jaLido = true;
    aoLer(texto);
  };

  try {
    await leitor.start({ facingMode: 'environment' }, config, aoSucesso, () => {});
  } catch (e) {
    // Alguns dispositivos recusam `facingMode: environment` mas aceitam
    // uma câmara escolhida pelo id.
    const camaras = await Html5Qrcode.getCameras().catch(() => []);
    if (!camaras.length) throw e;

    const traseira = camaras.find((c) => /back|rear|traseira|environment/i.test(c.label)) ?? camaras.at(-1);
    await leitor.start(traseira.id, config, aoSucesso, () => {});
  }
}

async function pararLeitor() {
  if (!leitor || !aLer) return;
  aLer = false;
  try {
    await leitor.stop();
    leitor.clear();
  } catch {
    // Já estava parado — não há nada a fazer.
  }
  leitor = null;
}

function mensagemDeCamara(erro) {
  const msg = erro?.message ?? String(erro);

  if (msg === 'inseguro') {
    return 'A câmara só funciona em HTTPS. Abra a app pelo endereço seguro (https://…).';
  }
  if (/NotAllowedError|Permission/i.test(msg)) {
    return 'Acesso à câmara recusado. Autorize a câmara nas definições do browser e tente de novo.';
  }
  if (/NotFoundError|no camera/i.test(msg)) {
    return 'Não encontrámos nenhuma câmara neste dispositivo.';
  }
  if (/NotReadableError|TrackStartError/i.test(msg)) {
    return 'A câmara está a ser usada por outra aplicação. Feche-a e tente de novo.';
  }
  return 'Não foi possível abrir a câmara. Tente novamente ou use o registo por GPS.';
}
