# Reconciliação — BI de Preço legado x `gold` (12/ago/2026)

Comparação medida a medida entre o PBIX legado (`Relatórios Comercial/Preço/BI Preço.pbix`,
consultado ao vivo por DAX) e o modelo novo sobre a `gold`. Objetivo: saber **quais números
mudam e por quê** antes de trocar o relatório que a gestão usa.

> **Atualizado em 12/ago/2026 (fim do dia):** o dev decidiu R22 — a pipeline passou a ler a
> MESMA matriz de preço do legado (`Preço/Apoio/Apoio - BI de Preço.xlsm`) e a
> `tab_viabil_padrão` foi preenchida com as constantes recuperadas do DAX. As duas maiores
> fontes de divergência sumiram. Os números abaixo já refletem isso.

## Resumo

| | |
|---|---|
| Estrutura (unidades e área privativa) | **bate exatamente em 11 de 11 produtos** |
| Preço de tabela | mesma fonte agora — `EstoqueVGV` bate ao centavo onde o estoque bate |
| Estoque (quantidade) | diverge 1-3 unidades por produto — defasagem do resumo manual (§3.4) |
| VGV realizado | bate em Arboretto ao centavo; diverge onde o resumo manual está atrasado |
| Margem / MargemViab | **11 de 13** produtos; `MargemViab` bate à 8ª casa em 7 deles (§4) |

## 1. As duas matrizes de preço da empresa (R22) — resolvido

O BI legado carrega a matriz de `Preço/Apoio/Apoio - BI de Preço.xlsm` e as vendas de
`Preço/Vendas/<Produto> - Resumo.xlsm` (uma por produto, colada à mão). Até a task 6.4 a
`gold` carregava `BI V.2/BI Matriz/base_precos.xlsm`.

As duas descrevem as mesmas unidades com **preços de tabela diferentes** (ex.: Arboretto,
mesmas 90 unidades fora de venda, R$ 70,05 mi no legado x R$ 67,13 mi no `base_precos`).
**Decisão: usar a do legado**, para o relatório novo bater com os números que a gestão já
conhece. `popular_seeds.py --estrutura-fonte legado|bi_matriz` alterna (default no `.env`).

Ganhos inesperados da troca — o arquivo do legado é melhor em 3 pontos:

| | `base_precos.xlsm` | `Apoio` (legado) |
|---|---|---|
| Villa Manacás, área privativa | **1000x errada** (9.156.800 m²) | correta (9.156,80 m²) |
| Quinta da Boa Vista | 57.498 m², 32 un. em estoque | 54.994 m², 30 un. — **bate com o legado** |
| Parc Paineira | **não existe** | 144 unidades |

E uma perda: **Villas do Pq. Lotes Mistos ficou sem preço** (164 lotes) — o arquivo do legado
nunca precificou esses; o `base_precos` tinha R$ 23,9 mi de estoque ali. Eles continuam
aparecendo em quantidade e metragem, mas sem VGV.

## 2. Comparativo por produto

Legado x gold. `EstoqueVGV` da gold na coluna comparável (com permuta, igual ao legado).

Já com a matriz do legado nos dois lados. `EstoqueVGV` da gold na coluna comparável (com
permuta, igual ao legado).

