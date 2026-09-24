# Runbook da integração GHL x CVCRM (Fase 1)

Este arquivo documenta a infraestrutura que sustenta o workflow
`workflow_n8n.json` em produção: como o n8n (que roda numa VM sem IP público,
dentro do WSL2, ver `infra/RUNBOOK_WINDOWS.md`) recebe webhook de duas
plataformas na nuvem (GoHighLevel e CVCRM), sem depender de domínio próprio
nem de TI. Registrado em 18/set/2026, depois de uma sessão inteira gastada
descobrindo, na prática, que a solução "óbvia" (domínio fixo gratuito do
ngrok) não se comporta do jeito que a documentação oficial promete.

## Por que existe um túnel aqui

GHL e CVCRM são serviços na nuvem: o webhook deles sai de fora, da internet,
e precisa alcançar o n8n. A VM não tem IP público nem domínio próprio, e a TI
não estava disponível pra liberar DNS quando essa necessidade surgiu. A
solução usada foi o **domínio de desenvolvimento gratuito do ngrok** (um
domínio por conta, sem custo, que a documentação oficial descreve como
estável entre reinícios).

**Isso é uma solução de contorno, não a definitiva.** O plano original
(`estou-pensando-em-um-deep-cupcake.md`, Fase 0) previa um subdomínio próprio
da Pafil via TI. Assim que isso existir, vale migrar pra lá e desativar o
ngrok, porque a experiência de hoje mostrou que ele é mais frágil do que a
documentação sugere (seção seguinte).

## A armadilha do domínio "fixo"

A documentação do ngrok diz que rodar `ngrok http PORTA --url "https://"`
(sem escolher um nome, deixando a conta escolher) dá um domínio estável, que
não muda entre reinícios. **Na prática, isso mudou três vezes na mesma
tarde** (`a7bf-...`, depois `51a0-...`, depois `401d-...`), sem um motivo
claro identificado (a suspeita mais forte é conflito entre múltiplos
processos `ngrok.exe` rodando ao mesmo tempo, sem ter sido finalizados
direito entre uma tentativa e outra).

**Domínio atual, confirmado funcionando em 18/set/2026:**

```
https://401d-179-94-63-6.ngrok-free.app
```

**Regra de ouro, pra não repetir a tarde inteira de depuração:** nunca
assuma que o domínio continua o mesmo depois de reiniciar o processo do
ngrok. Sempre confirme de novo, e sempre pelos dois lados:

1. **Local:** abre `http://127.0.0.1:4040` na VM e olha a URL em
   `Configuration > Tunnels > URL`.
2. **Externo, o que realmente importa:** o painel local pode mostrar
   "online" mesmo com o túnel de fato offline (a conexão do agente com a
   nuvem do ngrok caiu, mas o painel local não percebeu). A prova real é
   tentar acessar a URL de fora, de um dispositivo que não seja essa
   máquina/rede. Se dermos `ERR_NGROK_3200` ("offline"), o túnel não presta
   pra nada, mesmo o painel local dizendo o contrário.

Se o domínio mudar (depois de qualquer reinício do processo, planejado ou
não), **os dois lugares abaixo precisam ser atualizados juntos**, ou o
webhook correspondente simplesmente para de chegar, sem erro visível em
lugar nenhum (a plataforma de origem tenta mandar pra uma URL morta e
desiste em silêncio):

- **CVCRM:** Configurações → Integrações → webhook "Teste integracao n8n" →
  campo Endereço → `https://<dominio-atual>/webhook/cvcrm-evento`
- **GHL:** dentro do workflow "Pafil - Integração CVCRM <--> GHL" → ação
  Webhook → campo URL → `https://<dominio-atual>/webhook/ghl-evento`

## Como o túnel fica de pé sozinho

O processo do ngrok roda como uma Tarefa Agendada do Windows (mesmo padrão
de `infra/RUNBOOK_WINDOWS.md`), não como uma janela de PowerShell aberta:

