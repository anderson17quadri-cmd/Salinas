<div align="center">
  <img src="public/assets/logo.png" alt="Pastelaria Salinas" width="320" />

  <h1>Salinas — Registo de Ponto</h1>

  <p>
    Registo de entradas e saídas por <strong>QR code</strong> ou
    <strong>geolocalização</strong>, com painel de gestão para a folha de salários.
  </p>
</div>

---

## O que é

Duas aplicações web sobre um backend Supabase:

| | O quê | Onde |
|---|---|---|
| **App do funcionário** | PWA instalável no telemóvel: bater ponto, ver histórico, justificar faltas | `/` |
| **Painel de administração** | Dashboard, funcionários, registos, QR code, justificações, banco de horas, relatório mensal | `/admin/` |

A app do funcionário é uma **PWA** — corre no browser e instala-se no ecrã
principal com "Adicionar ao Ecrã Principal", em Android e em iPhone. Não há
Play Store, App Store, conta de developer nem Mac envolvidos.

**Limitações de ser PWA**, assumidas de propósito:

- Sem notificações push fiáveis no iPhone (o suporte do Safari é muito limitado).
- Não aparece nas lojas — a instalação é sempre por link ou QR code partilhado
  pela empresa.
- A permissão de câmara pode ser pedida mais vezes do que numa app nativa.

Se um dia fizer sentido publicar nas lojas, o backend fica igual: só o
frontend é que muda.

---

## Estrutura

```
supabase/          Schema, RLS, RPC functions e testes
  01_schema.sql      Tabelas, índices e triggers
  02_rls.sql         Row Level Security e grants (incl. ao nível da coluna)
  03_functions.sql   RPC SECURITY DEFINER — toda a lógica de negócio
  04_storage.sql     Buckets e policies de ficheiros
  05_seed.sql        Dados de arranque (opcional)
  06_banco_horas.sql Banco de horas — fecho de períodos, compensações e saldos
  00_stubs_teste.sql Emulação do Supabase para testes locais — NÃO correr em produção
  testes/            Suites de testes das regras de negócio e do RLS

public/            Tudo o que vai para o GitHub Pages
  index.html         PWA do funcionário
  manifest.json      Instalação no ecrã principal
  sw.js              Service worker
  assets/            Logo e ícones
  css/ js/           Estilos e código da PWA
  vendor/            Bibliotecas de terceiros, empacotadas (ver abaixo)
  admin/             Painel de administração (HTML + JS puro)

tools/             Utilitários Node
  gerar-qrcode.js    Cartaz A4 com o QR code da empresa
  gerar-icones.js    Ícones da PWA a partir do logo
  gerar-vendor.js    Empacota as bibliotecas para public/vendor/
```

### Bibliotecas de terceiros

A Salinas não vai buscar nada a um CDN. As três bibliotecas que usa —
`@supabase/supabase-js`, `html5-qrcode` e `qrcode` — estão empacotadas em
`public/vendor/` e são servidas do mesmo sítio que o resto da app.

É uma decisão deliberada: um registo de ponto é usado todas as manhãs, e se um
CDN estiver em baixo ninguém consegue bater o ponto — sem que haja nada a fazer
nesse momento. Servidas da mesma origem, as bibliotecas entram também no service
worker (a app abre com rede fraca) e deixa de haver pedidos a terceiros a partir
do telemóvel dos funcionários.

Os ficheiros são versionados de propósito: quem clonar o repositório publica sem
qualquer passo de build. Para actualizar uma versão:

```bash
cd tools
# mude a versão em package.json
npm install
node gerar-vendor.js
```

O workflow de deploy recusa publicar se algum `import` externo voltar a aparecer
ou se faltar um dos ficheiros de `public/vendor/`.

---

## Setup

### 1. Base de dados (Supabase)

