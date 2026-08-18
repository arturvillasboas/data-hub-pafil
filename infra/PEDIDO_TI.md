# Pedido de infraestrutura: servidor de banco de dados para o projeto de BI Comercial

> **Como usar este documento:** é um material de apoio para a reunião com a TI
> (etapa 7.1 do roadmap). Traz uma página de contexto, o que está sendo pedido, e
> as três decisões que dependem da TI para avançar. O detalhe técnico de execução
> fica em [`README.md`](README.md), o runbook completo.

## 1. O contexto, em um parágrafo

Hoje, o BI Comercial depende de exportações manuais do CVCRM, coladas em
planilhas, que alimentam três relatórios do Power BI que já divergem entre si. Este
projeto substitui essa cadeia por uma pipeline automática: API do CVCRM, banco
PostgreSQL, Power BI. Todo o software já está pronto e validado: a reconciliação
bate ao centavo com o relatório oficial de distratos, e bate em 98,8% com a
planilha de Vendas Consolidadas. O único bloqueio que resta é a inexistência de um
servidor da empresa onde esse banco possa rodar de forma permanente. Hoje ele roda
na máquina do analista, que desliga no fim do expediente.

Há um ponto aqui que não é uma questão de conveniência, mas de risco real: a API do
CVCRM devolve apenas o estado atual dos dados, nunca o histórico. Cada dia que
passa sem esse servidor é um dia de histórico comercial que não fica guardado em
lugar nenhum, e que não pode ser recuperado depois.

## 2. O que está sendo pedido

Uma instância EC2 na conta AWS da empresa (usando o licenciamento corporativo já
existente, confirmado pela TI em 7 de agosto de 2026), dedicada só a este banco.

| Item | Pedido | Observação |
|---|---|---|
| Tipo de instância | 2 vCPU / 4 GB RAM (equivalente a `t3.medium`) | O volume atual é de cerca de 777 mil registros, não é big data. Pode ser redimensionado depois de medir o uso real. |
| Disco | 50 GB EBS `gp3` | Uma margem folgada; o banco cresce no ritmo das vendas. |
| Sistema operacional | Ubuntu 22.04/24.04 LTS ou Amazon Linux 2023 | Decisão da TI, veja a seção 4. Os dois atendem igualmente bem. |
| Região | `sa-east-1` (São Paulo) | Menor latência para o CVCRM e o Power BI, acessados a partir do Brasil. |
| Disponibilidade | Sempre ativa (always-on) | A carga diária roda de madrugada, e o Power BI consulta o banco durante o expediente. |
| Backup | Snapshot do EBS diário, mais um `pg_dump` diário enviado ao S3 | Retenção sugerida: 7 backups diários e 4 semanais. |
| Nome e tag | Padrão da empresa, com tag de centro de custo do Comercial | A instância deve ser dedicada, sem compartilhar com outros workloads. |

**Uma ordem de grandeza do custo** (a confirmar com a TI, já que o licenciamento
corporativo pode absorver boa parte dele): uma instância `t3.medium` sob demanda em
`sa-east-1`, mais 50 GB em `gp3`, fica na faixa de algumas dezenas de dólares por
mês. Com um Savings Plan de 1 ano, esse valor cai ainda mais. Não há custo de
licença de software: o PostgreSQL é open source.

## 3. Segurança: o banco nunca fica exposto à internet

Este é o ponto mais importante para a TI: o banco vai conter dados pessoais de
clientes e leads, protegidos pela LGPD. Todo o desenho já parte desse cuidado.

- A porta do PostgreSQL (5432) não é liberada para a internet em nenhum momento. O
  Security Group nega tudo por padrão.
- O acesso administrativo acontece sem a porta 22 aberta, através do AWS Systems
  Manager (SSM) Session Manager: a autenticação é feita por IAM, a sessão fica
  auditada no CloudTrail, e não existe chave SSH para gerenciar ou vazar. Uma
  alternativa clássica, com SSH por chave combinado com uma lista de IPs fixos
  liberados, também é aceitável (veja a seção 4).
