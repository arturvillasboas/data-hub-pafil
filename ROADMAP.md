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

## Fase 1: infraestrutura própria da Pafil, para governança (a instância EC2 ainda não foi provisionada)

- **O quê:** um Postgres self-hosted, rodando em uma instância AWS EC2 da própria
  empresa. Essa é uma decisão fechada em 7 de agosto de 2026 (a TI confirmou um
  licenciamento AWS corporativo já existente, que cobre a EC2 sem custo adicional
  de infraestrutura; veja a seção 2 de `SKILL.md`, que prevalece em caso de
  conflito). Essa decisão substitui a opção anterior de VPS na DigitalOcean. Um
  Postgres gerenciado (RDS ou Azure Database) fica como opção em aberto para uma
  produção futura, com o seguinte gatilho: valeria a pena migrar quando operar o
  banco por conta própria (backup, patch, alta disponibilidade) pesar mais do que o
  custo de um serviço gerenciado. A decisão é reversível: bastaria reapontar a
  string de conexão, reaplicar `bronze.sql` e rodar `--full` de novo.
- **Por quê:** aproveita uma licença AWS que a empresa já paga, sem fricção de
  procurement; um banco sempre ativo serve à reconciliação diária melhor do que um
  Docker rodando localmente; e o Postgres em si continua 100% open source, só o
  sistema operacional e o servidor passam a ser da AWS.
- **Resultado esperado:** preencher as variáveis `PG_*` no `.env` com o host e a
  porta da instância EC2 (o acesso é sempre por túnel, via SSM ou SSH; a porta do
  Postgres nunca fica exposta à internet pública).
- **Preparação já concluída (12 de agosto de 2026):** o runbook executável e os
  scripts de provisionamento estão prontos em [`infra/`](infra/README.md), cobrindo
  a instalação do Postgres 16 (tanto em Ubuntu quanto em Amazon Linux 2023), o
  tuning do banco, a configuração do `pg_hba` restrita a acesso local, as roles
  `pafil_app` e `pafil_bi`, o backup diário, o systemd timer da ingestão e os
  grants necessários para o Power BI. O pedido formal para levar à TI está em
  [`infra/PEDIDO_TI.md`](infra/PEDIDO_TI.md). Falta apenas a instância existir de
  fato.

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
- **O que falta:** rodar contra a carga completa, que só vai existir depois da Fase
  1 na EC2 (hoje a validação usa apenas a carga local parcial), e popular os
  de-paras que ainda dependem de planilha do SharePoint (feriados, profissões,
  etapa de crédito).

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
  instância EC2 com a carga completa.

> **Para reconstruir o warehouse inteiro em um banco novo**, depois que a bronze já
> existir, basta rodar `python aplicar_tudo.py` (que executa silver, gold e seeds
> em sequência). Passando `--xlsm "<Vendas Consolidadas.xlsm>"`, o comando também
> popula o de-para de produtos.

---

## Decisões em aberto

1. Provisionar a instância AWS EC2 da empresa e instalar o Postgres (Fase 1). O
   runbook já está pronto em [`infra/README.md`](infra/README.md), e o pedido está
   em [`infra/PEDIDO_TI.md`](infra/PEDIDO_TI.md). O que falta confirmar com a TI é
   o sistema operacional (Ubuntu LTS ou Amazon Linux 2023) e a forma de acesso
   (SSM ou SSH por chave).
2. Rodar `ingestao.py --full --criar-tabelas` na EC2 e validar os primeiros dados
   (Fase 2). Hoje a carga local é parcial, com cerca de 4.756 das mais de 6.000
   reservas reais.
3. Reconciliar os totais com os relatórios PBIX existentes, para validar de vez o
   paralelo entre a pipeline nova e a antiga.
4. Definir como os de-paras de planilha (hoje sincronizados via OneDrive e
   SharePoint) vão continuar sendo atualizados depois que a fonte deixar de ser
   uma máquina local (veja `ARCHITECTURE.md` para mais detalhes sobre essa
   fronteira).
5. Decidir onde vai morar o On-premises Data Gateway. Ele só roda em Windows,
   então não cabe dentro de uma EC2 Linux, e o desenho anterior, que previa o
   gateway "na própria VPS", não se sustenta mais. Há três opções: usar um host
   Windows sempre ativo que a empresa já tenha (sem custo adicional), subir uma
   segunda instância EC2 Windows só para isso (com custo adicional), ou adiar essa
   decisão (o Power BI Desktop continua funcionando normalmente por túnel; só a
   atualização agendada no Power BI Service fica bloqueada enquanto isso). Essa
   decisão não bloqueia as etapas 7.2 a 7.4.