- **Nome da tarefa:** `ngrok - integracao Pafil`
- **Ação:** `C:\pafil\ngrok\ngrok.exe`, argumentos `http 5678 --url "https://"`, "Iniciar em" `C:\pafil\ngrok`
- **Disparador:** ao iniciar o sistema
- **Configurações:** "Executar estando o usuário conectado ou não",
  reiniciar a cada 1 minuto em caso de falha, até 999 vezes

**Isso não substitui verificação.** Depois de qualquer reinício da VM, ou
depois de mexer manualmente no processo do ngrok, sempre reconfira o domínio
pelos dois métodos da seção anterior antes de considerar o túnel confiável de
novo.

## A outra metade: o n8n também precisa estar de pé

O ngrok só encaminha tráfego para `localhost:5678`. Se o n8n (que roda em
Docker dentro do WSL2) estiver fora do ar, o túnel pode estar perfeitamente
online e mesmo assim nada funciona.

**A mesma regra já documentada em `SKILL.md` vale aqui:** mantenha sempre
uma janela de terminal WSL conectada, e nunca digite `exit` nela. Fechar o
último terminal anexado ao WSL derruba a VM inteira do WSL2 (e com ela, os
containers do n8n), mesmo com `vmIdleTimeout=-1` configurado.

Antes de investigar qualquer falha de webhook, confira nessa ordem:

1. `docker ps` (dentro do WSL, numa janela mantida aberta) mostra o
   container do n8n rodando?
2. `http://localhost:5678` (do navegador da VM) mostra a tela do n8n?
3. Só depois disso, investiga o túnel/domínio.

## Incidente: webhook de produção sem escopo criou ~90 contatos indevidos no GHL

Em 22/set/2026, na manhã seguinte a cadastrar os 4 webhooks de produção no
CVCRM (Nova interação, Novo lead, Alteração de situação, Associar
Atendente), apareceram ~90 contatos novos no GHL sem nome, de leads reais
de **outros empreendimentos**, não do piloto (FIUSA 016).

**Causa:** os 4 webhooks foram cadastrados com o campo "Empreendimentos" em
branco (= todos), copiando o padrão do webhook de teste original. Isso era
seguro enquanto o despacho só sabia **atualizar** contato existente no GHL
(falhava com 404 pra qualquer lead sem contato, sem criar nada). Na mesma
sessão em que os 4 webhooks foram cadastrados, também foi adicionada a
capacidade de **criar** contato novo no GHL quando não existe (ver node
`Tem contato GHL?` no workflow). A combinação das duas mudanças não foi
reconsiderada: qualquer lead de qualquer empreendimento que mudasse de
situação passou a criar contato novo no GHL automaticamente, fora do
escopo do piloto.

**Correção:** os 4 webhooks no CVCRM foram restritos ao empreendimento
FIUSA 016 (campo "Empreendimentos" preenchido, não mais em branco). Os ~90
contatos criados indevidamente foram identificados por SQL (cruzando
`integracao.fila_sync` × `integracao.depara_contato` × `bronze.leads` pelo
empreendimento real do lead) e apagados via um workflow n8n temporário
chamando `DELETE /contacts/:id` da API do GHL, um por um.

**Lição:** sempre que uma mudança adiciona uma capacidade de **escrita/criação**
nova a um caminho que antes só falhava com segurança (404, erro), reavaliar
o escopo de tudo que alimenta esse caminho — um filtro "em branco = todos"
que era inofensivo vira um risco real assim que o destino passa a criar
dado em vez de só tentar atualizar.

**Segunda leva, mesmo dia (22/set/2026):** poucas horas depois da correção
acima, apareceu mais um lote de ~91 contatos indevidos, incluindo leads
**nunca tocados antes** (não vieram dos 4 webhooks). Causa: o node
`Reconciliar CVCRM` estava **ativado** (deveria estar desativado desde
21/set — não ficou claro exatamente quando/como voltou a ficar ativo).
Esse node roda a cada 6h e varre `bronze.leads` inteiro via
`integracao.v_reconciliacao_cvcrm`, sem nenhum filtro de empreendimento —
diferente dos webhooks, que já tinham sido corrigidos. Um disparo agendado
dele (identificável pelo `criado_em` idêntico em dezenas de linhas de
`fila_sync`, sinal de INSERT em lote numa transação só) recriou o mesmo
tipo de problema em escala maior.

