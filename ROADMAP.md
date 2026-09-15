# Roadmap: dados do CVCRM até o Power BI

Este é o plano faseado do projeto, ajustado depois do alinhamento com a gestão em
junho de 2026. O objetivo é entregar valor desde já, sem depender de infraestrutura
de terceiros, e sem abrir mão do histórico de dados no médio prazo.

O contexto por trás dessa decisão é o seguinte: a gestão pediu para simplificar o
projeto e não depender de uma VPS pessoal, já que a infraestrutura precisa ser da
Pafil, sem risco de ser cortada por falta de pagamento de alguém. Ao mesmo tempo, a
API do CVDW só devolve o estado atual dos dados, então o histórico (tendências,
comparativos ao longo do tempo) só vai existir se nós mesmos o guardarmos. O
faseamento abaixo concilia esses dois pontos.

---

## Fase 0: demo e entrega rápida, sem infraestrutura (concluída)

- **O quê:** Power BI conectado direto na API do CVDW, através do Power Query, para
  painéis que precisam apenas do estado atual dos dados.
- **Entrega:** `demo/powerbi_bronze_demo.m`, junto com um fluxograma de apresentação.
- **Por quê:** mostra valor imediato, sem exigir nenhuma infraestrutura, e valida o
  interesse da gestão no projeto.
- **Limite consciente:** sem histórico, sem snapshot, e sujeita ao limite de 20
  requisições por minuto da API, o que significa manter poucas tabelas e espaçar bem
  o refresh.

## Fase 1: infraestrutura própria da Pafil, para governança (concluída, numa máquina Windows, não na EC2 originalmente planejada)

- **O quê:** um Postgres self-hosted. O plano original era uma instância AWS EC2 da
  própria empresa (decisão fechada em 7 de agosto de 2026, veja a seção 2 de
  `SKILL.md`), mas a TI nunca a provisionou: em 20 de agosto de 2026, passou
  credenciais de RDP para uma máquina Windows 10 Pro física/local já em uso, e
  confirmou que é esse o destino definitivo (não é uma instância AWS — o teste do
  endereço de metadados da AWS deu timeout nela). Veja `SKILL.md`, seção
  "Atualizações de setembro de 2026", e `infra/RUNBOOK_WINDOWS.md` para o runbook
  real. Um Postgres gerenciado (RDS ou Azure Database) segue como opção em aberto
  para uma produção futura, com o mesmo gatilho de antes: valeria a pena migrar
  quando operar o banco por conta própria pesar mais do que o custo de um serviço
  gerenciado.
- **Por quê:** o destino final não seguiu o plano original, mas o resultado
  prático é o mesmo objetivo desta fase: um Postgres sempre ativo, fora da máquina
  do analista, servindo à reconciliação diária e ao Power BI. O Postgres em si
  continua 100% open source.
- **Resultado alcançado:** o banco está de pé desde 20/ago/2026, com Postgres 16
  rodando como Serviço do Windows, backup diário e a ingestão automatizada por
  Tarefa Agendada (o runbook completo, incluindo os passos já validados na prática,
  está em [`infra/RUNBOOK_WINDOWS.md`](infra/RUNBOOK_WINDOWS.md)).
- **Preparação anterior (12 de agosto de 2026), mantida como histórico:** o
  runbook e os scripts pensados para EC2 Linux estão em
  [`infra/README.md`](infra/README.md) e [`infra/PEDIDO_TI.md`](infra/PEDIDO_TI.md).
  Ficam no repositório caso a empresa migre no futuro para uma instância Linux de
  verdade, mas não refletem o ambiente real hoje.

## Fase 2: bronze e ingestão do histórico (código pronto, aguardando a Fase 1)

- **O quê:** apontar as variáveis `PG_*` para o banco da Pafil, aplicar
  `sql/bronze/bronze.sql` e rodar `ingestao.py --full --criar-tabelas`. Depois
  disso, as cargas seguintes usam `--incremental`, agendadas por cron ou GitHub
  Actions.
- **Por quê:** garante o snapshot diário, que é o histórico que a API não guarda
  sozinha, além de melhorar a performance, evitando bater na API a cada refresh.
- **Status atual:** a descoberta de schema está concluída (19 de 19 objetos),
  e o `bronze.sql` já foi gerado e revisado.

## Fase 3: silver, com limpeza e tipagem forte (pronta, validada localmente)