Crie um projecto em [supabase.com](https://supabase.com) e, no **SQL Editor**,
corra os ficheiros **por esta ordem**:

```
supabase/01_schema.sql
supabase/02_rls.sql
supabase/03_functions.sql
supabase/04_storage.sql
supabase/05_seed.sql        (opcional — dados de exemplo)
supabase/06_banco_horas.sql
```

> `00_stubs_teste.sql` é só para correr o schema num Postgres normal. **Não o
> execute no Supabase**: recria objectos que o Supabase já fornece.

### 2. Empresa, administrador e funcionários

No **SQL Editor**, crie a empresa e o administrador:

```sql
insert into empresas (nome, morada, latitude, longitude, raio_metros)
values ('Pastelaria Salinas', 'Rua …, Lisboa', 38.707751, -9.136592, 100);

insert into admins (empresa_id, nome, email)
select id, 'Anderson', 'admin@exemplo.pt' from empresas where nome = 'Pastelaria Salinas';
```

Depois, em **Authentication → Users**, crie a conta com esse email. O trigger
`on_auth_user_created` liga automaticamente a conta ao registo de admin.

A palavra-passe define-se pela própria app: em **Authentication → URL
Configuration**, ponha o endereço publicado em *Site URL* e em *Redirect URLs*,
e use "Esqueci-me da palavra-passe" no ecrã de entrada. O link do email abre o
ecrã **Definir palavra-passe** — é o mesmo caminho para os funcionários.

Os funcionários criam-se pelo painel (**Funcionários → Novo funcionário**) e,
a seguir, **Criar acesso** — que gera a conta e uma palavra-passe temporária
para entregar em mão. Não é enviado nenhum email.

> **Porquê em mão e não por email:** o serviço de email do plano gratuito do
> Supabase está limitado a **2 emails por hora** em todo o projecto, e levantar
> esse limite exige configurar SMTP próprio. Para dar acesso a uma equipa de uma
> vez, o email não serve. Se configurar SMTP (Authentication → Emails), o
> "Esqueci-me da palavra-passe" e o registo pela própria app passam a ser
> práticos — o botão **Criar acesso** continua a funcionar de qualquer forma.

O funcionário também pode registar-se sozinho na app ("Primeira vez? Criar a
minha conta"), desde que use o email que o gestor registou — mas aí depende da
confirmação por email e do limite acima.

### 3. Coordenadas e métodos de registo

No painel, em **Definições**, defina:

- **Latitude/longitude** do local de trabalho (o botão "Usar a minha localização
  actual" preenche-as se estiver lá) e o **raio** permitido em metros.
- Que **métodos** estão activos — QR code, geolocalização, ou ambos.
- Se a **foto** de confirmação é obrigatória no registo por GPS.

### 4. Publicar (GitHub Pages)

Em **Settings → Pages**, escolha *Source: GitHub Actions*.

Em **Settings → Secrets and variables → Actions**, adicione:

| Secret | Valor |
|---|---|
| `SUPABASE_URL` | `https://xxxx.supabase.co` |
| `SUPABASE_ANON_KEY` | a chave **anon / public** (Project Settings → API) |

Um push para `main` publica automaticamente:

- **PWA do funcionário** → `https://<utilizador>.github.io/Salinas/`
- **Painel de administração** → `https://<utilizador>.github.io/Salinas/admin/`

O Pages serve tudo em **HTTPS**, que é obrigatório para a câmara e o GPS
funcionarem no browser.

> **Nunca** use a chave `service_role` em nenhum destes sítios — ignora o RLS
> por completo. O workflow descodifica qualquer chave que encontre em `public/`
> e recusa o deploy se o papel não for `anon`.

A chave `anon` **pode** ficar no código: é pública por desenho, vive no
JavaScript de qualquer app Supabase e está sempre limitada pelo RLS. Tê-la
embutida evita o ecrã de configuração aparecer aos funcionários.

**Sem secrets configurados** o site continua a funcionar: pede o URL e a chave
na primeira utilização e guarda-os no navegador. Também pode partilhar um link
já configurado com a equipa:

```
https://<utilizador>.github.io/Salinas/?supabase=https://xxxx.supabase.co&key=<chave-anon>
```

A app guarda os valores e limpa-os do endereço.

---

## Instalar a app no telemóvel

Partilhe o endereço da PWA com a equipa (o painel gera um QR code para o efeito
em **QR Code**, ou pode simplesmente enviar o link).

**Android (Chrome)** — abra o link e toque em **Instalar** no aviso que aparece,
ou no menu ⋮ → *Adicionar ao ecrã principal*.

**iPhone (Safari)** — abra o link **no Safari** (não funciona no Chrome do iOS),
toque em **Partilhar** (o quadrado com a seta) e depois em **Adicionar ao Ecrã
Principal**.

Feito isto, a Salinas fica com ícone próprio e abre em ecrã inteiro, sem barra
de endereço.

---

## Usar

### QR code na entrada

Em **QR Code**, o painel mostra o código da empresa com o logo sobreposto,
pronto a imprimir ("Imprimir cartaz"). O código usa correcção de erros de nível
**H**, que recupera até 30% da imagem — é o que permite pôr o logo ao centro sem
quebrar a leitura.

Para gerar o cartaz fora do navegador:

```bash
cd tools && npm install
node gerar-qrcode.js --token "<qr_code_token>" --empresa "Pastelaria Salinas"
```

Produz o PNG do código e um cartaz A4 (SVG e PNG) em `tools/output/`.

Se o código for fotografado ou partilhado indevidamente, use **Regenerar
código**: o antigo deixa de funcionar de imediato e há que afixar o novo.

### Bater ponto

O funcionário abre a app, toca em **Bater Ponto** e — se ambos os métodos
estiverem activos — escolhe entre ler o QR code ou usar o GPS. O feedback é
imediato: *"Entrada registada às 09:03"*.

Fora do raio, o registo **é gravado na mesma**, marcado como fora do raio e com
a distância — o gestor revê-o depois em **Registos**.

---

## Regras de negócio

Estas regras vivem no servidor, em RPC `SECURITY DEFINER`. O cliente **não tem
permissão de escrita** em `registos_ponto`, por isso não há como as contornar
mexendo no frontend.

- **Sequência do ponto.** Não é possível registar duas entradas seguidas sem
  uma saída pelo meio, sair durante uma pausa, ou terminar uma pausa que não
  começou.
  `(nada|saída) → entrada`, `(entrada|fim de pausa) → saída | início de pausa`,
  `início de pausa → fim de pausa`.
- **Duplo toque.** Dois registos com menos de 30 segundos de intervalo são
  recusados.
- **QR de outra empresa.** O token é validado contra a empresa do funcionário —
  ler o código de outra empresa não regista nada.
- **Token secreto.** `empresas.qr_code_token` não é legível pela API, nem pelo
  admin: os grants são ao nível da coluna e o token só sai pelo RPC
  `admin_obter_qr_token()`.
- **Isolamento.** Cada funcionário vê apenas os seus dados; cada admin vê apenas
  o seu `empresa_id`. Garantido por RLS em todas as tabelas.
- **Fusos horários.** A base de dados guarda sempre em **UTC**; a apresentação
  converte para o fuso da empresa (`Europe/Lisbon` por omissão).
- **Ficheiros.** Fotos e anexos vão para buckets privados, sempre em
  `{empresa_id}/{funcionario_id}/…`, com policies que impedem o acesso
  cruzado entre empresas.

### Cálculo das horas

O relatório mensal conta como trabalho os intervalos que começam numa **entrada**
ou num **fim de pausa** e terminam no evento seguinte. As pausas ficam de fora.
As horas esperadas vêm do horário definido por funcionário; sem horário,
estimam-se a partir das horas semanais do contrato.

O relatório e o banco de horas usam a **mesma** função (`_horas_do_periodo`),
por isso não podem divergir.

---

## Banco de horas

Uma conta corrente de horas por funcionário: a diferença entre o que foi
trabalhado e o que era esperado, acumulada ao longo dos meses.

- **Saldo positivo** é crédito, disponível para compensação.
- **Saldo negativo** é dívida de horas — **não é falta**. Uma falta só existe
  quando não há registo nenhum num dia com horário e não há justificação
  pendente ou aprovada; essa contagem aparece à parte, no relatório mensal.

### Fechar um período

Em **Banco de Horas → Fechar período**, escolha o mês. Para cada funcionário é
gravado um movimento com as horas trabalhadas, as esperadas e o saldo.

Refechar o mesmo mês **actualiza** o movimento em vez de duplicar — útil quando
se corrige um registo depois do fecho. Períodos já pagos ou compensados não são
tocados: reescrevê-los apagaria uma decisão já tomada, e o painel diz quais
foram ignorados.

Para automatizar, agende o RPC com [pg_cron](https://supabase.com/docs/guides/database/extensions/pg_cron)
— por exemplo, no primeiro dia de cada mês:

```sql
select cron.schedule(
  'fechar-banco-horas',
  '0 3 1 * *',
  $$ select admin_fechar_periodo_banco_horas(
       extract(year  from now() - interval '1 month')::int,
       extract(month from now() - interval '1 month')::int
     ) $$
);
```

### Saldo acumulado

`funcionarios.saldo_banco_horas` é sempre **recalculado** a partir dos movimentos
em aberto, nunca incrementado. Somar deltas dava saldos que, ao fim de alguns
meses e algumas correcções, deixavam de bater certo com o histórico — e num
saldo de horas isso é dinheiro.

Liquidar um movimento (**Compensado**, **Pago** ou **Descontado**) tira-o do
acumulado sem o apagar do histórico. Reabri-lo devolve-o ao saldo.

### Movimentos manuais

**Lançar** regista horas fora do fecho automático: pagar horas extra, dar uma
folga a partir do crédito, ou corrigir um acerto combinado. O sinal segue a
mesma convenção — uma folga de 8 h lança-se como `-8`.

### Política da empresa

Em **Definições**:

| Política | O que significa |
|---|---|
| `apenas_reportar` | O saldo é só informativo (por omissão) |
| `compensar_folga` | O crédito pode ser convertido em dias de folga |
| `desconto_automatico` | A dívida é descontada no relatório de salário |
| `pagar_extra` | O crédito é sinalizado para pagamento de horas extra |

O **limite de compensação** (12 meses por omissão, como é típico em Portugal)
faz o painel assinalar os saldos que já ultrapassaram o prazo e têm de ser
decididos.

O funcionário vê o seu saldo em destaque no ecrã **Histórico** da app — verde
quando está a crédito, vermelho quando está em dívida.

---

## Testes

O schema tem uma suite de testes que cobre as regras de negócio, o isolamento
entre empresas e as permissões. Corre num Postgres local descartável, sem tocar
no projecto Supabase:

```bash
./supabase/testes/correr.sh
```

Cobre, entre outras coisas: a fórmula de Haversine, a máquina de estados do
ponto, a rejeição de tokens de outra empresa, o registo fora do raio, o
isolamento por RLS, a impossibilidade de ler `qr_code_token` ou de escrever
directamente em `registos_ponto`, a regeneração do token e o relatório mensal.

---

## Desenvolvimento local

A câmara e o GPS exigem um contexto seguro. `localhost` conta como seguro, por
isso basta servir a pasta:

```bash
cd public && python3 -m http.server 4173
```

Depois abra `http://localhost:4173/` (PWA) ou `http://localhost:4173/admin/`
(painel) e introduza o URL e a chave anon no ecrã de configuração.

Para testar num telemóvel real, precisa de HTTPS — use `ngrok`, `cloudflared`
ou publique numa branch de pré-visualização.

---

## Identidade visual

O logo da Pastelaria Salinas está em `public/assets/logo.png` (wordmark sobre o
laranja da marca, `#F5A323`). É usado no splash e no login da PWA, no cabeçalho
do painel, no centro do QR code e como ícone da app.

Para o substituir, troque o ficheiro e regenere os ícones:

```bash
cd tools && npm install
node gerar-icones.js
```

Gera `icone-192.png`, `icone-512.png`, `icone-maskable-512.png` e
`apple-touch-icon.png`. Se mudar o laranja, actualize também `--laranja` em
`public/css/app.css`, `--primaria` em `public/admin/css/estilos.css` e
`theme_color`/`background_color` em `public/manifest.json` — o PNG do logo traz
o fundo incorporado e uma cor diferente daria uma emenda visível.

---

## Segurança

- Nenhuma credencial no repositório. O `.env` está no `.gitignore` e a
  configuração entra por secrets no deploy ou por localStorage.
- A chave `anon` é pública por desenho e está sempre limitada pelo RLS. A
  `service_role` não pode aparecer em lado nenhum do frontend — o workflow de
  deploy falha se a detectar.
- Toda a escrita sensível passa por RPC `SECURITY DEFINER` com validação de
  permissões lá dentro.