**Correção mais robusta desta vez:** em vez de só reativar a disciplina de
manter o node desativado (já provou falhar uma vez), a restrição de
empreendimento foi movida pra dentro da própria
`integracao.v_reconciliacao_cvcrm` (`WHERE l.empreendimento_ultimo =
'FIUSA 016'`). Mesmo que o node seja reativado de novo, por engano ou por
qualquer motivo, o dano fica contido ao escopo do piloto — a proteção não
depende mais de ninguém lembrar de manter um toggle desligado.

**Lição adicional:** quando uma proteção depende só de "lembrar de manter
X desativado", ela vai falhar eventualmente. Preferir sempre restringir o
escopo na fonte de dado (a query/view), que não pode ser "esquecida
ativada" da mesma forma que um node num canvas.

## Webhook de Oportunidade do GHL: o payload real não bate com a doc oficial

A documentação formal da API do GHL (`OpportunityStageUpdate`) descreve um
payload com `pipelineStageId` (um UUID) e `contactId`. **Isso não é o que a
ação de Webhook dentro de um Workflow do GHL manda de verdade** (confirmado
em 23/set/2026, testando contra o payload real). Essa ação achata o corpo
do jeito de sempre (`phone`, `email`, `tags`, `contact_id`, os Custom
Fields todos) e acrescenta os campos da oportunidade como texto solto,
incluindo dois erros de digitação do próprio GHL (não são erros nossos):

- `pipleline_stage`: nome da etapa **em texto** (ex.: `"Em Negociação"`),
  não um ID
- `pipleline_id`: ID do pipeline (esse funciona igual ao que a doc diz)

Como o nome da etapa já vem pronto, o de-para em
`integracao.depara_situacao_ghl` acabou não precisando do ID de estágio
pra nada — a coluna `pipeline_stage_id_ghl` fica só de referência. E como
telefone/email já vêm no corpo, não precisou de uma chamada `GET
/contacts/:id` separada (um node inteiro foi construído e depois removido
por causa dessa suposição errada).

**Lição:** a documentação formal do GHL descreve o formato de um mecanismo
de webhook (assinatura direta via API); a ação de "Webhook" dentro de um
Workflow visual é outro mecanismo, com formato próprio, que não está
documentado do mesmo jeito. Sempre testar contra o payload real antes de
confiar na doc — já vimos isso acontecer também do lado do Contato (ver
comentário no node `Normalizar evento GHL`).

## Notas do GHL e interações do CVCRM: o gatilho "Nova interação" não existe de verdade

Testado ao vivo em 23/set/2026: o gatilho "Nova interação" cadastrado no
painel de webhooks do CVCRM não dispara nada. Foram feitas várias
anotações de teste no lead piloto e nenhuma chamou o webhook, mesmo com
o cadastro correto (URL certa, Ativo, escopo FIUSA 016). Não existe log
de disparo no painel do CVCRM para confirmar se a causa é do lado deles;
o webhook de teste foi apagado depois de confirmar que não adianta
recriar.

**A solução não depende desse gatilho.** O node `Buscar lead CVCRM`
sempre busca o lead inteiro, então a última interação já vinha junto em
qualquer outro gatilho que já funciona (Associar Atendente, mudança de
situação). O ajuste ficou em duas partes:

- `Normalizar evento CVCRM` manda também `interacao_cvcrm_id` (o id da
  última interação), além do texto.
- A função `preencher_fila_sync()` (em `sql/integracao/integracao.sql`)
  compara esse id contra `depara_contato.ultima_interacao_id_cvcrm`. Se
  não for mais novo, tira `interacao_cvcrm` do evento antes de calcular o
  hash. Sem isso, a mesma anotação antiga seria reenviada como nota nova
  no GHL toda vez que outro campo do lead mudasse.

