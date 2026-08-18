# BI de Preço — como replicar as páginas na `gold` (task 6.5)

Mapa visual-a-visual do PBIX legado (`Relatórios Comercial/Preço/BI Preço.pbix`) para o
modelo novo. Extraído do `Report/Layout` do próprio arquivo em 12/ago/2026 + do catálogo de
medidas em `_bi_ref/RESUMO_BIPreco.md`.

Medidas: `powerbi/MEDIDAS_ESTOQUE_PRECO.dax` (bloco A já criado no modelo vivo; bloco B
depende de um refresh — ver "Passos no Desktop").

---

## 1. O que o legado é

**21 páginas** = 1 página por empreendimento (13) + 1 página "Gráfico Histórico" para 7 deles
+ "F16 Novo" (um redesign em HTML que ficou só no Fiusa) + "Resumo".

Cada página de empreendimento tem sempre **a mesma estrutura**, com as tabelas duplicadas por
produto (`PA_Matriz`/`PA_Vendas`, `TR_Matriz`/`TR_Vendas`, ...) e 9 medidas repetidas com
prefixo. É o R4 do `REGRAS_NEGOCIO.md` levado ao extremo: 12 conjuntos de medidas idênticas
com constantes de margem coladas no DAX.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Margem │ MargemViab │ Metragem │ VGV Proj. │ M² Vend. │ VGV Real. │ ...   │  9 cards
├──────────────┬───────────────────────────────────────────────────────────┤
│ M² Praticado │  MATRIZ "REALIZADO"                                       │
│  (total)     │  linhas: Produto > Torre/Bloco > Prumada                  │
│  Frente      │  colunas: Frente-Fundo > Final                            │
│  Parque      │  valores: contagem de vendas + M² praticado               │
│  Lateral     │                                                           │
├──────────────┼───────────────────────────────────────────────────────────┤
│ M² a Realizar│  MATRIZ "A REALIZAR"  (mesmas linhas/colunas)             │
│  (total)     │  valores: Estoque Qtd + M² a realizar                     │
│  Frente ...  │                                                           │
└──────────────┴───────────────────────────────────────────────────────────┘
```

A leitura de negócio das duas matrizes: **onde eu vendi e por quanto** (em cima) x **o que
sobrou e a que preço de tabela** (embaixo), sempre cortado por posição da unidade — andar
(prumada), face (frente/fundo/parque) e final. É o que sustenta decisão de reajuste de tabela
por posição, que é o propósito do BI.

## 2. O desenho novo: 21 páginas → 3

Uma página só, com **slicer de empreendimento** (`dim_empreendimento[empreendimento]`), faz o
papel das 13. As medidas não têm mais prefixo e a margem vem parametrizada de
`dim_viabilidade` em vez de constante no DAX.

| Página nova | Substitui | Fonte |
|---|---|---|
| **Preço & Estoque** | as 13 páginas de empreendimento | `dim_estrutura` + `fato_reservas` + `dim_viabilidade` |
| **Histórico** | as 7 páginas "Gráfico Histórico" | `dim_estrutura` (ano_venda) |
| **Carteira** | página "Resumo" | `dim_estrutura` + `fato_reservas` + `dim_viabilidade` |

## 3. Página "Preço & Estoque"

### 3.1 Cards do topo (na ordem do legado)

| # | Card legado | Medida nova | Observação |
|---|---|---|---|
| 1 | `XX_Margem` | `Margem` | ⚠️ só 2 produtos têm parâmetro — ver §6 |
| 2 | `XX_MargemViab` | `MargemViab` | idem |
| 3 | `SUM(XX_Matriz[Área Privativa])` | `Metragem Total` | |
| 4 | `XX_ProjetadoVGV` | `ProjetadoVGV` | |
| 5 | `SUM(XX_Vendas[M² da unidade])` | `Metragem Vendida` | |
| 6 | `SUM(XX_Vendas[Valor do contrato])` | `VGV Realizado` | |
| 7 | `XX_MetragemAVender` | `MetragemAVender` | |
| 8 | `XX_Permuta` | `Metragem Permuta` | |
| 9 | `XX_EstoqueVGV` | `EstoqueVGV` | ⚠️ muda de número — ver §6 |

Vale acrescentar dois que o legado não tinha e são baratos: `VSO` e `Ticket Médio Estoque`.

### 3.2 Matriz "Realizado" (superior)

| Papel | Legado | Novo |
|---|---|---|
| Linhas | `XX_Matriz[Produto]` > `[Torre]` > `[Prumada]` | `dim_estrutura[produto]` > `[bloco]` > `[config_1]` |
| Colunas | `XX_Matriz[Frente/Fundo]` > `[Final]` | `dim_estrutura[config_2]` > `[config_3]` |
| Valores | `COUNT(M² Praticado)` + `SUM(M² Praticado)` | `Qtd Vendida (matriz)`* + `M² Médio Realizado (matriz)` |

\* use `CALCULATE(COUNTROWS(dim_estrutura), dim_estrutura[status_unidade]="Realizado")`, ou
`VGV Realizado (matriz)` se quiser o valor em R$ em vez da contagem.

**⚠️ Por que as medidas do bloco A não servem aqui:** elas leem `fato_reservas`, que **não é
filtrada** pelas linhas da matriz — não existe (e não pode existir) relacionamento
`dim_estrutura → fato_reservas`, porque fecharia um losango de filtro com `dim_empreendimento`
e o Power BI recusa. Por isso a `gold.dim_estrutura` passou a carregar o realizado no grão da
unidade (`vgv_realizado`, `m2_praticado`, `agio_pct`, `ano_venda`) — é o que o bloco B usa.

### 3.3 Matriz "A Realizar" (inferior)

Mesmas linhas e colunas. Valores: `Estoque Qtd` + `M²ARealizar`. Essa já funciona 100% com o
que está no modelo (é `dim_estrutura` pura).

### 3.4 Cards laterais por posição

O legado tinha ~6 cards com filtro fixo (`Frente/Fundo = 'Frente'`, `= 'Parque'`,
`= 'Lateral'`...) — um por face, **hard-coded por empreendimento** (por isso Tríade tinha
"Lazer" e Parc das Artes tinha "Parque"). No modelo novo isso vira **um gráfico de barras**
por `dim_estrutura[config_2]` com a medida `M² Praticado (matriz)` / `M²ARealizar`: mesma
informação, sem card hard-coded, e se aparecer uma face nova ela entra sozinha.

### 3.5 O que significa `config_1/2/3` em cada produto

O `base_precos.xlsm` padronizou as colunas de posição como CONFIG_1/2/3, mas o significado
muda entre vertical e horizontal — importante ao rotular a matriz:

Na matriz do legado as colunas se chamam `Prumada` / `Frente/Fundo` / `Final` nos produtos
verticais mais antigos e `CONFIG_1/2/3` nos mais novos — o loader normaliza tudo para
`config_1/2/3`, então o significado por produto é:

| Produto | config_1 | config_2 | config_3 |
|---|---|---|---|
| Arboretto, Fiusa 016, Parc Cidade Jardim, Parc Sul, Parc das Artes, Tríade, Primaveras, Parc das Orquídeas | prumada (faixa de pavimentos: "01º ao 03º") | face ("Frente"/"Fundo"/"Lazer"/"Parque"/"Estac.") | final ("1 e 8", "2 e 7") |
| Villas do Parque (Casas e Lotes) | "Esquina"/"Quadra" | "Muro"/"Sem Muro" | detalhe do muro |
| Parc Paineira | prumada | — | — |
| Quinta da Boa Vista | tipologia do lote ("LOTE MISTO...") | — | — |
| Villa Manacás | "Com suíte"/"Sem suíte" | — | — |
| Residencial Quinta dos Ventos | "Lote_Casa" | — | — |

Nos 4 últimos a matriz de posição degenera (só uma dimensão para cruzar) — a página mostra a
quebra por `bloco`/quadra x `config_1`. Não é falha da migração: **é o que existe na origem**.

### 3.6 Duas páginas, não uma

A quebra da matriz serve a duas perguntas diferentes, e uma página não faz as duas:

| Página | Slicer | Linha da matriz | Pergunta que responde |
|---|---|---|---|
| **Carteira** | nenhum | `produto` | qual produto está com o estoque parado, e a que preço |
| **Preço por Produto** | `dim_empreendimento[empreendimento]` | `produto` × `bloco` | dentro deste produto, que posição está cara ou barata |

A segunda é o BI de Preço legado propriamente dito (era 1 página por produto). A primeira
não existia — o "Resumo" do legado era 18 tabelas empilhadas.

Mudam só as duas medidas de matriz; KPIs do topo e painéis laterais são os mesmos nas duas.

| Visual | Carteira | Preço por Produto |
|---|---|---|
| matriz de cima | `Matriz M² Realizado HTML` | `Matriz M² Realizado por Bloco HTML` |
| matriz de baixo | `Matriz M² A Realizar HTML` | `Matriz M² A Realizar por Bloco HTML` |

⚠️ **Na Carteira as colunas ficam com as 33 `config_1` de todos os produtos** — prumada de
apartamento e tipologia de lote na mesma tabela. É correto (é o que existe), mas é muita
coluna. Duas saídas: deixar rolar na horizontal (`overflow-x:auto` já está no CSS), ou trocar
o eixo de coluna da Carteira para algo comum a todos os produtos — `status_unidade`, ou nada,
virando a matriz do §5. Vale decidir olhando a página montada.

### 3.7 Versão em HTML Content (é a que está montada)

O dev já tinha começado essa página no legado com o visual **HTML Content**, e a réplica seguiu
por ali — 5 medidas em `powerbi/PAGINA_PRECO_HTML.dax`, todas já criadas no modelo (pasta
`Preço/HTML`):

| Medida | Onde vai | Substitui |
|---|---|---|
| `KPIs Preço HTML` | faixa do topo, largura cheia (~80px de altura) | os 9 cards |
| `Painel Realizado HTML` | coluna esquerda, ao lado da matriz de cima | os cards "M² Realizado / Frente / Fundo / Média VGV / Atingimento" |
| `Matriz M² Realizado HTML` | centro/direita, em cima | a matriz superior |
| `Painel A Realizar HTML` | coluna esquerda, ao lado da matriz de baixo | os cards de estoque |
| `Matriz M² A Realizar HTML` | centro/direita, embaixo | a matriz inferior |

Cada uma vai num visual **HTML Content**, campo `content`/`Values` = a medida. Nada de linha,
coluna ou valor: a medida monta a tabela inteira.

Três coisas que a versão nova faz diferente do rascunho, todas propositais:

1. **A matriz de estoque mostra preço de tabela** (`M²ARealizar`). No rascunho ela usava
   `[F16_M²Médio]` — média do praticado nas *vendas* — e por isso as duas tabelas exibiam o
   mesmo R$/m² em todas as células.
2. **Os cards de face são dinâmicos** (`config_2`), não hard-coded. Fiusa mostra Frente/Fundo,
   Parc das Artes mostra Frente/Lateral/Parque, Tríade mostra Frente/Lazer — sem editar medida.
3. **O gradiente é calculado sobre as células** (média por linha × coluna), não sobre a unidade
   solta. No rascunho o min/max vinha da coluna crua e quase toda célula caía na faixa clara.

Conferido contra o print do legado (Fiusa 016): colunas idênticas, total 330 unidades,
R$/m² por coluna 5.519 / 5.344 / 5.737 / 6.789 / 6.283 / 6.147 contra 5.519 / 5.334 / 5.737 /
6.842 / 6.310 / 6.118, atingimento de VGV 57,2% igual. As diferenças de 1-2 unidades por
célula são o match unidade↔reserva (R17), não a fórmula.

## 4. Página "Histórico"

Legado: slicers (Prumada, Frente/Fundo, Final, Área Privativa, Ano) + gráfico de linha de
`SUM(M² Praticado)` e `COUNT(M² Praticado)` por Ano.

Novo: mesmos slicers em `dim_estrutura[config_1/2/3]` e `[area_privativa]`, gráfico de linha
com eixo `dim_estrutura[ano_venda]` e as medidas `M² Médio Realizado (matriz)` (linha) +
`VGV Realizado (matriz)` ou contagem de realizadas (coluna).

Usar `ano_venda` de `dim_estrutura` (e não `dim_calendario`) é de propósito: mantém os
slicers de posição funcionando, que é o ponto da página. Para recorte mensal/trimestral, a
`fato_reservas` + `dim_calendario` continuam disponíveis — só não aceitam corte por posição.

## 5. Página "Carteira" (ex-"Resumo")

O legado tinha **18 tabelas empilhadas**, duas por empreendimento (uma de metragem, uma de
valor), cada uma amarrada às tabelas daquele produto. Vira **uma matriz só**, linhas =
`dim_empreendimento[empreendimento]`:

`Metragem Total` · `Metragem Vendida` · `MetragemAVender` · `Metragem Permuta` ·
`ProjetadoVGV` · `VGV Realizado` · `M² Médio Realizado` · `EstoqueVGV` · `M²ARealizar` ·
`MargemViab` · `Margem` · `VSO` · `% IVV Padrão` · `Diferença IVV x Padrão`

As 3 últimas o legado não tinha nessa tela e são as que respondem a pergunta que a página
quer responder ("qual produto está com o estoque parado?").

## 6. O que muda de número em relação ao legado

Levantado comparando os dois modelos ao vivo (o PBIX legado estava aberto). Detalhe completo
em `reconciliacao/preco_legado_vs_gold.md`.

**A pipeline usa a MESMA matriz de preço do legado** desde 12/ago/2026 (`Preço/Apoio/Apoio -
BI de Preço.xlsm`) — decisão do dev sobre R22. Com isso o preço de tabela deixou de ser fonte
de divergência: `EstoqueVGV` bate ao centavo em Arboretto e Primaveras, e `MargemViab` bate à
8ª casa em 7 produtos. O que ainda difere:

1. **`EstoqueVGV` incluía permuta no legado** e a `Estoque Qtd`/`MetragemAVender` não —
   inconsistência do próprio legado. `EstoqueVGV` novo exclui; `EstoqueVGV (legado, c/
   permuta)` reproduz o antigo. Diferença de R$ 16,6 mi no Arboretto e R$ 15,1 mi no Parc Sul.
2. **`ProjetadoVGV` agora usa valor de contrato no realizado** (como o legado), não o preço
   de tabela — a versão da task 6.4 inflava o realizado.
3. **Unidade distratada volta pro estoque.** O legado só enxergava vendas vivas (as planilhas
   `<Produto> - Resumo.xlsm` só têm Situação="Vendida"); a task 6.4 contava distrato como
   vendido. A regra antiga segue em `dim_estrutura[status_unidade_c_distrato]` para auditoria.
4. Estoque diverge 1-3 unidades por produto porque **a base do legado está defasada** (o
   resumo é colado à mão): ex. Parc das Artes 22 unidades no legado x 20 na gold. É o mesmo
   R10 da Vendas Consolidadas, e a favor da pipeline.
5. **F16** difere 0,007pp na MargemViab: o DAX legado subtraía 0,097 mas usava 0,9033 no
   denominador (não fecha com ele mesmo). **Parc das Orquídeas** difere 0,35pp porque usa o
   estudo de viabilidade real da planilha, não a constante do DAX (que tinha outro custo de
   obra, ~R$ 531 mil a mais).

## 7. Regra de ouro ao mexer no modelo por fora (XMLA/powerbi-mcp)

**Só medidas, relacionamentos e propriedades. Tabela e coluna, nunca.** Aprendido na marra
em 12/ago/2026, duas vezes no mesmo dia:

1. **Coluna nova numa view já importada não entra**: o Power Query cacheia o schema da fonte
   por sessão do Desktop. `column_operations Create` + refresh falha com *"A coluna 'x' não
   existe no conjunto de linhas"* e deixa a partição `Incomplete` — o que quebra o refresh
   do dev também. Só sai reabrindo o Desktop.
2. **Tabela nova criada por XMLA impede salvar o arquivo**: ela entra como consulta que o
   editor do Power Query não authorou, aí a barra "alterações pendentes" aparece e o
   "Aplicar alterações" morre em *"Coleção foi modificada; talvez a operação de enumeração
   não seja executada"*. O modelo em memória fica perfeito e o `.pbix` não salva — todo o
   trabalho se perde ao fechar.

Medidas e relacionamentos não tocam a camada de consultas e salvam sem problema.

## 8. Passos no Desktop

Estado em 13/ago/2026 — **25 medidas já estão no modelo** ("Esteira de reservas"), em pastas
`Preço/*`. As colunas novas de `dim_estrutura`/`fato_reservas` também já entraram, e a
`dim_ivv` do modelo aponta para `gold.dim_ivv_padrao` (serve o `% IVV Padrão` sem tabela nova).

1. **Ctrl+S agora** — persiste as 25 medidas antes de qualquer outra coisa.
2. **Adicionar `gold.dim_viabilidade` pela UI**: Obter dados → PostgreSQL →
   `localhost:5433` / `pafil_dw` → marcar `gold.dim_viabilidade` → Carregar. É a única
   tabela que falta, e tem que ser pela UI (§7).
3. Relacionar `dim_viabilidade[codigo_cv]` (muitos) → `dim_empreendimento[codigo_interno_empreendimento]` (um).
4. Colar as 5 medidas de margem (`Custo de Obra`, `% Receita Líquida`, `Margem`, `MargemViab`,
   `Δ Margem x Viabilidade`) de `MEDIDAS_ESTOQUE_PRECO.dax`.
5. **Ctrl+S de novo.**
6. Montar os visuais (§3–§5) — isso é UI mesmo, não dá pela API.

## 9. Pendências / decisões da gestão

Resolvidos em 12/ago/2026 pela troca de matriz + preenchimento da viabilidade:
✅ Margem/MargemViab saem para 11 produtos (era 2) · ✅ Villa Manacás sem o erro de 1000x
(era só do `base_precos.xlsm`) · ✅ Quinta da Boa Vista bate exatamente · ✅ Parc Paineira
passou a existir (144 unidades).

Em aberto:

- 🔴 **Villas do Pq. Lotes Mistos ficou sem preço**: a matriz do legado nunca precificou esses
  164 lotes (o `base_precos.xlsm` tinha, R$ 23,9 mi de estoque). Hoje eles aparecem no estoque
  em quantidade e metragem, mas com VGV vazio. Decidir: completar na planilha do legado, ou
  fazer o loader cair no `base_precos.xlsm` só para as unidades sem preço.
- ⚠️ **Residencial Quinta dos Ventos** tem estrutura diferente nos dois arquivos (158 unidades
  / 7.119 m² no legado x 161 / 4.103 m² no `base_precos`). O legado não tinha página para esse
  produto, então nenhum dos dois foi validado por uso. Conferir qual está certo.
- **R1 aplicado ao estoque:** distrato devolve a unidade ao estoque? (implementado como sim,
  igual ao legado — confirmar com a gestão).
- **Viabilidade preenchida a partir do DAX legado** (9 produtos): são constantes de vintage
  desconhecido, recuperadas de fórmula. Validar contra o estudo vigente. Duas ressalvas já
  conhecidas: o custo de obra veio só como TOTAL (a linha "Terreno" ficou em branco de
  propósito e o valor inteiro está em "Construção"), e **Villas do Pq. Casas recebeu a
  viabilidade do produto inteiro** (o legado tratava Casas + Lotes como um só) — se a gestão
  quiser separar, é preciso ratear.
- **Parc Paineira** ainda não tem viabilidade (não existe na `tab_viabil_padrão`), e no DAX
  legado ele usava as constantes de Parc das Orquídeas — provavelmente errado desde sempre.
