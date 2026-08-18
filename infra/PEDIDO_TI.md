# Pedido de infraestrutura — Servidor de banco de dados (Projeto BI Comercial)

> **Uso:** documento de apoio para a reunião com a TI (etapa 7.1 do roadmap).
> Uma página de contexto + o que está sendo pedido + as 3 decisões que dependem da TI.
> Detalhe técnico de execução fica em [`README.md`](README.md) (runbook).

## 1. Contexto em um parágrafo

O BI Comercial hoje depende de exportações manuais do CVCRM coladas em planilhas, que
alimentam 3 relatórios do Power BI que já divergem entre si. O projeto substitui essa
cadeia por uma pipeline automática: **API do CVCRM → banco PostgreSQL → Power BI**. Todo o
software já está pronto e validado (a reconciliação bate ao centavo com o relatório
oficial de distratos e 98,8% com a planilha de Vendas Consolidadas). **O único bloqueio
restante é não existir um servidor da empresa onde o banco possa rodar de forma
permanente** — hoje ele roda na máquina do analista, que desliga no fim do expediente.

Há um ponto que não é de conveniência, e sim de risco: **a API do CVCRM devolve apenas o
estado atual dos dados, não o histórico.** Todo dia que passa sem o servidor é um dia de
histórico comercial que não é guardado por ninguém e não pode ser recuperado depois.

## 2. O que está sendo pedido

Uma instância **EC2 na conta AWS da empresa** (licenciamento corporativo já existente,
confirmado pela TI em 07/ago/2026), dedicada a este banco.

| Item | Pedido | Observação |
|---|---|---|
| Tipo de instância | 2 vCPU / 4 GB RAM (equivalente a `t3.medium`) | Volume atual ~777 mil registros — não é big data. Redimensionável depois de medir. |
| Disco | 50 GB EBS `gp3` | Sobra folgada; o banco cresce ~ao ritmo das vendas. |
| Sistema operacional | Ubuntu 22.04/24.04 LTS **ou** Amazon Linux 2023 | **Decisão da TI** — ver seção 4. Ambos atendem. |
| Região | `sa-east-1` (São Paulo) | Menor latência para CVCRM e Power BI a partir do Brasil. |
| Disponibilidade | Always-on | A carga diária roda de madrugada; o Power BI consulta durante o expediente. |
| Backup | Snapshot EBS diário + `pg_dump` diário para S3 | Retenção sugerida: 7 diários + 4 semanais. |
| Nome/tag | Padrão da empresa, tag de centro de custo Comercial | Instância **dedicada** — não compartilhar com outros workloads. |

**Ordem de grandeza de custo** (a confirmar com a TI, já que o licenciamento corporativo
pode absorver): instância `t3.medium` on-demand em `sa-east-1` + 50 GB `gp3` ficam na
casa de algumas dezenas de dólares/mês; com *Savings Plan* de 1 ano, menos. Não há custo
de licença de software — PostgreSQL é open source.

## 3. Segurança — o banco nunca fica exposto à internet

Este ponto é o mais importante para a TI: o banco vai conter **dados pessoais de clientes
e leads (LGPD)**. O desenho já parte disso.

- **A porta do PostgreSQL (5432) não é liberada para a internet em nenhum momento.** O
  Security Group nega tudo por padrão.
- Acesso administrativo **sem porta 22 aberta**, via **AWS Systems Manager (SSM) Session
  Manager** — autenticação por IAM, sessão auditada no CloudTrail, sem chave SSH para
  gerenciar ou vazar. (Alternativa clássica em SSH por chave + allowlist de IP fixo
  também é aceitável — ver seção 4.)
- Acesso ao banco pelo analista: **túnel** (port forwarding do SSM ou SSH), nunca conexão
  direta pela internet.
- Acesso do Power BI: apenas a partir do host do gateway, liberado por **Security Group
  referenciando o SG de origem** — não por IP público.
- Login por senha no SO desabilitado; patches de segurança automáticos habilitados
  (`unattended-upgrades` / `dnf-automatic`).
- Credenciais da API e senha do banco ficam em variáveis de ambiente com permissão
  restrita na instância — nunca no repositório de código.

> Consequência prática: **nada neste desenho depende de abrir uma porta de banco de dados
> para fora.** Se a TI tiver política de VPN corporativa, o desenho se adapta sem mudança
> de arquitetura.

## 4. Decisões que dependem da TI (o que preciso levar da reunião)

**(a) Sistema operacional:** Ubuntu LTS ou Amazon Linux 2023?
Não há preferência técnica forte — a escolha é do padrão da casa. O script de
provisionamento cobre os dois. *Preciso apenas saber qual, para fixar o runbook.*

**(b) Forma de acesso administrativo:** SSM Session Manager ou SSH por chave?
SSM é a recomendação (sem porta 22, auditado por IAM). Requer que a instância tenha um
**IAM Instance Profile** com a policy gerenciada `AmazonSSMManagedInstanceCore` — é a
única exigência de IAM do projeto.

**(c) Host Windows para o gateway do Power BI** — *o ponto mais fácil de passar batido:*
o **On-premises Data Gateway da Microsoft só roda em Windows.** Se a EC2 for Linux (o
recomendado para o Postgres), o gateway precisa de outro lugar para morar. Três saídas,
em ordem de preferência:
   1. Instalar o gateway em uma **máquina Windows always-on que a empresa já tenha** e que
      alcance a EC2 pela rede privada — custo zero.
   2. Subir uma **segunda EC2 Windows pequena** só para o gateway — custo adicional.
   3. **Adiar:** sem gateway, o Power BI Desktop continua funcionando (atualização manual
      pelo analista, via túnel). Só a *atualização agendada no Power BI Service* fica
      bloqueada.

   *Não é bloqueio para as etapas 7.2–7.4* — dá para subir o banco e a carga sem resolver
   isso. Mas define se o painel atualiza sozinho ou no botão.

## 5. Divisão de responsabilidades

| Quem | O quê |
|---|---|
| **TI** | Criar a instância EC2 + Security Group + IAM Instance Profile (SSM); definir SO e forma de acesso; política de snapshot/backup; indicar o host do gateway (item 4c) |
| **Analista (eu)** | Instalar e configurar o PostgreSQL, hardening do serviço, criar o banco e os usuários, rodar a carga histórica completa, agendar a atualização diária, conectar o Power BI, documentar tudo |

Tudo do lado do analista já está escrito e testado — é execução, estimada em **~2 dias**
depois que a instância existir (etapas 7.2 a 7.5 do roadmap).

## 6. O que acontece depois da aprovação

| Etapa | O quê | Tempo |
|---|---|---|
| 7.2 | Instalar e proteger o banco no servidor | ~2 dias |
| 7.3 | Rodar a carga histórica completa de produção | ~1 dia |
| 7.4 | Reativar a atualização diária automática | ~0,5 dia |
| 7.5 | Conexão segura Power BI ↔ servidor | ~1 dia |
