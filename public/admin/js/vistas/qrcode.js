import QRCode from '../../../vendor/qrcode.js';

import { mensagemDeErro, obterQrToken, regenerarQrToken } from '../api.js';
import { confirmar, dataHora, esc, exportarPdf, notificar } from '../ui.js';

const TINTA = '#12100C';
const LARANJA = '#F5A323';
const LOGO = '../assets/logo.png';

export default async function renderQrCode(container, ctx) {
  const dados = await obterQrToken();

  container.innerHTML = `
    <div class="pagina-cabecalho nao-imprimir">
      <div>
        <h1>QR Code da empresa</h1>
        <p>Afixe este código na entrada. Os funcionários lêem-no na app para bater o ponto.</p>
      </div>
      <div class="accoes">
        <button type="button" class="botao botao-secundario" id="imprimir">Imprimir cartaz</button>
        <button type="button" class="botao botao-secundario" id="descarregar">Descarregar PNG</button>
        <button type="button" class="botao botao-perigo" id="regenerar">Regenerar código</button>
      </div>
    </div>

    <div class="grelha-duas">
      <div class="qr-caixa">
        <div class="qr-cartaz">
          <img class="qr-logo" src="${LOGO}" alt="Pastelaria Salinas" />
          <h2>${esc(ctx.empresa.nome)}</h2>
          <p>Registo de ponto — leia o código na app Salinas</p>
          <canvas id="qr-canvas" aria-label="QR code de registo de ponto"></canvas>
          <ol class="qr-passos">
            <li>Abra a app Salinas no telemóvel</li>
            <li>Toque em “Bater Ponto” e escolha “Ler QR code”</li>
            <li>Aponte a câmara a este código</li>
          </ol>
        </div>
      </div>

      <div class="cartao nao-imprimir">
        <h2>Segurança</h2>
        <p class="nota">
          O código identifica a sua empresa. Se for fotografado ou partilhado
          indevidamente, regenere-o: o código antigo deixa de funcionar de imediato
          e terá de imprimir e afixar o novo.
        </p>
        <p class="nota" style="margin-top:12px">
          <strong>Última actualização:</strong> ${esc(dataHora(dados.atualizado_em, ctx.timezone))}
        </p>
        <p class="nota" style="margin-top:12px">
          A app só aceita este código se o funcionário pertencer a esta empresa —
          ler o QR de outra empresa não permite registar ponto.
        </p>
        <p class="nota" style="margin-top:12px">
          O código usa correcção de erros de nível <strong>H</strong>, que recupera
          até 30% da imagem: é o que permite sobrepor o logo sem quebrar a leitura.
        </p>
        <p class="nota" style="margin-top:12px">
          Para gerar o cartaz fora do navegador, use
          <code>node tools/gerar-qrcode.js</code> com o token do projecto.
        </p>
      </div>
    </div>
  `;

  const canvas = container.querySelector('#qr-canvas');

  await QRCode.toCanvas(canvas, dados.qr_code_token, {
    width: 620,
    margin: 2,
    errorCorrectionLevel: 'H',
    color: { dark: TINTA, light: '#FFFFFF' },
  });

  await sobreporLogo(canvas);

  container.querySelector('#imprimir').addEventListener('click', exportarPdf);

  container.querySelector('#descarregar').addEventListener('click', () => {
    const a = document.createElement('a');
    a.href = canvas.toDataURL('image/png');
    a.download = `salinas-qr-${slug(ctx.empresa.nome)}.png`;
    a.click();
  });

  container.querySelector('#regenerar').addEventListener('click', async () => {
    const ok = await confirmar(
      'Regenerar QR code',
      'O código actual deixa de funcionar imediatamente. Todos os cartazes afixados '
        + 'têm de ser substituídos pelo novo. Quer continuar?',
      'Regenerar'
    );
    if (!ok) return;

    try {
      await regenerarQrToken();
      notificar('QR code regenerado. Imprima e afixe o novo cartaz.', 'sucesso');
      renderQrCode(container, ctx);
    } catch (e) {
      notificar(mensagemDeErro(e), 'erro');
    }
  });
}

/**
 * Desenha o logo num crachá no centro do QR code.
 *
 * O crachá ocupa ~30% da largura e ~16% da altura — cerca de 5% da área,
 * bem dentro dos 30% que o nível H consegue recuperar.
 */
function sobreporLogo(canvas) {
  return new Promise((resolve) => {
    const img = new Image();

    // Sem logo (ou se falhar a carregar) o QR continua válido.
    img.onerror = () => resolve();

    img.onload = () => {
      const ctx2d = canvas.getContext('2d');
      const lado = canvas.width;

      const largura = Math.round(lado * 0.30);
      const altura = Math.round((largura * img.height) / img.width);
      const x = Math.round((lado - largura) / 2);
      const y = Math.round((lado - altura) / 2);
      const folga = Math.round(lado * 0.014);

      // Moldura branca: separa o logo dos módulos do QR e ajuda o leitor
      // a delimitar a zona a recuperar.
      ctx2d.fillStyle = '#FFFFFF';
      arredondado(ctx2d, x - folga, y - folga, largura + folga * 2, altura + folga * 2, folga * 1.6);
      ctx2d.fill();

      ctx2d.save();
      arredondado(ctx2d, x, y, largura, altura, folga);
      ctx2d.clip();
      ctx2d.fillStyle = LARANJA;
      ctx2d.fillRect(x, y, largura, altura);
      ctx2d.drawImage(img, x, y, largura, altura);
      ctx2d.restore();

      resolve();
    };

    img.src = LOGO;
  });
}

function arredondado(ctx2d, x, y, largura, altura, raio) {
  const r = Math.min(raio, largura / 2, altura / 2);
  ctx2d.beginPath();
  ctx2d.moveTo(x + r, y);
  ctx2d.arcTo(x + largura, y, x + largura, y + altura, r);
  ctx2d.arcTo(x + largura, y + altura, x, y + altura, r);
  ctx2d.arcTo(x, y + altura, x, y, r);
  ctx2d.arcTo(x, y, x + largura, y, r);
  ctx2d.closePath();
}

function slug(texto) {
  return (texto || 'empresa')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}
