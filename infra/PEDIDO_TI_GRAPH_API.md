# Pedido de infraestrutura: acesso automatizado ao SharePoint (Microsoft Graph API)

> **Como usar este documento:** é um material de apoio para uma conversa com a TI,
> no mesmo formato do pedido anterior ([`PEDIDO_TI.md`](PEDIDO_TI.md), sobre o
> servidor de banco de dados). Traz o contexto, o que está sendo pedido e as
> decisões que dependem da TI para avançar. Este pedido é independente do anterior
> e não bloqueia nem depende dele: pode ser levado à TI a qualquer momento, mesmo
> em paralelo a outras frentes do projeto.

## 1. O contexto, em um parágrafo

Parte dos dados que alimentam o projeto (o de-para de gerentes, o headcount de
corretores, o apoio de classificação de leads, entre outras planilhas) vem de
arquivos Excel mantidos à mão pelo backoffice, guardados no SharePoint da empresa.
Hoje, o jeito de buscar esses arquivos é um analista abrir um túnel SSH até a
máquina de produção, a partir do próprio notebook, porque o script que lê essas
planilhas (`popular_seeds.py`) depende de um caminho de arquivo local, só
alcançável numa máquina com o OneDrive da empresa sincronizado (o notebook do
analista, nunca a máquina de produção, que já tentou sincronizar sem sucesso). O
pedido aqui é trocar esse caminho por uma busca direta na nuvem do SharePoint, via
API da Microsoft, para que a atualização dessas planilhas não dependa mais de
ninguém logado num computador específico, com uma sessão de túnel aberta.

## 2. O que está sendo pedido

Um registro de aplicativo (**App Registration**) no Azure AD / Microsoft Entra ID
do tenant da Pafil, com permissão para ler arquivos de um ou dois sites específicos
do SharePoint, sem interação de usuário.

| Item | Pedido | Observação |
|---|---|---|
| App Registration | Um novo registro de aplicativo, de uso exclusivo deste projeto | Gera um `Client ID` e um `Tenant ID`, que não são segredo, e podem ser compartilhados livremente |
| Permissão de API (Microsoft Graph) | `Sites.Selected`, tipo **Application** (não Delegated), só leitura | Deliberadamente não é `Sites.Read.All`: essa permissão daria acesso de leitura a todo o SharePoint da empresa. `Sites.Selected` restringe o aplicativo a só os sites explicitamente concedidos (seção 4a) |
| Credencial | Um Client Secret ou um certificado, com uma data de expiração definida de antemão | Certificado é a opção mais robusta se a TI já tiver uma PKI disponível; um Client Secret com prazo de 12 a 24 meses é uma alternativa aceitável, desde que a rotação fique agendada (seção 4c) |
| Consentimento | "Grant admin consent" para a permissão acima, dentro do portal do Azure | Só um Global Administrator ou Application Administrator do tenant consegue conceder isso |

**Uma ordem de grandeza do custo:** zero. Isso usa um recurso já incluído em
qualquer licenciamento Microsoft 365 que já cobre o SharePoint da empresa hoje. Não
há instância, servidor ou assinatura nova envolvida.

## 3. Segurança: por que este desenho é mais restrito do que parece

Este pedido concede acesso automatizado a uma aplicação, não a uma pessoa, e vale
deixar claro o que isso significa na prática:

- **`Sites.Selected` só enxerga o que for explicitamente liberado.** Diferente de
  `Sites.Read.All`, essa permissão não abre a porta pra nenhum outro site do
  SharePoint da empresa, mesmo que o aplicativo tecnicamente pudesse pedir. Cada
  site precisa ser concedido individualmente, numa chamada de API separada, feita
  por quem administra o site (seção 4a).
- **É acesso de aplicativo, não de usuário.** A autenticação usa o fluxo
  `client credentials`: o aplicativo se autentica sozinho, com o `Client ID` e o
  segredo, sem nenhum usuário digitando senha ou passando por MFA. Isso é
  justamente o que permite essa busca rodar de forma automatizada e agendada, sem
  depender de ninguém logado.
- **É só leitura.** O aplicativo não teria permissão de escrever, apagar ou
  modificar nada nos sites concedidos, só de ler o conteúdo dos arquivos.
- **O segredo fica guardado do mesmo jeito que as outras credenciais do projeto**
  (o token do CVCRM, a senha do Postgres): em variável de ambiente, nunca no
  repositório, nunca em mensagem ou print de tela.

> Na prática, isso significa que este aplicativo consegue ler exatamente as
> planilhas que hoje já são lidas manualmente através do túnel, e nada além
> disso.

## 4. As decisões que dependem da TI (o que preciso levar da conversa)

**(a) Quais sites do SharePoint conceder acesso.** A biblioteca que hoje guarda as
planilhas de origem é a "COMERCIAL - Documentos" (a mesma que o OneDrive do
notebook do analista já sincroniza). Preciso confirmar com a TI, ou com quem
administra esse site, o nome exato e a URL para que o acesso seja concedido a ele
especificamente, via `Sites.Selected`. Se as planilhas estiverem espalhadas em mais
de um site, o mesmo processo se repete para cada um.

**(b) Client Secret ou certificado.** Se a TI já usa certificados para outras
integrações, essa é a opção mais robusta. Caso contrário, um Client Secret com
prazo definido (recomendo 12 meses) resolve, desde que a rotação fique agendada
desde já, no mesmo espírito da política de rotação do token do CVCRM (`SKILL.md`,
seção 7.2): trocar o secret por rotina, ou imediatamente se ele circular fora do
lugar onde deveria estar guardado.

**(c) Quem concede o "admin consent".** Esse clique só pode ser feito por um
Global Administrator ou Application Administrator do tenant. Preciso saber quem é
essa pessoa na TI, para que o registro do aplicativo (item a ser criado por mim ou
por quem a TI designar) seja seguido desse consentimento sem depender de uma
segunda rodada de agendamento.

**Este pedido não bloqueia nenhuma outra frente do projeto.** Enquanto ele não é
atendido, a atualização das planilhas continua funcionando do jeito atual (túnel
SSH a partir do notebook do analista). Não há pressa artificial aqui, mas também
não há motivo para esperar: pode ser levado à TI a qualquer momento, em paralelo a
qualquer outra conversa em andamento.

## 5. Divisão de responsabilidades

| Quem | O que faz |
|---|---|
| TI | Cria o App Registration (ou aprova que o analista crie, se tiver essa permissão no tenant), concede a permissão `Sites.Selected` como Application, dá o admin consent, gera o Client Secret ou certificado, e concede ao aplicativo o acesso ao(s) site(s) do item 4a |
| Analista (eu) | Recebe o `Client ID`, o `Tenant ID` e o segredo, guarda em variável de ambiente, implementa a busca via Microsoft Graph API, e testa contra os arquivos reais antes de desligar o caminho manual atual |

## 6. O que acontece depois da aprovação

| Etapa | O que é feito | Tempo estimado |
|---|---|---|
| 1 | TI cria o App Registration, concede a permissão e o admin consent | Depende só da disponibilidade da TI |
| 2 | TI concede o acesso ao(s) site(s) específico(s) (item 4a) | Poucos minutos, depois da etapa 1 |
| 3 | Implementar e testar a busca via Graph API contra as planilhas reais | Cerca de 1 a 2 dias |
| 4 | Trocar a leitura local por essa busca automática nas rotinas que hoje dependem do túnel | Já incluído na etapa 3 |
