#!/usr/bin/env node
/**
 * Empacota as bibliotecas de terceiros para dentro de public/vendor/.
 *
 *   cd tools && npm install
 *   node gerar-vendor.js
 *
 * Porquê ter isto no repositório em vez de as ir buscar a um CDN:
 *
 *   1. Um registo de ponto é usado todas as manhãs. Se o CDN estiver em
 *      baixo, ninguém consegue bater o ponto — e a culpa nem sequer é
 *      nossa nem há nada a fazer nesse momento.
 *   2. Servidas da mesma origem, as bibliotecas entram no service worker
 *      e a app abre mesmo com a rede fraca.
 *   3. Deixa de haver pedidos a terceiros a partir do telemóvel dos
 *      funcionários.
 *
 * Os ficheiros gerados são versionados de propósito: quem clonar o
 * repositório tem tudo o que precisa para publicar, sem passo de build.
 *
 * Para actualizar uma biblioteca: mude a versão em package.json, corra
 * `npm install` e volte a correr este script.
 */

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

import * as esbuild from 'esbuild';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const VENDOR = path.join(AQUI, '..', 'public', 'vendor');

// Cada entrada re-exporta apenas o que a Salinas usa, para o esbuild
// poder deitar fora o resto.
const BIBLIOTECAS = [
  {
    ficheiro: 'supabase.js',
    pacote: '@supabase/supabase-js',
    conteudo: "export { createClient } from '@supabase/supabase-js';",
  },
  {
    ficheiro: 'html5-qrcode.js',
    pacote: 'html5-qrcode',
    conteudo: "export { Html5Qrcode } from 'html5-qrcode';",
  },
  {
    ficheiro: 'qrcode.js',
    pacote: 'qrcode',
    // O `qrcode` traz um caminho para Node que arrasta o `fs`; o browser
    // só precisa da parte que desenha, exposta em lib/browser.js.
    conteudo: "export { default } from 'qrcode/lib/browser.js';",
  },
];

async function versaoDe(pacote) {
  const nome = pacote.split('/').slice(0, pacote.startsWith('@') ? 2 : 1).join('/');
  const json = JSON.parse(
    await readFile(path.join(AQUI, 'node_modules', nome, 'package.json'), 'utf8')
  );
  return `${json.name}@${json.version}`;
}

async function empacotar({ ficheiro, pacote, conteudo }) {
  const versao = await versaoDe(pacote);

  const resultado = await esbuild.build({
    stdin: {
      contents: conteudo,
      resolveDir: AQUI,
      loader: 'js',
    },
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: ['es2020'],
    minify: true,
    legalComments: 'none',
    write: false,
    define: { 'process.env.NODE_ENV': '"production"' },
  });

  const cabecalho =
    `// ${versao}\n` +
    '// Gerado por tools/gerar-vendor.js — não editar à mão.\n' +
    '// Ver a licença do pacote original em tools/node_modules.\n';

  const destino = path.join(VENDOR, ficheiro);
  await writeFile(destino, cabecalho + resultado.outputFiles[0].text);

  const kb = (Buffer.byteLength(resultado.outputFiles[0].text) / 1024).toFixed(0);
  console.log(`  ${ficheiro.padEnd(20)} ${versao.padEnd(34)} ${kb} kB`);
}

async function principal() {
  await mkdir(VENDOR, { recursive: true });
  console.log('A empacotar bibliotecas para public/vendor/:');

  for (const biblioteca of BIBLIOTECAS) {
    await empacotar(biblioteca);
  }

  console.log('Pronto.');
}

principal().catch((erro) => {
  console.error('Erro ao empacotar:', erro.message);
  process.exitCode = 1;
});
