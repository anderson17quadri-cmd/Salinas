#!/usr/bin/env node
/**
 * Gera os ícones da PWA a partir do logo da Pastelaria Salinas.
 *
 *   cd tools && npm install
 *   node gerar-icones.js
 *
 * Fonte: public/assets/logo.png (wordmark sobre o laranja da marca).
 * Se o logo for substituído, basta voltar a correr este script.
 *
 * Produz, em public/assets/:
 *   icone-192.png            ícone do manifest
 *   icone-512.png            ícone grande (splash em Android)
 *   icone-maskable-512.png   com a margem que o recorte adaptativo exige
 *   apple-touch-icon.png     180×180, usado pelo iOS
 *   logo-quadrado.png        1024×1024, versão quadrada reutilizável
 */

import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

import sharp from 'sharp';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const ASSETS = path.join(AQUI, '..', 'public', 'assets');
const LOGO = path.join(ASSETS, 'logo.png');

// Laranja exacto do ficheiro do logo — tem de bater certo com o CSS,
// senão vê-se a emenda entre o PNG e o fundo do ecrã.
const LARANJA = { r: 245, g: 163, b: 35, alpha: 1 };

/**
 * Compõe o logo centrado num quadrado laranja.
 *
 * `ocupacao` é a fracção da largura que o wordmark ocupa. Os ícones
 * "maskable" precisam de mais folga porque o Android recorta as bordas.
 */
async function quadrado(tamanho, ocupacao) {
  const largura = Math.round(tamanho * ocupacao);

  const logo = await sharp(LOGO)
    .resize({ width: largura, withoutEnlargement: false })
    .toBuffer();

  return sharp({
    create: { width: tamanho, height: tamanho, channels: 4, background: LARANJA },
  })
    .composite([{ input: logo, gravity: 'center' }])
    .png()
    .toBuffer();
}

async function gerar(nome, tamanho, ocupacao) {
  const png = await quadrado(tamanho, ocupacao);
  await writeFile(path.join(ASSETS, nome), png);
  console.log(`  ${nome}  (${tamanho}×${tamanho})`);
}

async function principal() {
  console.log('A gerar ícones a partir de public/assets/logo.png:');

  await gerar('logo-quadrado.png', 1024, 0.86);
  await gerar('icone-512.png', 512, 0.86);
  await gerar('icone-192.png', 192, 0.86);
  await gerar('apple-touch-icon.png', 180, 0.86);
  // Zona segura dos ícones maskable: o círculo central de 80%. Com 62%
  // de ocupação o wordmark nunca é cortado, seja qual for a máscara.
  await gerar('icone-maskable-512.png', 512, 0.62);

  console.log('Pronto.');
}

principal().catch((erro) => {
  console.error('Erro ao gerar os ícones:', erro.message);
  process.exitCode = 1;
});
