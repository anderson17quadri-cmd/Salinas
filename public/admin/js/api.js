import { createClient } from '../../vendor/supabase.js';

import { obterConfig } from './config.js';

let cliente = null;

export function supabase() {
  if (cliente) return cliente;

  const config = obterConfig();
  if (!config) throw new Error('Projecto Supabase por configurar.');

  cliente = createClient(config.url, config.chaveAnon, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  });
  return cliente;
}

export function reiniciarCliente() {
  cliente = null;
}

/** Mensagens de erro legíveis, em português. */
export function mensagemDeErro(erro, alternativa = 'Ocorreu um erro. Tente novamente.') {
  if (!erro) return alternativa;
  const msg = erro.message || '';

  if (erro.code === '42501' || msg.includes('permission denied')) {
    return 'Não tem permissão para esta operação.';
  }
  if (msg.includes('Invalid login credentials')) return 'Email ou palavra-passe incorrectos.';
  if (msg.includes('Email not confirmed')) return 'Confirme o seu email antes de entrar.';
  if (msg.includes('Failed to fetch')) return 'Sem ligação ao Supabase. Verifique o URL do projecto.';
  if (msg.includes('duplicate key') && msg.includes('email')) {
    return 'Já existe um funcionário com esse email.';
  }
  return msg || alternativa;
}

async function rpc(nome, argumentos = {}) {
  const { data, error } = await supabase().rpc(nome, argumentos);
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------------------
// Sessão e contexto
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
  // Sem `redirectTo`, o Supabase manda o link para o Site URL do projecto
  // — por omissão localhost — e o email ficava inútil. Apontar para a
  // própria página garante que volta para onde o pedido foi feito.
  const destino = location.origin + location.pathname;

  const { error } = await supabase().auth.resetPasswordForEmail(
    email.trim().toLowerCase(),
    { redirectTo: destino }
  );
  if (error) throw error;
}

/** Confirma que o utilizador autenticado é admin e devolve a sua empresa. */
export async function contextoAdmin() {
  const { data: admin, error } = await supabase()
    .from('admins')
    .select('id, empresa_id, nome, email')
    .maybeSingle();
  if (error) throw error;
  if (!admin) return null;

  const { data: empresa, error: erroEmpresa } = await supabase()
    .from('empresas')
    .select('id, nome, morada, latitude, longitude, raio_metros, metodo_qrcode_ativo, metodo_gps_ativo, foto_obrigatoria, timezone, qr_token_atualizado_em, politica_banco_horas, limite_compensacao_meses, regime_folgas')
    .eq('id', admin.empresa_id)
    .single();
  if (erroEmpresa) throw erroEmpresa;

  return { admin, empresa };
}

// ---------------------------------------------------------------------
// Banco de horas
// ---------------------------------------------------------------------
export const bancoHoras = () => rpc('admin_banco_horas');

export const movimentosBancoHoras = (funcionarioId) =>
  rpc('admin_movimentos_banco_horas', { p_funcionario_id: funcionarioId });

export const fecharPeriodoBancoHoras = (ano, mes) =>
  rpc('admin_fechar_periodo_banco_horas', { p_ano: ano, p_mes: mes });

export const registarMovimentoBancoHoras = ({ funcionarioId, saldo, estado, observacao, periodo }) =>
  rpc('admin_registar_movimento_banco_horas', {
    p_funcionario_id: funcionarioId,
    p_saldo: saldo,
    p_status: estado ?? 'aberto',
    p_observacao: observacao ?? null,
    p_periodo_referencia: periodo ?? null,
  });

export const liquidarMovimentoBancoHoras = (id, estado, observacao) =>
  rpc('admin_liquidar_movimento_banco_horas', {
    p_movimento_id: id,
    p_status: estado,
    p_observacao: observacao ?? null,
  });

export async function actualizarEmpresa(empresaId, campos) {
  const { error } = await supabase().from('empresas').update(campos).eq('id', empresaId);
  if (error) throw error;
}

/**
 * Define uma nova palavra-passe para a sessão actual.
 *
 * Usado no fim do fluxo de recuperação: o link do email traz um token que
 * o supabase-js converte em sessão, e é essa sessão que autoriza a troca.
 */
export async function definirPalavraPasse(nova) {
  const { error } = await supabase().auth.updateUser({ password: nova });
  if (error) throw error;
}

