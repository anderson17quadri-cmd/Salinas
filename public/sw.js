/* =====================================================================
   Salinas — service worker
   =====================================================================
   Objectivo: permitir a instalação no ecrã principal e um arranque
   instantâneo. NÃO serve para trabalhar offline a sério — bater ponto
   exige rede, e um registo guardado em fila que só chegasse ao servidor
   horas depois daria uma hora errada no cartão de ponto.

   Estratégia: **rede primeiro**, cache só como rede de segurança.

   A versão anterior servia a cache primeiro e actualizava por trás
   (stale-while-revalidate). Parece boa ideia — abre instantaneamente —
   mas significa que uma correcção publicada só chega ao telemóvel na
   utilização *seguinte*. Aconteceu mesmo: mudou-se a configuração da
   app e os telemóveis que já a tinham instalada continuaram a mostrar a
   versão antiga.

   Como bater o ponto exige rede de qualquer forma, ir primeiro à rede
   não custa nada em prática e garante que o que está no telemóvel é o
   que está publicado. Sem rede, a cache entra e a app pelo menos abre.

   Não há pedidos a CDN: as bibliotecas são servidas da mesma origem.
   ===================================================================== */

// Carimbado com o commit em cada publicação (ver .github/workflows/deploy.yml).
// Sem isto, era preciso lembrar de mudar este número à mão sempre que um
// ficheiro mudasse — e esquecer uma vez chega para os telemóveis ficarem
// com a versão antiga guardada.
const VERSAO = 'salinas-__VERSAO__';
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
  // Bibliotecas empacotadas localmente (ver tools/gerar-vendor.js): sem
  // elas a app nem arranca, por isso vão para a cache do shell.
  'vendor/supabase.js',
  'vendor/html5-qrcode.js',
  'assets/logo.png',
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
    fetch(request)
      .then((resposta) => {
        if (resposta.ok) {
          const copia = resposta.clone();
          caches.open(CACHE_SHELL).then((cache) => cache.put(request, copia));
        }
        return resposta;
      })
      // Sem rede (ou falha), vale o que estiver guardado.
      .catch(() => caches.match(request).then((emCache) =>
        emCache || Response.error()
      ))
  );
});