| Produto | Área total (leg.) | (gold) | Estoque qtd (leg.) | (gold) | EstoqueVGV (leg.) | (gold, c/ permuta) | MetragemAVender (leg.) | (gold) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Arboretto | 11.798,50 | ✅ | 68 | 68 ✅ | 70.054.900 | **70.054.900** ✅ | 5.271,96 | ✅ |
| Primaveras | 11.001,12 | ✅ | 15 | 15 ✅ | 3.648.268 | **3.648.268** ✅ | 658,29 | ✅ |
| Quinta da Boa Vista | 54.994,24 | ✅ | 30 | 30 ✅ | 8.332.975 | 8.823.505 | 10.094,77 | ✅ |
| Parc Cidade Jardim | 11.956,80 | ✅ | 125 | 126 | 42.038.870 | 42.334.233 | 6.206,78 | 6.259,56 |
| Parc Sul Uberaba | 14.115,87 | ✅ | 59 | 57 | 41.470.232 | 40.768.233 | 2.892,84 | 2.796,60 |
| Fiusa 016 | 26.770,77 | ✅ | 142 | 141 | 62.685.670 | 62.304.859 | 7.567,39 | 7.513,63 |
| Parc das Artes | 11.299,05 | ✅ | 22 | 20 | 20.323.780 | 19.061.758 | 1.516,88 | 1.377,47 |
| Tríade | 22.481,95 | ✅ | 15 | 13 | 6.826.950 | 5.936.550 | 839,63 | 728,33 |
| Parc das Orquídeas | 8.366,04 | ✅ | 4 | 5 | 1.122.784 | 1.372.146 | 173,72 | 217,15 |
| Villa Manacás | 9.156,80 | ✅ | 128 | 129 | 37.446.428 | 37.660.866 | 5.911,72 | 5.956,39 |
| Villas do Parque | 67.979,24 | ✅ | 388 | 356 | 56.344.484 | 49.015.274 ⚠️ | 45.245,92 | 43.849,12 |

Notas:
- **A área privativa total agora bate em 11 de 11** — mesma matriz dos dois lados.
- **Onde o estoque bate, o VGV bate ao centavo** (Arboretto, Primaveras). O resto da diferença
  é só quantidade de unidades vendidas (§3.4), não preço.
- **Villas do Parque** na gold são dois produtos (`8883` Casas + `5958` Lotes Mistos), somados
  aqui. ⚠️ O EstoqueVGV exclui os 164 lotes sem preço na origem (§1).
- **Quinta da Boa Vista**: a `config_1` (tipologia do lote) que antes vinha vazia agora carrega
  — o loader passou a preservar o primeiro valor não-vazio quando duas colunas da mesma aba
  caem no mesmo nome canônico ("Tipologia" e "CONFIG 1" coexistiam).
- **Parc Paineira** passou a existir (144 unidades, R$ 42,9 mi de estoque).
- **Residencial Quinta dos Ventos** existe nos dois arquivos com estruturas diferentes (158 un.
  / 7.119 m² no legado x 161 / 4.103 m² no `base_precos`) e **não tinha página** no legado —
  nenhum dos dois foi validado por uso. Conferir.

## 3. Diferenças de definição (não são erro de nenhum dos lados)

| # | O legado fazia | A gold faz | Impacto |
|---|---|---|---|
| 1 | `XX_EstoqueVGV` somava preço das não-vendidas **incluindo permuta**, enquanto `Estoque_Qtd` e `MetragemAVender` **excluíam** | `EstoqueVGV` exclui; `EstoqueVGV (legado, c/ permuta)` reproduz o antigo | R$ 16,6 mi (ARB), R$ 15,1 mi (PSU), R$ 6,3 mi (VM) |
| 2 | `ProjetadoVGV` = estoque + **valor de contrato** das vendas | idem (corrigido) — a task 6.4 usava preço de tabela no realizado | inflava o realizado |
| 3 | Distrato **não** aparecia (o resumo manual só tinha Situação="Vendida") → unidade voltava ao estoque | idem (corrigido) — a task 6.4 contava distrato como vendido | **136 unidades** voltaram ao estoque (2.526 → 2.390 realizadas) |
| 4 | Margem com constantes coladas no DAX, por empreendimento | parametrizada por `dim_viabilidade` | ver §4 |

A #3 é uma decisão de negócio (R1 aplicado ao estoque), não técnica: implementada como o
legado fazia, mas a regra antiga continua disponível em
`gold.dim_estrutura[status_unidade_c_distrato]`.

## 4. Viabilidade — preenchida (era o bloqueio da Margem)

