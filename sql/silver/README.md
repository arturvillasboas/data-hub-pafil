# Camada silver

A silver conforma os dados a partir da bronze. Diferente do BI legado, que
precisava limpar CSVs manuais dentro do Power Query, a bronze aqui já chega da
API com chaves e tipos definidos. Por isso, a silver se concentra em conformar
nomes, aplicar tipagem forte e calcular flags de regras de negócio, em vez de
consertar dado sujo.

Ela foi mapeada a partir de [`REGRAS_NEGOCIO.md`](../../REGRAS_NEGOCIO.md),
seguindo os códigos `ING-*`, `DP-*`, `KPI-*` e `R*` usados naquele catálogo.

## O que tem nesta pasta

| Arquivo | Conteúdo |
|---|---|
| [`silver.sql`](silver.sql) | O schema `silver`, com funções de tipagem tolerante e 6 views de conformação |
| [`seeds.sql`](seeds.sql) | As tabelas de-para (DP-01 a DP-12): a estrutura e a proveniência de cada uma (os dados em si são carregados à parte) |
| [`mdnet.sql`](mdnet.sql) | A view `silver.mdnet_chamadas`, do CDR de telefonia da MDnet (PABX, URA e ramais). Aplica-se sozinha com `python aplicar_silver.py --so-mdnet` |

Para aplicar: `python aplicar_silver.py`, rodado na raiz do projeto. É
idempotente, e valida contando as linhas de cada view.

## As views (declarativas, construídas sobre a bronze)

| View | Grão | Destaques |
|---|---|---|
| `silver.reservas` | 1 reserva | traz as flags `eh_venda`, `eh_venda_ou_distrato` e `eh_distrato` (que expõem a regra R1); converte datas de texto para `timestamptz`; calcula chaves de tempo como `ano_mes_venda` |
| `silver.vendas` | 1 venda (endpoint `/vendas`) | um caminho alternativo às reservas vendidas, já com `preco_m2` calculado |
| `silver.distratos` | 1 distrato | é a fonte única de distratos, substituindo as três fontes que existiam no legado (regra R2) |
| `silver.unidades` | 1 unidade | traz `preco_m2` e `eh_vendida`, a base para estoque e VSO |
| `silver.corretores` | 1 corretor | converte `creci` para texto |
| `silver.imobiliarias` | 1 imobiliária | converte `cnpj` para texto (regra R8) |

> **Por que são views, e não tabelas:** são declarativas, reversíveis, sempre
> refletem o dado mais atual, e não exigem nenhum passo extra de refresh.
> Materializar como `TABLE` ou `MATERIALIZED VIEW` só faria sentido se a
> performance algum dia exigir isso.

## Telefonia da MDnet (`silver.mdnet_chamadas`)

A fonte não tem API: o painel web da MDnet (DDA Telecom) só exporta um CSV, e o
`ingerir_mdnet.py` faz login e baixa esse CSV dia a dia. Grão: uma linha por
ligação. O que vale saber antes de usar:

- **O CSV sem filtro mostra uma perna por ligação e esconde as outras.** As pernas
  vêm do relatório filtrado por direção (`ingerir_mdnet_pernas.py`, tabela
  `bronze.mdnet_cdr_pernas`). Os valores do filtro são `inbound`, `outbound` e
  `internal`.
- **`direcao_cartao` e `estado_cartao` reproduzem os cartões do painel web.** O
  critério é por prioridade entre as pernas: com perna de entrada é Entrada, senão
  com perna de saída é Saída, senão Interna. Em 05/out/2026 fechou com o painel nas
  três direções (21.137, 1.062 e 4.701) e nos estados de Entrada e Interna.
- **Divergência conhecida:** em Saída o painel mostra 251 atendidas e a perna de
  saída diz 512. A maioria das 512 tem conversa longa, então o painel é o
  divergente. Para decisão, use `atendida` (estado do painel OU tempo falado > 0).
- `direcao` é a nossa leitura da perna que o CSV mostra, com três correções (perna
  de tronco, ligação encaminhada para fora e códigos de recurso como a captura
  `*8`). `e_chamada_real` tira os recursos e as pernas de transferência.
- `rota_entrada` é o prefixo do número chamado (88810, 88830015, 88860). Não foi
  confirmado com a MDnet o que significa, então não tem rótulo.
- O CSV não traz a opção escolhida na URA nem a fila. O que dá para medir é tempo
  até atender, quem atendeu, quem desligou e se a chamada foi transferida.
- A carga **preserva** a primeira versão de cada linha (`--atualizar` sobrescreve):
  o painel oscila em ~0,5% das ligações, devolvendo ao acaso uma das pernas.

Conferência: `python conferir_mdnet.py --de 2026-01-01 --ate 2026-10-05 --silver`.

## Validação (carga local, 28 de junho de 2026)

Esta validação foi feita contra a bronze já carregada localmente (na porta 5433):

- Os volumes encontrados foram: 4.756 em `silver.reservas`, 2.680 em `vendas`,
  741 em `distratos`, 5.773 em `unidades`, 1.087 em `corretores` e 633 em
  `imobiliarias`.
- **Consistência cruzada confirmada:** o total de `/vendas` (2.680) bate com o
  total de reservas com `situacao='Vendida'` (também 2.680), e o total de
  `/distratos` (741) bate com o total de reservas com `situacao='Distrato'`
  (também 741). Isso resolve a regra R7.
- **Os KPIs já ficam prontos para reconciliação:** VGV Bruto de
  R$ 715.397.140,32, VGV Distrato de R$ 173.196.940,07, resultando em um VGV
  Líquido de R$ 542.200.200,25.

## Decisões e regras já aplicadas

- As regras ING-01 a ING-03 (limpeza de lixo de CSV, como extrair o número da
  reserva de dentro de aspas) não foram portadas para cá: eram consertos de
  defeitos do export manual antigo, e a API já entrega os dados estruturados
  corretamente. Um filtro defensivo só seria adicionado se algum dia aparecesse
  sujeira parecida vinda da API.
- A regra ING-04 ("Ajuste Castro") virou a seed
  `silver.dpara_responsavel_imobiliaria`, em vez de ficar fixa no código. A
  aplicação efetiva dessa regra dentro de uma view fica para a gold, quando
  existir uma coluna de responsável lá.
- A regra R1 (as duas definições de "venda") está com as duas colunas expostas
  na view. Qual delas é a autoritativa é uma decisão que se resolve durante a
  reconciliação, não aqui.
- Na tipagem forte, identificadores como `creci` e `cnpj` viram texto (`TEXT`),
  e datas que chegam como texto passam pela função
  `silver.tentar_timestamptz`, que devolve `NULL` em vez de quebrar a
  ingestão quando o formato é inesperado.

## Próximos passos

1. Popular os seeds `dpara_*` que ainda faltam, extraindo das planilhas do
   SharePoint ou decodificando o JSON guardado em `_bi_ref`.
2. Construir a gold: o star schema descrito em
   [`MODELO_SEMANTICO.md`](../../MODELO_SEMANTICO.md), com `fato_reservas`
   cruzando reservas e distratos, e as dimensões vindas de `unidades`,
   `corretores`, `imobiliarias`, além de uma `dim_calendario`.
3. Fazer a reconciliação: comparar os KPIs autoritativos (VGV Bruto, VGV
   Líquido, QTD, Taxa de Distrato), mês a mês e empreendimento a
   empreendimento, contra os números dos PBIX legados.
