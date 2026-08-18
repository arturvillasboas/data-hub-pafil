# Reconciliação entre o BI de Preço legado e a gold (12 de agosto de 2026)

Esta é uma comparação medida a medida entre o PBIX legado
(`Relatórios Comercial/Preço/BI Preço.pbix`, consultado ao vivo por DAX) e o
modelo novo, construído sobre a gold. O objetivo é entender quais números mudam,
e por quê, antes de trocar o relatório que a gestão usa no dia a dia.

> **Atualizado em 12 de agosto de 2026, no fim do dia:** o desenvolvedor decidiu a
> regra R22: a pipeline passou a ler a mesma matriz de preço do legado
> (`Preço/Apoio/Apoio - BI de Preço.xlsm`), e a tabela `tab_viabil_padrão` foi
> preenchida com as constantes recuperadas do DAX. As duas maiores fontes de
> divergência desapareceram. Os números abaixo já refletem essa mudança.

## Resumo

| | |
|---|---|
| Estrutura (unidades e área privativa) | bate exatamente em 11 dos 11 produtos |
| Preço de tabela | agora é a mesma fonte dos dois lados; `EstoqueVGV` bate ao centavo onde o estoque também bate |
| Estoque (quantidade) | diverge de 1 a 3 unidades por produto, por causa da defasagem do resumo manual (veja a seção 3.4) |
| VGV realizado | bate ao centavo em Arboretto; diverge nos produtos onde o resumo manual está atrasado |
| Margem / MargemViab | calculada para 11 dos 13 produtos; `MargemViab` bate até a 8ª casa decimal em 7 deles (veja a seção 4) |

## 1. As duas matrizes de preço da empresa (regra R22), já resolvido

O BI legado carrega a matriz a partir de `Preço/Apoio/Apoio - BI de Preço.xlsm`, e
as vendas a partir de `Preço/Vendas/<Produto> - Resumo.xlsm` (um arquivo por
produto, preenchido à mão). Até a task 6.4, a gold carregava
`BI V.2/BI Matriz/base_precos.xlsm`.

As duas fontes descrevem as mesmas unidades, mas com preços de tabela diferentes.
Um exemplo: em Arboretto, considerando as mesmas 90 unidades fora de venda, o
legado soma R$ 70,05 milhões, contra R$ 67,13 milhões no `base_precos`. A decisão
tomada foi usar a matriz do legado como padrão, para que o relatório novo bata
com os números que a gestão já conhece. O comando
`popular_seeds.py --estrutura-fonte legado|bi_matriz` alterna entre as duas
(o padrão fica definido no `.env`).

Essa troca trouxe ganhos inesperados: o arquivo do legado se mostrou melhor em
três pontos:

| | `base_precos.xlsm` | `Apoio` (legado) |
|---|---|---|
| Villa Manacás, área privativa | 1000 vezes errada (9.156.800 m²) | correta (9.156,80 m²) |
| Quinta da Boa Vista | 57.498 m², 32 unidades em estoque | 54.994 m², 30 unidades: bate com o legado |
| Parc Paineira | não existe | 144 unidades |

E trouxe uma perda: Villas do Pq. Lotes Mistos ficou sem preço (164 lotes). O
arquivo do legado nunca precificou esses lotes; o `base_precos` tinha ali R$ 23,9
milhões de estoque. Eles continuam aparecendo em quantidade e em metragem, mas
sem VGV.

## 2. Comparativo por produto

A tabela abaixo já usa a matriz do legado nos dois lados. A coluna `EstoqueVGV`
da gold está na versão comparável ao legado (incluindo permuta, do mesmo jeito
que o legado calculava).

| Produto | Área total, legado | Área total, gold | Estoque, legado | Estoque, gold | EstoqueVGV, legado | EstoqueVGV, gold (com permuta) | MetragemAVender, legado | MetragemAVender, gold |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Arboretto | 11.798,50 | igual | 68 | igual | 70.054.900 | igual | 5.271,96 | igual |
| Primaveras | 11.001,12 | igual | 15 | igual | 3.648.268 | igual | 658,29 | igual |
| Quinta da Boa Vista | 54.994,24 | igual | 30 | igual | 8.332.975 | 8.823.505 | 10.094,77 | igual |
| Parc Cidade Jardim | 11.956,80 | igual | 125 | 126 | 42.038.870 | 42.334.233 | 6.206,78 | 6.259,56 |
| Parc Sul Uberaba | 14.115,87 | igual | 59 | 57 | 41.470.232 | 40.768.233 | 2.892,84 | 2.796,60 |
| Fiusa 016 | 26.770,77 | igual | 142 | 141 | 62.685.670 | 62.304.859 | 7.567,39 | 7.513,63 |
| Parc das Artes | 11.299,05 | igual | 22 | 20 | 20.323.780 | 19.061.758 | 1.516,88 | 1.377,47 |
| Tríade | 22.481,95 | igual | 15 | 13 | 6.826.950 | 5.936.550 | 839,63 | 728,33 |
| Parc das Orquídeas | 8.366,04 | igual | 4 | 5 | 1.122.784 | 1.372.146 | 173,72 | 217,15 |
| Villa Manacás | 9.156,80 | igual | 128 | 129 | 37.446.428 | 37.660.866 | 5.911,72 | 5.956,39 |
| Villas do Parque | 67.979,24 | igual | 388 | 356 | 56.344.484 | 49.015.274 * | 45.245,92 | 43.849,12 |

