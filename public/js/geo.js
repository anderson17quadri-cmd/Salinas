const RAIO_TERRA_METROS = 6371000;

const paraRadianos = (graus) => (graus * Math.PI) / 180;

/**
 * Distância em metros entre dois pontos (fórmula de Haversine).
 *
 * A fonte de verdade é a função `haversine_metros` no Postgres — esta
 * cópia só serve para avisar o funcionário antes de enviar o registo.
 */
export function distanciaMetros(lat1, lon1, lat2, lon2) {
  const dLat = paraRadianos(lat2 - lat1);
  const dLon = paraRadianos(lon2 - lon1);

  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(paraRadianos(lat1)) * Math.cos(paraRadianos(lat2)) * Math.sin(dLon / 2) ** 2;

  return 2 * RAIO_TERRA_METROS * Math.asin(Math.sqrt(a));
}

/**
 * Localização actual do dispositivo.
 *
 * Rejeita com uma mensagem já escrita para o funcionário — a API do
 * browser devolve códigos que não dizem nada a quem está a bater ponto.
 */
export function obterLocalizacao({ timeout = 15000, precisaoAlta = true } = {}) {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) {
      reject(new Error('Este dispositivo não suporta geolocalização.'));
      return;
    }

    navigator.geolocation.getCurrentPosition(
      (posicao) => resolve(posicao.coords),
      (erro) => {
        const mensagens = {
          1: 'Precisamos da sua localização para registar o ponto. Autorize o acesso nas definições do browser.',
          2: 'Não foi possível obter a sua localização. Verifique se o GPS está ligado.',
          3: 'A localização demorou demasiado tempo. Tente novamente.',
        };
        reject(new Error(mensagens[erro.code] ?? 'Não foi possível obter a sua localização.'));
      },
      { enableHighAccuracy: precisaoAlta, timeout, maximumAge: 0 }
    );
  });
}

/** Localização "se estiver à mão" — usada como extra no fluxo de QR code. */
export async function localizacaoOpcional() {
  try {
    // Só pede se a permissão já tiver sido concedida, para não interromper
    // o registo por QR com uma caixa de permissão inesperada.
    if (navigator.permissions?.query) {
      const estado = await navigator.permissions.query({ name: 'geolocation' });
      if (estado.state !== 'granted') return null;
    }
    return await obterLocalizacao({ timeout: 5000, precisaoAlta: false });
  } catch {
    return null;
  }
}