Do lado GHL, a direção contrária (nota do contato virando interação no
CVCRM) usa um gatilho de verdade: o Workflow "Nota adicionada" no GHL,
filtrado pela tag do piloto. O payload real desse gatilho manda o texto
em `note.body` (objeto aninhado), diferente dos quatro nomes tentados
antes de confirmar contra um teste ao vivo.

## Incidente: loop infinito de eco entre nota GHL e interação CVCRM

Descoberto ao vivo em 23/set/2026, pouco depois de validar o piggyback
acima. Uma nota criada de um lado virava interação no outro, essa
interação virava nota de novo no primeiro lado, e assim por diante, sem
parar sozinho. Em cerca de 16 minutos, uma única mensagem de teste ("oi")
virou 4 notas/interações duplicadas, uma a cada ciclo de despacho, até o
node `Gatilho despacho` ser desativado a mão pra estancar.

**Causa:** a detecção de eco genérica (`eh_eco`, em
`v_fila_para_despachar`) compara o hash de TODOS os campos de um evento
entre origem e destino. Isso nunca bate pra esse par de campos
especificamente, porque a forma muda de lado pro lado: `nota_ghl` chega
sozinho, `interacao_cvcrm` chega junto de `corretor_responsavel`,
`empreendimento_interesse` e `origem_campanha`. Um hash calculado sobre
formas diferentes nunca é igual, então o eco nunca era pego.

**Correção:** duas checagens novas em `preencher_fila_sync()`, por TEXTO
em vez de hash. Compara o valor que está chegando contra o `log_sync`
mais recente na direção de destino correspondente (o que a própria
integração acabou de escrever lá). Se for exatamente igual, é eco, o
campo sai de `NEW.campos` antes do hash ser calculado. Validado ao vivo:
uma nota de teste faz uma ida e volta (esperado), e a segunda tentativa
de propagar de volta é corretamente descartada.

**Lição:** a detecção de eco por hash-de-todos-os-campos só funciona
quando o formato do evento é o mesmo nos dois sentidos. Qualquer campo
novo que mude de forma entre origem e destino (como nota/interação, que
vira um objeto solto de um lado e parte de um payload maior do outro)
precisa de detecção de eco própria, não pode confiar na genérica.

## Tarefa CVCRM → GHL: lead.tarefa já vem embutido, não precisa buscar à parte

Implementado em 23/set/2026, com um desvio no meio do caminho que vale
registrar. A primeira versão assumiu que precisava de uma chamada à API
separada pra buscar a tarefa: o gatilho "Nova tarefa" do CVCRM (diferente
de "Nova interação") dispara de verdade e manda `idtarefa` no corpo do
webhook, então pareceu natural usar esse id para buscar a tarefa num
endpoint dedicado (`GET /api/v1/cvdw/leads/tarefas`, tipo CVDW, bulk,
paginado, sem busca por id — precisou filtrar client-side pela data de
hoje).

Isso funcionava, mas trouxe um bug: a tarefa só era buscada quando o
webhook trazia `idtarefa` no corpo, e num teste real outro gatilho
disparou primeiro (sem `idtarefa`), então a tarefa nunca chegou no GHL.
Ao investigar esse bug junto com o Artur, saiu à tona que **`lead.tarefa`
já vem embutido na resposta do `GET` do lead** (o mesmo `Buscar lead
CVCRM` que já roda em todo evento), exatamente como `lead.interacao` --
não tinha necessidade nenhuma do endpoint separado. Reescrito pro mesmo
padrão de carona + dedup por id que a interação já usa
(`ultima_tarefa_id_cvcrm` em `depara_contato`).

**Lição, a mesma do "Nova interação" mas ao contrário desta vez:** antes
de construir uma busca nova pra um dado do CVCRM, primeiro conferir se
ele já não vem de graça no payload que já é buscado em todo evento. Nem
todo campo precisa de gatilho dedicado nem de endpoint dedicado --
"Nova tarefa" disparar de verdade não significava que fosse o caminho
mais simples.

