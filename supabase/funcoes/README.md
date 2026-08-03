# Edge Functions

## `criar-acesso`

Cria a conta de acesso de um funcionário e devolve uma palavra-passe
temporária, para o gestor entregar em mão.

**Porque existe:** o serviço de email do plano gratuito do Supabase está
limitado a 2 emails por hora, e levantar esse limite exige configurar SMTP
próprio. Numa equipa pequena, em que o gestor vê toda a gente, entregar a
palavra-passe em mão é mais rápido e não depende de caixas de spam.

**Autorização:** a função não decide quem é admin por si. Lê o funcionário
com o token de quem chama, através da API normal — se o RLS não deixar ver
aquela linha, não há acesso a criar — e confirma `auth_is_admin()`. A regra
de segurança vive nas policies, não duplicada aqui.

### Instalar

Com a [CLI do Supabase](https://supabase.com/docs/guides/cli):

```bash
supabase functions deploy criar-acesso --project-ref <REF>
```

Ou pela Management API, com um Personal Access Token:

```bash
cd supabase/funcoes/criar-acesso
curl -X POST "https://api.supabase.com/v1/projects/<REF>/functions/deploy?slug=criar-acesso" \
  -H "Authorization: Bearer <TOKEN>" \
  -F 'metadata={"entrypoint_path":"index.ts","name":"criar-acesso","verify_jwt":true};type=application/json' \
  -F 'file=@index.ts;type=application/typescript'
```

As variáveis `SUPABASE_URL`, `SUPABASE_ANON_KEY` e
`SUPABASE_SERVICE_ROLE_KEY` são fornecidas pelo Supabase — não é preciso
configurar nada.