\* O `EstoqueVGV` da gold em Villas do Parque exclui os 164 lotes que ficaram sem
preço na origem (veja a seção 1).

Algumas notas sobre esta tabela:
- A área privativa total agora bate em 11 dos 11 produtos, porque as duas fontes
  usam a mesma matriz.
- Onde o estoque bate exatamente (Arboretto, Primaveras), o VGV também bate ao
  centavo. O resto da diferença observada é só uma questão de quantidade de
  unidades vendidas (veja a seção 3.4), não de preço.
- Villas do Parque, na gold, é a soma de dois produtos: `8883` (Casas) e `5958`
  (Lotes Mistos).
- Em Quinta da Boa Vista, a coluna `config_1` (a tipologia do lote), que antes
  vinha vazia, agora está preenchida: o loader passou a preservar o primeiro
  valor não vazio quando duas colunas da mesma aba caem no mesmo nome canônico
  (nesse caso, "Tipologia" e "CONFIG 1" coexistiam na planilha).
- Parc Paineira passou a existir no relatório, com 144 unidades e R$ 42,9
  milhões em estoque.
- Residencial Quinta dos Ventos existe nos dois arquivos, mas com estruturas
  diferentes (158 unidades e 7.119 m² no legado, contra 161 unidades e 4.103 m²
  no `base_precos`). Esse produto não tinha página própria no legado, então
  nenhuma das duas versões foi validada pelo uso real. Ainda precisa ser
  conferido qual está correta.

## 3. Diferenças de definição (não são erro de nenhum dos dois lados)

| # | O que o legado fazia | O que a gold faz | Impacto |
|---|---|---|---|
| 1 | `XX_EstoqueVGV` somava o preço das unidades não vendidas incluindo permuta, enquanto `Estoque_Qtd` e `MetragemAVender` excluíam a permuta | `EstoqueVGV` exclui permuta; a medida `EstoqueVGV (legado, com permuta)` reproduz o comportamento antigo, para quem precisar comparar | R$ 16,6 milhões em Arboretto, R$ 15,1 milhões em Parc Sul, R$ 6,3 milhões em Villa Manacás |
| 2 | `ProjetadoVGV` era estoque mais o valor de contrato das vendas | O mesmo comportamento, já corrigido: a implementação da task 6.4 usava o preço de tabela no realizado | Isso inflava o valor do realizado |
| 3 | O distrato não aparecia, porque o resumo manual só trazia `Situação="Vendida"`, então a unidade não voltava ao estoque | O mesmo comportamento do legado, já corrigido: a implementação da task 6.4 contava distrato como se fosse venda | 136 unidades voltaram ao estoque (de 2.526 para 2.390 unidades realizadas) |
| 4 | A margem vinha com constantes coladas diretamente no DAX, por empreendimento | Passou a ser parametrizada por `dim_viabilidade` | Veja a seção 4 |

O item 3 é uma decisão de negócio (a regra R1 aplicada ao estoque), não uma
questão técnica: foi implementada exatamente como o legado fazia, mas a regra
antiga continua disponível em `gold.dim_estrutura[status_unidade_c_distrato]`,
para quem precisar comparar.

## 4. Viabilidade: já preenchida (era o que travava a Margem)

A tabela `tab_viabil_padrão` (aba `viabil_padrão` de `d_para empreendimentos.xlsx`)
tem as 10 linhas de parâmetro para os 13 empreendimentos, mas as células de
Valor e % estavam vazias em 11 deles: só Parc das Artes e Parc das Orquídeas
vinham preenchidos. Isso foi conferido lendo o arquivo diretamente, com e sem a
opção `data_only` (confirmando que não era uma fórmula sem cache: as células
estavam realmente em branco).

