// =====================================================================
// Salinas — Edge Function `criar-acesso`
// =====================================================================
// Cria a conta de acesso de um funcionário e devolve uma palavra-passe
// temporária, para o gestor a entregar em mão.
//
// Porquê isto existir: o serviço de email do plano gratuito do Supabase
// está limitado a 2 emails por hora, o que torna o registo por email
// impraticável para dar acesso a uma equipa de uma vez. Numa pastelaria,
// em que o gestor vê toda a gente todos os dias, entregar a palavra-passe
// em mão é mais simples e não depende de caixas de spam.
//
// Autorização: a função **não** decide quem é admin. Usa o token de quem
// chama para ler o funcionário através da API normal — se o RLS não
// deixar ver aquela linha, não há acesso a criar. Assim a regra de
// segurança vive num sítio só (as policies), e não duplicada aqui.
//
// Deploy: ver supabase/funcoes/README.md
// =====================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });

/**
 * Palavra-passe fácil de ditar: sem caracteres que se confundam ao ler
 * em voz alta (0/O, 1/l/I) e com um separador que ajuda a memorizar.
 */
function gerarPalavraPasse(): string {
  const letras = 'ABCDEFGHJKMNPQRSTUVWXYZ';
  const digitos = '23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(10));

  const bloco = (fonte: string, n: number, desvio: number) =>
    Array.from({ length: n }, (_, i) => fonte[bytes[desvio + i] % fonte.length]).join('');

  return `${bloco(letras, 4, 0)}-${bloco(digitos, 4, 4)}-${bloco(letras, 2, 8)}`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ erro: 'Método não suportado.' }, 405);

  const autorizacao = req.headers.get('Authorization');
  if (!autorizacao) return json({ erro: 'Falta autenticação.' }, 401);

  let funcionarioId: string;
  try {
    ({ funcionario_id: funcionarioId } = await req.json());
  } catch {
    return json({ erro: 'Corpo do pedido inválido.' }, 400);
  }
  if (!funcionarioId) return json({ erro: 'Falta o funcionario_id.' }, 400);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

  // Cliente com o token de quem chama: sujeito ao RLS, tal como o painel.
  const comoUtilizador = createClient(url, anon, {
    global: { headers: { Authorization: autorizacao } },
  });

  const { data: funcionario, error } = await comoUtilizador
    .from('funcionarios')
    .select('id, nome, email, user_id, empresa_id')
    .eq('id', funcionarioId)
    .maybeSingle();

  if (error) return json({ erro: error.message }, 400);
  if (!funcionario) {
    // Ou não existe, ou o RLS escondeu-o. A resposta é a mesma de
    // propósito: não vale a pena confirmar a existência de fichas de
    // outras empresas a quem não as pode ver.
    return json({ erro: 'Funcionário não encontrado nesta empresa.' }, 404);
  }

  // Só um admin cria acessos. O RLS deixa o próprio funcionário ver a sua
  // ficha, por isso essa parte tem de ser verificada à parte.
  const { data: souAdmin } = await comoUtilizador.rpc('auth_is_admin');
  if (souAdmin !== true) return json({ erro: 'Apenas administradores.' }, 403);

  if (funcionario.user_id) {
    return json({ erro: 'Este funcionário já tem acesso criado.' }, 409);
  }

  const palavraPasse = gerarPalavraPasse();
  const comoServico = createClient(url, service, { auth: { persistSession: false } });

  // `email_confirm: true` porque quem confirma a identidade é o gestor, ao
  // entregar a palavra-passe em mão — não há email para confirmar.
  const { data: criado, error: erroCriar } = await comoServico.auth.admin.createUser({
    email: funcionario.email,
    password: palavraPasse,
    email_confirm: true,
  });

  if (erroCriar) {
    const jaExiste = /already been registered|already exists/i.test(erroCriar.message);
    return json(
      {
        erro: jaExiste
          ? 'Já existe uma conta com este email. Peça ao funcionário para usar "Esqueci-me da palavra-passe".'
          : erroCriar.message,
      },
      jaExiste ? 409 : 400
    );
  }

  // O trigger `on_auth_user_created` liga a conta à ficha pelo email. Se
  // por alguma razão não tiver ligado, liga-se aqui — sem isto o
  // funcionário entrava e via "não está associado a nenhuma empresa".
  await comoServico
    .from('funcionarios')
    .update({ user_id: criado.user.id })
    .eq('id', funcionario.id)
    .is('user_id', null);

  return json({
    nome: funcionario.nome,
    email: funcionario.email,
    palavra_passe: palavraPasse,
  });
});
