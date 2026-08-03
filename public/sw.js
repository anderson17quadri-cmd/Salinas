/* =====================================================================
   Salinas — service worker
   =====================================================================
   Objectivo: permitir a instalação no ecrã principal e um arranque
   instantâneo. NÃO serve para trabalhar offline a sério — bater ponto
   exige rede, e um registo guardado em fila que só chegasse ao servidor
   horas depois daria uma hora errada no cartão de ponto.

   Estratégia:
   - Shell da app (HTML/CSS/JS/ícones): stale-while-revalidate.
   - Supabase e qualquer outro pedido não-GET: sempre rede, nunca cache.
   ===================================================================== */

const VERSAO = 'salinas-v1';
const CACHE_SHELL = `${VERSAO}-shell`;

const SHELL = [
  './',
  'index.html',
  'manifest.json',
  'css/app.css',
  'js/app.js',
  'js/api.js',
  'js/config.js',
  'js/ui.js',
  'js/geo.js',
  'js/scanner.js',
  'js/ecrans/inicio.js',
  'js/ecrans/historico.js',
  'js/ecrans/faltas.js',
  'js/ecrans/perfil.js',
  'assets/icone-192.png',
  'assets/icone-512.png',
  'assets/apple-touch-icon.png',
];

self.addEventListener('install', (evento) => {
  evento.waitUntil(
    caches
      .open(CACHE_SHELL)
      // `addAll` falha inteiro se um único ficheiro falhar; guardar um a
      // um evita que a instalação rebente por causa de um asset opcional.
      .then((cache) => Promise.allSettled(SHELL.map((url) => cache.add(url))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (evento) => {
  evento.waitUntil(
    caches
      .keys()
      .then((chaves) =>
        Promise.all(chaves.filter((c) => !c.startsWith(VERSAO)).map((c) => caches.delete(c)))
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (evento) => {
  const { request } = evento;

  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Tudo o que toca em dados (Supabase, storage, auth) passa directo à
  // rede: uma resposta em cache aqui mostraria registos desactualizados.
  if (url.origin !== self.location.origin) return;

  evento.respondWith(
    caches.match(request).then((emCache) => {
      const daRede = fetch(request)
        .then((resposta) => {
          if (resposta.ok) {
            const copia = resposta.clone();
            caches.open(CACHE_SHELL).then((cache) => cache.put(request, copia));
          }
          return resposta;
        })
        .catch(() => emCache);

      return emCache || daRede;
    })
  );
});
