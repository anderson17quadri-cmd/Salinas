#!/usr/bin/env node
/**
 * Gera o cartaz com o QR code de uma empresa, a partir do seu `qr_code_token`.
 *
 *   node gerar-qrcode.js --token <TOKEN> --empresa "Nome da Empresa"
 *   SALINAS_QR_TOKEN=<TOKEN> node gerar-qrcode.js --empresa "Nome"
 *
 * Produz um PNG do código (com o logo da Pastelaria Salinas sobreposto) e
 * um cartaz A4 pronto a imprimir e afixar na entrada.
 *
 * O token está em `empresas.qr_code_token` e obtém-se no painel admin
 * (secção QR Code) ou por SQL. Trate-o como um segredo: quem o tiver
 * consegue bater ponto sem estar no local — se for exposto, regenere-o.
 */

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

import QRCode from 'qrcode';
import sharp from 'sharp';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const LOGO = path.join(AQUI, '..', 'public', 'assets', 'logo.png');

const TINTA = '#12100C';
const LARANJA = '#F5A323';
const LADO_QR = 1200;

function lerArgumentos(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const actual = argv[i];
    if (!actual.startsWith('--')) continue;
    const chave = actual.slice(2);
    const proximo = argv[i + 1];
    if (proximo && !proximo.startsWith('--')) {
      args[chave] = proximo;
      i += 1;
    } else {
      args[chave] = true;
    }
  }
  return args;
}

function slug(texto) {
  return (texto || 'empresa')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

function escaparXml(texto) {
  return String(texto)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

/**
 * Gera o QR em nível H e sobrepõe-lhe o logo.
 *
 * O nível H recupera até 30% do código; o crachá do logo fica em ~5% da
 * área, com folga de sobra para leitores baratos e impressões desalinhadas.
 */
async function montarQr(token, temLogo) {
  const qr = await QRCode.toBuffer(token, {
    errorCorrectionLevel: 'H',
    margin: 2,
    width: LADO_QR,
    color: { dark: TINTA, light: '#FFFFFF' },
  });

  if (!temLogo) return qr;

  const largura = Math.round(LADO_QR * 0.3);
  const folga = Math.round(LADO_QR * 0.014);

  const logo = await sharp(LOGO).resize({ width: largura }).toBuffer();
  const { height: altura } = await sharp(logo).metadata();

  // Moldura branca por baixo do logo, para o separar dos módulos.
  const moldura = await sharp({
    create: {
      width: largura + folga * 2,
      height: altura + folga * 2,
      channels: 4,
      background: '#FFFFFF',
    },
  })
    .png()
    .toBuffer();

  return sharp(qr)
    .composite([
      { input: moldura, gravity: 'centre' },
      { input: logo, gravity: 'centre' },
    ])
    .png()
    .toBuffer();
}

/** Cartaz A4 com o logo, o nome da empresa, o QR e as instruções. */
function montarCartaz({ qrBase64, logoBase64, empresa }) {
  const logoSvg = logoBase64
    ? `<image href="data:image/png;base64,${logoBase64}" x="257" y="60" width="280" height="149" />`
    : `<text x="397" y="150" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
             font-size="52" font-weight="bold" fill="${TINTA}">Salinas</text>`;

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="794" height="1123" viewBox="0 0 794 1123">
  <rect width="794" height="1123" fill="#FFFFFF"/>
  ${logoSvg}

  <text x="397" y="262" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="32" font-weight="bold" fill="${TINTA}">${escaparXml(empresa)}</text>
  <text x="397" y="300" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="20" fill="#7A7266">Registo de ponto</text>

  <image href="data:image/png;base64,${qrBase64}" x="177" y="330" width="440" height="440" />

  <rect x="147" y="820" width="500" height="4" rx="2" fill="${LARANJA}"/>

  <text x="397" y="880" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="24" font-weight="bold" fill="${TINTA}">Como bater o ponto</text>
  <text x="397" y="928" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="19" fill="#7A7266">1. Abra a app Salinas no seu telemóvel</text>
  <text x="397" y="962" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="19" fill="#7A7266">2. Toque em "Bater Ponto" e escolha "Ler QR code"</text>
  <text x="397" y="996" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="19" fill="#7A7266">3. Aponte a câmara a este código</text>
</svg>`;
}

async function principal() {
  const args = lerArgumentos(process.argv);
  const token = args.token || process.env.SALINAS_QR_TOKEN;
  const empresa = args.empresa || process.env.SALINAS_EMPRESA || 'A sua empresa';
  const destino = args.saida || path.join(process.cwd(), 'output');

  if (!token || token === true) {
    console.error(
      'Falta o token da empresa.\n\n' +
        '  node gerar-qrcode.js --token <TOKEN> --empresa "Nome da Empresa"\n\n' +
        'Obtenha-o no painel admin (QR Code) ou com:\n' +
        '  select nome, qr_code_token from empresas;\n'
    );
    process.exitCode = 1;
    return;
  }

  await mkdir(destino, { recursive: true });

  // Sem o logo o cartaz sai na mesma, só que sem marca.
  const logoBuffer = await readFile(LOGO).catch(() => null);
  if (!logoBuffer) {
    console.warn('Aviso: public/assets/logo.png não encontrado — o cartaz sai sem logo.');
  }

  const base = `salinas-qr-${slug(empresa)}`;
  const qrPng = await montarQr(token, Boolean(logoBuffer));

  const caminhoPng = path.join(destino, `${base}.png`);
  await writeFile(caminhoPng, qrPng);

  const caminhoCartaz = path.join(destino, `${base}-cartaz.svg`);
  await writeFile(
    caminhoCartaz,
    montarCartaz({
      qrBase64: qrPng.toString('base64'),
      logoBase64: logoBuffer?.toString('base64'),
      empresa,
    }),
    'utf8'
  );

  const caminhoCartazPng = path.join(destino, `${base}-cartaz.png`);
  await sharp(Buffer.from(await readFile(caminhoCartaz)), { density: 150 })
    .png()
    .toFile(caminhoCartazPng);

  console.log('QR code gerado:');
  console.log(`  Código  → ${caminhoPng}`);
  console.log(`  Cartaz  → ${caminhoCartaz}`);
  console.log(`  Cartaz  → ${caminhoCartazPng}  (A4, pronto a imprimir)`);
}

principal().catch((erro) => {
  console.error('Erro ao gerar o QR code:', erro.message);
  process.exitCode = 1;
});
