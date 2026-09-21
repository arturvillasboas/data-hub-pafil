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