Detalhe menor, mas registrado porque já aconteceu duas vezes: reaplicar
o SQL (`aplicar_integracao.py`) bem no meio de uma sequência de testes
pode deixar 1 evento "de transição" passar sem dedup (a coluna de
controle começa vazia e o primeiro evento pós-fix é tratado como
primeira vez vendo aquele id). Não é bug, é só questão de sequência --
o efeito desaparece a partir do próximo evento.

## Situação: recolocada bidirecional em 24/set/2026

A inversão de 22/set/2026 (ver seção do webhook de Oportunidade) tinha
deixado situação de mão única, GHL→CVCRM. Isso contrariava o objetivo
real do projeto (sincronização bidirecional de verdade), e foi corrigido
em 24/set/2026: agora mudar a situação em qualquer lado reflete no
outro, no mesmo padrão de nota/interação e tarefa (campo `situacao_cvcrm`,
dono cvcrm, destino `situacao_ghl`, marcador especial).

A escrita no GHL não é um Custom Field, é um `PUT /opportunities/:id`
mudando o estágio do pipeline. Isso exigiu resolver duas coisas antes de
poder escrever:

- **O id do estágio no GHL**, via `integracao.depara_situacao_ghl`
  (coluna `pipeline_stage_id_ghl`, capturada em 16-18/set/2026 mas nunca
  exercitada numa escrita real até esse dia).
- **O id da Oportunidade do contato no GHL**, via `GET
  /opportunities/search?contactId=X&pipelineId=Y` (confirmado contra a
  doc oficial), já que o PUT precisa do id da Oportunidade, não do
  contato.

A detecção de eco é por VALOR (idsituacao numérico), mesmo padrão
já usado pro par nota/interação — a genérica por hash não serve aqui
pelo mesmo motivo (forma diferente entre origem e destino). A diferença
importante: situação é idempotente dos dois lados (escrever o mesmo
valor de novo não duplica nada, ao contrário de nota/interação, que são
append-only), então o risco de um eco escapar por 1 ciclo é bem mais
baixo.

**Pegadinha de tipo encontrada ao vivo:** a condição do desvio "Tem
situação pra mudar?" comparava um valor number (`situacao_ghl`) usando
tipo `string` com validação estrita no n8n — deu erro "Wrong type: X is
a number but was expecting a string" antes mesmo de avaliar a condição.
Resolvido envolvendo o valor em `String(...)` na própria expressão.

## Visita CVCRM → Compromisso GHL: três rodadas até funcionar

Implementado em 24/set/2026. Visita é uma Tarefa do CVCRM com
`tipo_interacao='V'` (mesmo formulário da aba "Tarefa", só um tipo
diferente) — o array `lead.tarefa` embutido no GET do lead (usado pra
tarefa genérica) não tem esse campo de tipo, então foi preciso trazer de
volta o endpoint CVDW `/leads/tarefas` especificamente por causa disso
(dessa vez com motivo real, ver seção da Tarefa acima). Sem lag
perceptível — testado ao vivo, tarefa criada e encontrada na mesma
consulta, segundos depois.

Do lado GHL, "Compromissos" é a API de Calendário
(`POST /calendars/events/appointments`), bem diferente de Tasks. O GHL
tem **um calendário pessoal por corretor** (8 vistos em 24/set/2026),
não um único compartilhado — hoje o `calendarId`/`assignedUserId` estão
hardcoded pro corretor de teste (Artur Filho), e falta um de-para
corretor(CVCRM)→(calendarId, assignedUserId) do GHL pra funcionar fora
do piloto.

**A chamada mínima documentada não funcionou.** Precisou de três
rodadas de erro real até funcionar:

