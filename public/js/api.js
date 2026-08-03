import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

import { obterConfig } from './config.js';

let cliente = null;

export function supabase() {
  if (cliente) return cliente;

  const config = obterConfig();
  if (!config) throw new Error('Projecto Supabase por configurar.');

  cliente = createClient(config.url, config.chaveAnon, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
  });
  return cliente;
}

export function reiniciarCliente() {
  cliente = null;
}

/** Traduz erros do Supabase/Postgres em mensagens para o funcionário. */
export function mensagemDeErro(erro, alternativa = 'Ocorreu um erro. Tente novamente.') {
  if (!erro) return alternativa;
  const msg = erro.message || '';

  if (erro.code === '42501' || msg.includes('permission denied')) {
    return 'Não tem permissão para esta operação.';
  }
  if (msg.includes('Invalid login credentials')) return 'Email ou palavra-passe incorrectos.';
  if (msg.includes('Email not confirmed')) return 'Confirme o seu email antes de entrar.';
  if (msg.includes('Failed to fetch') || msg.includes('NetworkError')) {
    return 'Sem ligação ao servidor. Verifique a Internet.';
  }
  return msg || alternativa;
}

async function rpc(nome, argumentos = {}) {
  const { data, error } = await supabase().rpc(nome, argumentos);
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------------------
// Sessão
// ---------------------------------------------------------------------
export async function entrar(email, palavraPasse) {
  const { error } = await supabase().auth.signInWithPassword({
    email: email.trim().toLowerCase(),
    password: palavraPasse,
  });
  if (error) throw error;
}

export async function sair() {
  await supabase().auth.signOut();
}

export async function sessaoActual() {
  const { data } = await supabase().auth.getSession();
  return data.session ?? null;
}

export async function recuperarPalavraPasse(email) {
  const { error } = await supabase().auth.resetPasswordForEmail(email.trim().toLowerCase());
  if (error) throw error;
}

// ---------------------------------------------------------------------
// Registo de ponto
// ---------------------------------------------------------------------
export const estadoAtual = () => rpc('meu_estado_atual');

/** Check-in por QR code. A localização é opcional e vai só como extra. */
export const registarPorQrCode = ({ token, tipo, latitude, longitude, fotoUrl, observacao }) =>
  rpc('registar_ponto_qrcode', {
    p_token: token,
    p_tipo: tipo,
    p_latitude: latitude ?? null,
    p_longitude: longitude ?? null,
    p_foto_url: fotoUrl ?? null,
    p_observacao: observacao ?? null,
  });

/** Check-in por geolocalização. O raio é sempre revalidado no servidor. */
export const registarPorGps = ({ tipo, latitude, longitude, fotoUrl, observacao }) =>
  rpc('registar_ponto_gps', {
    p_tipo: tipo,
    p_latitude: latitude,
    p_longitude: longitude,
    p_foto_url: fotoUrl ?? null,
    p_observacao: observacao ?? null,
  });

export async function listarRegistos({ de, ate, tipo }) {
  let query = supabase()
    .from('registos_ponto')
    .select('id, tipo, metodo, timestamp, latitude, longitude, dentro_do_raio, distancia_metros, foto_url, observacao')
    .gte('timestamp', de)
    .lte('timestamp', ate)
    .order('timestamp', { ascending: false });

  if (tipo) query = query.eq('tipo', tipo);

  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

// ---------------------------------------------------------------------
// Banco de horas
// ---------------------------------------------------------------------
export const meuBancoHoras = () => rpc('meu_banco_horas');

// ---------------------------------------------------------------------
// Perfil e horário
// ---------------------------------------------------------------------
export async function obterHorario(funcionarioId) {
  const { data, error } = await supabase()
    .from('horarios_esperados')
    .select('dia_semana, hora_entrada, hora_saida')
    .eq('funcionario_id', funcionarioId)
    .order('dia_semana');
  if (error) throw error;
  return data ?? [];
}

export async function actualizarPerfil(funcionarioId, campos) {
  const { error } = await supabase().from('funcionarios').update(campos).eq('id', funcionarioId);
  if (error) throw error;
}

// ---------------------------------------------------------------------
// Justificações
// ---------------------------------------------------------------------
export async function listarJustificacoes(funcionarioId) {
  const { data, error } = await supabase()
    .from('faltas_justificacoes')
    .select('id, data, motivo, status, anexo_url, created_at')
    .eq('funcionario_id', funcionarioId)
    .order('data', { ascending: false })
    .limit(50);
  if (error) throw error;
  return data ?? [];
}

export async function criarJustificacao({ funcionarioId, data: dataFalta, motivo, anexoUrl }) {
  const { error } = await supabase().from('faltas_justificacoes').insert({
    funcionario_id: funcionarioId,
    data: dataFalta,
    motivo,
    anexo_url: anexoUrl ?? null,
    status: 'pendente',
  });
  if (error) throw error;
}

// ---------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------
/**
 * Carrega um ficheiro respeitando a convenção de caminhos exigida pelas
 * policies: {empresa_id}/{funcionario_id}/{ficheiro}.
 */
export async function carregarFicheiro({ bucket, empresaId, funcionarioId, ficheiro }) {
  const extensao = (ficheiro.type?.split('/')[1] || 'jpg').replace('jpeg', 'jpg');
  const caminho = `${empresaId}/${funcionarioId}/${Date.now()}.${extensao}`;

  const { error } = await supabase().storage.from(bucket).upload(caminho, ficheiro, {
    contentType: ficheiro.type || 'image/jpeg',
    upsert: false,
  });
  if (error) throw error;

  return caminho;
}

export function urlPublico(bucket, caminho) {
  return supabase().storage.from(bucket).getPublicUrl(caminho).data.publicUrl;
}