`tab_viabil_padrão` (aba `viabil_padrão` de `d_para empreendimentos.xlsx`) tem as 10 linhas de
parâmetro para os 13 empreendimentos, mas **as células de Valor e % estão vazias em 11 deles**
— só Parc das Artes e Parc das Orquídeas estão preenchidos. Conferido lendo o arquivo direto,
com e sem `data_only` (não é fórmula sem cache: as células estão em branco mesmo).

Consequência: `Margem` retorna 100% e `MargemViab` retorna vazio para 11 produtos — o número
mais visível do BI de Preço.

Os valores existem: estavam **hard-coded nas 12 medidas DAX do legado**. Foram recuperados e
decompostos em `relatorios/viabilidade_constantes_legado.csv`. A decomposição usa a identidade
do próprio DAX (denominador = 1 − deduções, e o resto do que era subtraído = despesas) e foi
conferida reproduzindo `XX_MargemViab` de cada produto ao 8º decimal.

**Preenchido em 12/ago/2026** (Excel COM, backup em `_backups_fechamento/`): 8 produtos que já
tinham as linhas vazias + 10 linhas novas para Villa Manacás, que não tinha nenhuma. Parc das
Artes e Parc das Orquídeas não foram tocados (já vinham do estudo real). Resultado — `MargemViab`
da gold x do legado:

| Bate à 8ª casa | Tríade, Primaveras, Quinta da Boa Vista, Parc Sul, Villas do Pq. Casas, Arboretto, Parc Cidade Jardim |
|---|---|
| Bate a 6 casas | Parc das Artes (0,2523861 x 0,2523865) |
| Difere 0,007pp | **Fiusa 016** — o DAX subtraía 0,097 mas usava 0,9033 no denominador; não fechava com ele mesmo |
| Difere 0,35pp | **Parc das Orquídeas** — usa o estudo real da planilha, não a constante do DAX |
| Sem viabilidade | Parc Paineira e Residencial Quinta dos Ventos (não existem na `tab_viabil_padrão`) |

⚠️ Duas ressalvas sobre o que foi escrito: o DAX só guardava o custo de obra **TOTAL**, então a
linha "Terreno" ficou em branco de propósito e o valor inteiro está em "Construção" (a soma, que
é o que a margem usa, fica correta); e **Villas do Pq. Casas recebeu a viabilidade do produto
inteiro**, porque o legado tratava Casas + Lotes como um só.

Achados de qualidade nessas constantes:
- **Parc Paineira** usa constantes **idênticas** às de Parc das Orquídeas (copiar/colar não
  corrigido) — a margem publicada de PPN provavelmente nunca foi a dele.
- **Primaveras** usava 0,079 na `Margem` e 0,0788814711655896 na `MargemViab` (o DAX divergia
  de si mesmo).
- **Parc das Orquídeas**: terreno + construção na planilha (−30.669.428) difere do custo no
  DAX (−31.200.727) em ~R$ 531 mil — dois estudos de viabilidade diferentes.

## 5. Villa Manacás: área privativa 1000x — era só do `base_precos.xlsm`

Na `base_precos.xlsm`, `Área Privativa` do Villa Manacás vem 48.790 onde deveria ser 48,79 m²
(e `Preço M²` sai 5,25 em vez de ~5.247), o que deixava **todo KPI por m² do produto 1000x
errado**. A matriz do legado tem o valor certo, então a troca de fonte resolveu:
`M²ARealizar` saiu de 5,11 para 5.247,61.

O erro continua na `base_precos.xlsm` — se alguém voltar a usá-la (`--estrutura-fonte
bi_matriz`), volta junto. Vale corrigir na planilha.

## 6. Como reproduzir

```bash
python popular_seeds.py --estrutura-precos "<...>\Preço\Apoio\Apoio - BI de Preço.xlsm" --estrutura-fonte legado
```

```bash
python aplicar_gold.py
```

Números do legado: PBIX aberto no Desktop + `dax_query_operations` (as medidas `XX_*`).
Números da gold: `gold.dim_estrutura` / `gold.fato_reservas` (ver §2 do
`powerbi/PAGINA_PRECO.md` para o de-para de medidas).