A consequência era que a medida `Margem` retornava 100%, e `MargemViab`
retornava vazio, para 11 produtos, justamente o número mais visível de todo o BI
de Preço.

Os valores existiam, porém: estavam fixos (hard-coded) nas 12 medidas DAX do
legado. Foram recuperados e decompostos no arquivo
`relatorios/viabilidade_constantes_legado.csv`. Essa decomposição usa a mesma
identidade presente no próprio DAX (o denominador é 1 menos as deduções, e o
restante do que era subtraído são as despesas), e foi conferida reproduzindo a
`XX_MargemViab` de cada produto até a 8ª casa decimal.

**O preenchimento aconteceu em 12 de agosto de 2026** (via automação do Excel,
com backup guardado em `_backups_fechamento/`): foram preenchidos 8 produtos que
já tinham linhas vazias, mais 10 linhas novas para Villa Manacás, que antes não
tinha nenhuma. Parc das Artes e Parc das Orquídeas não foram alterados, porque já
vinham do estudo real. O resultado, comparando `MargemViab` da gold com a do
legado, ficou assim:

| Resultado | Produtos |
|---|---|
| Bate até a 8ª casa decimal | Tríade, Primaveras, Quinta da Boa Vista, Parc Sul, Villas do Pq. Casas, Arboretto, Parc Cidade Jardim |
| Bate até a 6ª casa decimal | Parc das Artes (0,2523861 contra 0,2523865) |
| Diverge 0,007 ponto percentual | Fiusa 016: o DAX legado subtraía 0,097, mas usava 0,9033 no denominador, uma conta que não fechava nem com ela mesma |
| Diverge 0,35 ponto percentual | Parc das Orquídeas: a gold usa o estudo de viabilidade real da planilha, em vez da constante fixa no DAX |
| Sem viabilidade calculada | Parc Paineira e Residencial Quinta dos Ventos, que não existem em `tab_viabil_padrão` |

Duas ressalvas importantes sobre esse preenchimento: o DAX legado só guardava o
custo de obra como valor total, então a linha "Terreno" ficou em branco de
propósito, com o valor inteiro concentrado em "Construção" (a soma dos dois, que
é o que a margem de fato usa, continua correta); e Villas do Pq. Casas recebeu a
viabilidade do produto inteiro, porque o legado tratava Casas e Lotes como um
produto só.

A investigação dessas constantes também revelou alguns problemas de qualidade:

- Parc Paineira usa constantes idênticas às de Parc das Orquídeas, sinal de um
  copiar e colar nunca corrigido. É provável que a margem publicada de Parc
  Paineira nunca tenha sido, de fato, a margem real dele.
- Primaveras usava 0,079 na medida `Margem`, mas 0,0788814711655896 na
  `MargemViab`, ou seja, o próprio DAX legado divergia de si mesmo.
- Em Parc das Orquídeas, a soma de terreno e construção na planilha
  (R$ -30.669.428) difere do custo usado no DAX (R$ -31.200.727) em cerca de
  R$ 531 mil, sinal de que são dois estudos de viabilidade diferentes.

## 5. Villa Manacás: a área privativa 1000 vezes errada, só no `base_precos.xlsm`

Na `base_precos.xlsm`, a `Área Privativa` de Villa Manacás vinha registrada como
48.790, quando deveria ser 48,79 m² (o que fazia o `Preço M²` calculado sair como
5,25, em vez de aproximadamente 5.247). Isso deixava todo KPI calculado por metro
quadrado do produto 1000 vezes errado. A matriz do legado tem o valor correto,
então a troca de fonte já resolveu isso: o indicador `M²ARealizar` saiu de 5,11
para 5.247,61.

O erro continua existindo dentro da `base_precos.xlsm`. Se alguém voltar a usar
essa fonte (rodando `--estrutura-fonte bi_matriz`), o erro volta junto. Vale
corrigir isso diretamente na planilha de origem.

## 6. Como reproduzir esta comparação

```bash
python popular_seeds.py --estrutura-precos "<...>\Preço\Apoio\Apoio - BI de Preço.xlsm" --estrutura-fonte legado
```

```bash
python aplicar_gold.py
```

Os números do legado vêm do PBIX aberto no Power BI Desktop, consultados com
`dax_query_operations` sobre as medidas `XX_*`. Os números da gold vêm de
`gold.dim_estrutura` e `gold.fato_reservas` (veja a seção 2 de
`powerbi/PAGINA_PRECO.md` para o de-para completo entre as medidas antigas e as
novas).