- O acesso do analista ao banco acontece sempre por túnel (redirecionamento de
  porta via SSM ou SSH), nunca por conexão direta pela internet.
- O acesso do Power BI acontece só a partir do host que roda o gateway, liberado
  por referência ao Security Group de origem, nunca por IP público.
- O login por senha no sistema operacional fica desabilitado, e os patches de
  segurança são aplicados automaticamente (`unattended-upgrades` no Ubuntu, ou
  `dnf-automatic` no Amazon Linux).
- As credenciais da API e a senha do banco ficam em variáveis de ambiente, com
  permissão restrita na própria instância, e nunca no repositório de código.

> Na prática, isso significa que nada neste desenho depende de abrir uma porta de
> banco de dados para fora. Se a TI tiver uma política de VPN corporativa, o
> desenho se adapta sem precisar mudar a arquitetura.

## 4. As decisões que dependem da TI (o que preciso levar da reunião)

**(a) Sistema operacional: Ubuntu LTS ou Amazon Linux 2023?**
Não há uma preferência técnica forte da nossa parte: a escolha deve seguir o padrão
já usado pela casa. O script de provisionamento já cobre os dois casos. Só preciso
saber qual escolher, para fixar isso no runbook.

**(b) Forma de acesso administrativo: SSM Session Manager ou SSH por chave?**
A recomendação é o SSM, por dispensar a porta 22 aberta e ser auditado por IAM.
Isso exige que a instância tenha um IAM Instance Profile com a policy gerenciada
`AmazonSSMManagedInstanceCore`, que é a única exigência de IAM deste projeto.

**(c) Onde fica o host Windows para o gateway do Power BI.** Este é o ponto mais
fácil de passar despercebido: o On-premises Data Gateway, da Microsoft, só roda em
Windows. Se a EC2 for Linux (o recomendado para o Postgres), o gateway precisa de
outro lugar para morar. Há três saídas possíveis, em ordem de preferência:

1. Instalar o gateway em uma máquina Windows já existente na empresa, sempre
   ativa, que consiga alcançar a EC2 pela rede privada. Custo zero.
2. Subir uma segunda instância EC2 Windows, pequena, só para o gateway. Isso tem
   um custo adicional.
3. Adiar essa decisão: sem o gateway, o Power BI Desktop continua funcionando
   normalmente (com atualização manual feita pelo analista, via túnel). Só a
   atualização agendada, dentro do Power BI Service, fica bloqueada enquanto isso.

   Essa escolha não bloqueia as etapas 7.2 a 7.4. Já é possível subir o banco e
   fazer a carga de dados sem resolver essa questão do gateway antes.

## 5. Divisão de responsabilidades

| Quem | O que faz |
|---|---|
| TI | Cria a instância EC2, o Security Group e o IAM Instance Profile para o SSM; define o sistema operacional e a forma de acesso; define a política de snapshot e backup; indica o host que vai rodar o gateway (item 4c) |
| Analista (eu) | Instala e configura o PostgreSQL, faz o hardening do serviço, cria o banco e os usuários, roda a carga histórica completa, agenda a atualização diária, conecta o Power BI, e documenta todo o processo |

Tudo do lado do analista já está escrito e testado: é só execução, com uma
estimativa de cerca de 2 dias depois que a instância existir (as etapas 7.2 a 7.5
do roadmap).

## 6. O que acontece depois da aprovação

| Etapa | O que é feito | Tempo estimado |
|---|---|---|
| 7.2 | Instalar e proteger o banco no servidor | cerca de 2 dias |
| 7.3 | Rodar a carga histórica completa de produção | cerca de 1 dia |
| 7.4 | Reativar a atualização diária automática | cerca de meio dia |
| 7.5 | Estabelecer a conexão segura entre o Power BI e o servidor | cerca de 1 dia |