- **O quê:** `sql/silver/silver.sql`, junto com `aplicar_silver.py`, entrega seis
  views conformadas (`reservas`, `vendas`, `distratos`, `unidades`, `corretores`,
  `imobiliarias`), com tipagem forte para datas e documentos, além das seeds de
  de-para (`sql/silver/seeds.sql` e `popular_seeds.py`). Também cobre leads e
  pré-cadastros, através de `silver.leads`, `silver.precadastros` e
  `silver.leads_conversoes`.
- **Insumo usado:** o catálogo de regras dos PBIX legados em
  [`REGRAS_NEGOCIO.md`](REGRAS_NEGOCIO.md), fruto de uma engenharia reversa
  guardada em `../_bi_ref/`. A silver implementa as regras de limpeza (`ING-*`) e
  materializa os de-paras (`DP-*`) como seeds.
- **O que falta:** confirmar o status da carga completa em produção (feita na
  máquina Windows real, ver Fase 1 acima), e popular os de-paras que ainda dependem
  de planilha do SharePoint (feriados, profissões, etapa de crédito).

## Fase 4: gold e o Power BI definitivo (a gold está pronta; falta montar o .pbix)

- Concluído: o star schema já está implementado em `sql/gold/`, com
  `fato_reservas`, `fato_leads` e `fato_precadastros`, além das dimensões de
  calendário, empreendimento, unidade e corretor. Agregados como rankings, mídia,
  esteira e funis ficam por conta do Power BI, montados em cima da fato.
- Concluído: o kit de consumo está pronto em [`powerbi/`](powerbi/README.md), com
  o arquivo de conexão `.pbids`, o `MEDIDAS_GOLD.dax` (os KPIs já reimplementados)
  e um guia de relacionamentos.
- Concluído: a reconciliação já prova que a pipeline nova reproduz a antiga: os
  distratos de maio de 2026 batem idêntico ao centavo, e o VGV Praticado das
  vendas bate em 98,8% das propostas (os relatórios completos estão em
  `reconciliacao/`).
- Pendente: montar o `.pbix` sobre a gold, um passo manual feito no Power BI
  Desktop, e, já no ambiente de produção, reapontar o `.pbids` e o gateway para a
  máquina Windows de produção com a carga completa.

> **Para reconstruir o warehouse inteiro em um banco novo**, depois que a bronze já
> existir, basta rodar `python aplicar_tudo.py` (que executa silver, gold e seeds
> em sequência). Passando `--xlsm "<Vendas Consolidadas.xlsm>"`, o comando também
> popula o de-para de produtos.

---

## Decisões em aberto

Os itens 1 e 5 desta lista, em versões anteriores deste documento, tratavam a
instância AWS EC2 e a localização do gateway do Power BI como pendências. As duas
estão resolvidas, por um caminho diferente do planejado: a produção roda numa
máquina Windows 10 Pro física/local (não a EC2), e o gateway já está instalado
nela, já que a máquina toda é Windows. Veja `SKILL.md`, seção "Atualizações de
setembro de 2026", para o histórico completo. Os itens que seguem em aberto de
verdade são:

1. Confirmar o status da carga completa em produção e validar os totais (Fase 2).
   Antes da produção existir, a carga local era parcial, com cerca de 4.756 das
   mais de 6.000 reservas reais; o runbook (`infra/RUNBOOK_WINDOWS.md`, seção 3)
   define o critério de aceite, mas vale reconferir o status atual.
2. Reconciliar os totais com os relatórios PBIX existentes, para validar de vez o
   paralelo entre a pipeline nova e a antiga.
3. Definir como os de-paras de planilha (hoje atualizados por um túnel SSH da
   máquina do analista) vão continuar sendo atualizados de forma menos manual. Um
   plano em execução (ver `SKILL.md`) prevê buscar as planilhas via Microsoft
   Graph API, eliminando a dependência do túnel e do OneDrive sincronizado local
   para a maior parte delas (veja `ARCHITECTURE.md`, seção 4, para o detalhe dessa
   fronteira e da exceção dos processos que dependem de Excel COM).
4. Trazer para dentro do repositório o plano em execução desde 15/set/2026
   (migração para dbt-core e Airflow, e a integração entre CVCRM e GoHighLevel),
   hoje registrado só num plano local do Claude Code e num quadro no GitHub
   Projects. Enquanto isso não acontece, este ROADMAP.md descreve apenas a
   primeira etapa do projeto (Fases 0 a 4 acima), já praticamente concluída, não o
   trabalho em andamento.