// ---------------------------------------------------------------------
// Dashboard e relatórios
// ---------------------------------------------------------------------
export const dashboardHoje = () => rpc('admin_dashboard_hoje');

export const relatorioMensal = (ano, mes) =>
  rpc('admin_relatorio_mensal', { p_ano: ano, p_mes: mes });

// ---------------------------------------------------------------------
// Funcionários
// ---------------------------------------------------------------------
export async function listarFuncionarios() {
  const { data, error } = await supabase()
    .from('funcionarios')
    .select('id, nome, email, cargo, ativo, horas_semanais_esperadas, foto_perfil_url, user_id, created_at')
    .order('nome');
  if (error) throw error;
  return data ?? [];
}

export const criarFuncionario = ({ nome, email, cargo, horasSemanais }) =>
  rpc('admin_criar_funcionario', {
    p_nome: nome,
    p_email: email,
    p_cargo: cargo || null,
    p_horas_semanais: horasSemanais ?? 40,
  });

export const actualizarFuncionario = (id, { nome, cargo, horasSemanais, ativo }) =>
  rpc('admin_atualizar_funcionario', {
    p_funcionario_id: id,
    p_nome: nome ?? null,
    p_cargo: cargo ?? null,
    p_horas_semanais: horasSemanais ?? null,
    p_ativo: ativo ?? null,
  });

/**
 * Cria o acesso de um funcionário e devolve a palavra-passe temporária.
 *
 * Passa por uma Edge Function porque criar contas exige a chave de
 * serviço, que nunca pode estar no navegador. A autorização é feita lá,
 * com o token de quem chama — ver supabase/funcoes/criar-acesso.
 */
export async function criarAcesso(funcionarioId) {
  const { data: sessao } = await supabase().auth.getSession();
  const config = obterConfig();

  const resposta = await fetch(`${config.url}/functions/v1/criar-acesso`, {
    method: 'POST',
    headers: {
      apikey: config.chaveAnon,
      Authorization: `Bearer ${sessao.session?.access_token ?? ''}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ funcionario_id: funcionarioId }),
  });

  const corpo = await resposta.json().catch(() => ({}));
  if (!resposta.ok) throw new Error(corpo.erro || corpo.message || 'Não foi possível criar o acesso.');
  return corpo;
}

export async function obterHorario(funcionarioId) {
  const { data, error } = await supabase()
    .from('horarios_esperados')
    .select('dia_semana, hora_entrada, hora_saida')
    .eq('funcionario_id', funcionarioId)
    .order('dia_semana');
  if (error) throw error;
  return data ?? [];
}

export const definirHorario = (funcionarioId, horarios) =>
  rpc('admin_definir_horario', { p_funcionario_id: funcionarioId, p_horarios: horarios });

// ---------------------------------------------------------------------
// Registos
// ---------------------------------------------------------------------
export async function listarRegistos({ de, ate, funcionarioId, tipo, limite = 1000 }) {
  let query = supabase()
    .from('registos_ponto')
    .select('id, funcionario_id, tipo, metodo, timestamp, latitude, longitude, dentro_do_raio, distancia_metros, foto_url, observacao')
    .order('timestamp', { ascending: false })
    .limit(limite);

  if (de) query = query.gte('timestamp', de);
  if (ate) query = query.lte('timestamp', ate);
  if (funcionarioId) query = query.eq('funcionario_id', funcionarioId);
  if (tipo) query = query.eq('tipo', tipo);

  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

// ---------------------------------------------------------------------
// QR code
// ---------------------------------------------------------------------
export const obterQrToken = () => rpc('admin_obter_qr_token');
export const regenerarQrToken = () => rpc('admin_regenerar_qr_token');

// ---------------------------------------------------------------------
// Justificações
// ---------------------------------------------------------------------
export async function listarJustificacoes(estado) {
  let query = supabase()
    .from('faltas_justificacoes')
    .select('id, funcionario_id, data, motivo, status, anexo_url, created_at, revisto_em')
    .order('created_at', { ascending: false })
    .limit(500);

  if (estado) query = query.eq('status', estado);

  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

export const reverJustificacao = (id, estado) =>
  rpc('admin_rever_justificacao', { p_justificacao_id: id, p_status: estado });

/** URL temporário para abrir um anexo guardado num bucket privado. */
export async function urlAssinado(bucket, caminho, segundos = 300) {
  const { data, error } = await supabase().storage.from(bucket).createSignedUrl(caminho, segundos);
  if (error) throw error;
  return data.signedUrl;
}
