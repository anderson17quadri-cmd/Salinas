#!/usr/bin/env node
/**
 * Gera o cartaz com o QR code de uma empresa, a partir do seu `qr_code_token`.
 *
 * Produz um PNG (para imprimir directamente) e um SVG (para escalar sem perda).
 *
 *   node gerar-qrcode.js --token <TOKEN> --empresa "Nome da Empresa"
 *   SALINAS_QR_TOKEN=<TOKEN> node gerar-qrcode.js --empresa "Nome"
 *
 * O token está em `empresas.qr_code_token` e obtém-se no painel admin
 * (secção QR Code) ou por SQL. Trate-o como um segredo: quem o tiver
 * consegue bater ponto sem estar no local — se for exposto, regenere-o.
 */

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

import QRCode from 'qrcode';

const VERDE = '#0F5C4E';

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

/** Envolve o QR num cartaz A4-friendly com o nome da empresa e instruções. */
function montarCartaz(qrSvg, empresa) {
  // Remove o cabeçalho XML do SVG do QR para o poder embutir.
  const interior = qrSvg
    .replace(/<\?xml[^>]*\?>/, '')
    .replace(/<svg[^>]*>/, '')
    .replace(/<\/svg>\s*$/, '');

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="794" height="1123" viewBox="0 0 794 1123">
  <rect width="794" height="1123" fill="#FFFFFF"/>
  <text x="397" y="130" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="52" font-weight="bold" fill="${VERDE}">Salinas</text>
  <text x="397" y="180" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="30" fill="#16211E">${escaparXml(empresa)}</text>
  <text x="397" y="226" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="20" fill="#6B7A76">Registo de ponto</text>

  <g transform="translate(147, 280) scale(0.5)">
    ${interior}
  </g>

  <text x="397" y="900" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="24" font-weight="bold" fill="#16211E">Como bater o ponto</text>
  <text x="397" y="945" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="19" fill="#6B7A76">1. Abra a app Salinas no seu telemóvel</text>
  <text x="397" y="978" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="19" fill="#6B7A76">2. Toque em "Bater Ponto" e escolha "Ler QR code"</text>
  <text x="397" y="1011" text-anchor="middle" font-family="Helvetica, Arial, sans-serif"
        font-size="19" fill="#6B7A76">3. Aponte a câmara a este código</text>
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

  const base = `salinas-qr-${slug(empresa)}`;
  const opcoes = {
    errorCorrectionLevel: 'M',
    margin: 2,
    color: { dark: VERDE, light: '#FFFFFF' },
  };

  const caminhoPng = path.join(destino, `${base}.png`);
  await QRCode.toFile(caminhoPng, token, { ...opcoes, width: 1024, type: 'png' });

  const qrSvg = await QRCode.toString(token, { ...opcoes, type: 'svg', width: 1000 });

  const caminhoSvg = path.join(destino, `${base}.svg`);
  await writeFile(caminhoSvg, qrSvg, 'utf8');

  const caminhoCartaz = path.join(destino, `${base}-cartaz.svg`);
  await writeFile(caminhoCartaz, montarCartaz(qrSvg, empresa), 'utf8');

  console.log('QR code gerado:');
  console.log(`  PNG    → ${caminhoPng}`);
  console.log(`  SVG    → ${caminhoSvg}`);
  console.log(`  Cartaz → ${caminhoCartaz}  (A4, pronto a imprimir)`);
}

principal().catch((erro) => {
  console.error('Erro ao gerar o QR code:', erro.message);
  process.exitCode = 1;
});