1. `400 "The slot you have selected is no longer available"` — o
   calendário é do tipo "Dinâmico" (agenda de disponibilidade real,
   tipo Calendly), não um bloqueio de horário livre. Primeira suspeita
   (desalinhamento de slot de 30min) foi descartada ao vivo, via F12 no
   agendamento manual pela tela do GHL — os slots batiam certinho mesmo
   assim. A causa real só apareceu comparando contra o payload de um
   agendamento manual bem-sucedido (capturado pelo Network do
   navegador): faltava o campo `ignoreFreeSlotValidation: true`
   (`ignoreDateRange`, que já estava sendo mandado, só pula a validação
   de antecedência mínima — são flags diferentes, a doc não deixa isso
   claro).
2. `422 "A team member needs to be selected. assignedUserId is
   missing"` — campo listado como opcional na doc oficial, mas exigido
   de verdade por esse tipo de calendário. O agendamento manual pela
   tela não precisa mandar porque o backend preenche pela sessão
   logada; a API direta, sem sessão, exige explícito.

**Lição, reforça a de hoje mais cedo com nota/tarefa:** quando uma
chamada de API documentada como simples não funciona do jeito que a doc
sugere, o atalho mais rápido é capturar o payload real de uma ação
manual bem-sucedida pelo Network do navegador (F12) e comparar campo a
campo, em vez de ir testando parâmetro por parâmetro às cegas.

## Reconciliação: pausada de propósito

O workflow tem um segundo caminho, independente do webhook: `Gatilho
reconciliacao`, que roda a cada 6h e varre `bronze.leads` (dado real,
trazido pela ingestão CVDW) procurando qualquer lead que a integração ainda
não conhece.

**Esse gatilho está desativado no node `Gatilho reconciliacao`** desde
18/set/2026. O motivo: assim que ligado, ele já começou a puxar leads reais
de produção pra dentro da fila de despacho, mesmo com a integração ainda em
validação. Isso não chegou a escrever dado nenhum de verdade (o GHL hoje só
tem contatos de teste, então toda tentativa de vincular um lead real falha
com 404, de forma segura), mas gerou uma leva de erros na fila e uma
investigação inteira até isso ficar claro.

**Antes de reativar**, decida conscientemente: a integração já está pronta
pra tocar em leads reais dos dois lados? Se sim, reative o node e acompanhe
de perto as primeiras execuções. Se ainda não, deixe como está.

## Verificação rápida

| Situação | Como checar |
|---|---|
| O túnel está de pé de verdade (não só o painel local dizendo isso)? | Acessa a URL pública de um dispositivo fora dessa rede; `ERR_NGROK_3200` = offline |
| Qual é o domínio atual? | `http://127.0.0.1:4040` → Configuration → Tunnels → URL |
| O processo do ngrok está rodando? | Gerenciador de Tarefas → procura `ngrok.exe`; deve ter só **um** processo |
| A tarefa agendada do ngrok rodou sem erro? | Agendador de Tarefas → `ngrok - integracao Pafil` → aba Histórico |
| O n8n está de pé? | `docker ps` dentro de uma janela WSL aberta, ou `http://localhost:5678` no navegador da VM |
| Um webhook específico chegou? | `http://127.0.0.1:4040` → Traffic Inspector, filtra por `/webhook/cvcrm-evento` ou `/webhook/ghl-evento` |
| A fila está processando? | `SELECT id, origem, status, tentativas, erro_msg FROM integracao.fila_sync ORDER BY id DESC LIMIT 10;` |
| Um node HTTP Request parece "certo" mas falha sempre | Confere a aba **Settings** (On Error = "Continue using error output") e as duas saídas (sucesso/erro) conectadas em `Rotular despacho` — recriar um node via colar-JSON perde as duas coisas com frequência |

## Pendência de governança

A conta do ngrok usada aqui precisa ter o email de recuperação vinculado a
algo que a Pafil controle (não uma conta pessoal do analista), pelo mesmo
motivo já levantado sobre domínio próprio: é uma dependência barata de
resolver agora, e cara de descobrir depois que quem criou a conta não está
mais na empresa. Ainda não confirmado quem/qual email criou a conta atual.
