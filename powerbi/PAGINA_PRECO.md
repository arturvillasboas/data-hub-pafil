# BI de Preço: como replicar as páginas na gold (task 6.5)

Este documento é um mapa visual a visual, ligando o PBIX legado
(`Relatórios Comercial/Preço/BI Preço.pbix`) ao modelo novo. Foi extraído do
`Report/Layout` do próprio arquivo em 12 de agosto de 2026, combinado com o
catálogo de medidas em `_bi_ref/RESUMO_BIPreco.md`.

As medidas ficam em `powerbi/MEDIDAS_ESTOQUE_PRECO.dax` (o bloco A já está criado
no modelo vivo; o bloco B depende de um refresh, veja a seção "Passos no
Desktop" mais abaixo).

---

## 1. Como o sistema legado é organizado

São 21 páginas ao todo: uma por empreendimento (totalizando 13), mais uma página
"Gráfico Histórico" para 7 deles, mais "F16 Novo" (um redesign em HTML que ficou
restrito ao Fiusa) e, por fim, "Resumo".

Cada página de empreendimento segue sempre a mesma estrutura, com tabelas
duplicadas por produto (`PA_Matriz`/`PA_Vendas`, `TR_Matriz`/`TR_Vendas`, e assim
por diante) e 9 medidas repetidas, cada uma com um prefixo diferente. É a regra R4
do `REGRAS_NEGOCIO.md` levada ao extremo: 12 conjuntos de medidas idênticas, cada
um com suas próprias constantes de margem coladas diretamente no DAX.

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

A leitura de negócio por trás dessas duas matrizes é: onde eu vendi e por quanto
(a matriz de cima), contra o que sobrou e a que preço de tabela (a de baixo),
sempre cortado pela posição da unidade: o andar (prumada), a face (frente, fundo
ou parque) e o final. É essa comparação que sustenta a decisão de reajustar a
tabela de preço por posição, que é o propósito central deste BI.

## 2. O novo desenho: de 21 páginas para 3

Uma única página, com um slicer de empreendimento
(`dim_empreendimento[empreendimento]`), passa a fazer o papel das 13 anteriores.
As medidas deixam de ter prefixo, e a margem passa a vir parametrizada de
`dim_viabilidade`, em vez de estar fixa no código DAX.

| Página nova | Substitui | Fonte |
|---|---|---|
| Preço & Estoque | as 13 páginas de empreendimento | `dim_estrutura`, `fato_reservas` e `dim_viabilidade` |
| Histórico | as 7 páginas "Gráfico Histórico" | `dim_estrutura` (campo `ano_venda`) |
| Carteira | a página "Resumo" | `dim_estrutura`, `fato_reservas` e `dim_viabilidade` |

## 3. A página "Preço & Estoque"

### 3.1 Os cards do topo (na mesma ordem do legado)

| # | Card no legado | Medida nova | Observação |
|---|---|---|---|
| 1 | `XX_Margem` | `Margem` | Atenção: só 2 produtos têm o parâmetro preenchido, veja a seção 6 |
| 2 | `XX_MargemViab` | `MargemViab` | O mesmo vale aqui |
| 3 | `SUM(XX_Matriz[Área Privativa])` | `Metragem Total` | |
| 4 | `XX_ProjetadoVGV` | `ProjetadoVGV` | |
| 5 | `SUM(XX_Vendas[M² da unidade])` | `Metragem Vendida` | |
| 6 | `SUM(XX_Vendas[Valor do contrato])` | `VGV Realizado` | |
| 7 | `XX_MetragemAVender` | `MetragemAVender` | |
| 8 | `XX_Permuta` | `Metragem Permuta` | |
| 9 | `XX_EstoqueVGV` | `EstoqueVGV` | Atenção: o número muda em relação ao legado, veja a seção 6 |

Vale acrescentar dois cards que o legado não tinha, e que são baratos de calcular:
`VSO` e `Ticket Médio Estoque`.

### 3.2 A matriz "Realizado" (a de cima)

| Papel | No legado | No modelo novo |
|---|---|---|
| Linhas | `XX_Matriz[Produto]` acima de `[Torre]` acima de `[Prumada]` | `dim_estrutura[produto]` acima de `[bloco]` acima de `[config_1]` |
| Colunas | `XX_Matriz[Frente/Fundo]` acima de `[Final]` | `dim_estrutura[config_2]` acima de `[config_3]` |
| Valores | `COUNT(M² Praticado)` mais `SUM(M² Praticado)` | `Qtd Vendida (matriz)`* mais `M² Médio Realizado (matriz)` |

\* Use `CALCULATE(COUNTROWS(dim_estrutura), dim_estrutura[status_unidade]="Realizado")`,
ou `VGV Realizado (matriz)` se preferir o valor em reais em vez da contagem.

**Atenção: por que as medidas do bloco A não servem aqui.** Elas leem
`fato_reservas`, que não é filtrada pelas linhas da matriz. Não existe, e não pode
existir, um relacionamento direto de `dim_estrutura` para `fato_reservas`, porque
isso fecharia um losango de filtro junto com `dim_empreendimento`, e o Power BI
recusa esse tipo de relacionamento. Por causa disso, `gold.dim_estrutura` passou a
carregar o realizado no próprio grão da unidade (as colunas `vgv_realizado`,
`m2_praticado`, `agio_pct` e `ano_venda`). É exatamente isso que o bloco B usa.

### 3.3 A matriz "A Realizar" (a de baixo)

Usa as mesmas linhas e colunas da matriz de cima. Os valores são `Estoque Qtd` e
`M²ARealizar`. Essa matriz já funciona 100% com o que já existe no modelo, porque
é `dim_estrutura` pura, sem depender de `fato_reservas`.

### 3.4 Os cards laterais por posição

O legado tinha cerca de 6 cards com filtro fixo (`Frente/Fundo = 'Frente'`,
depois `= 'Parque'`, depois `= 'Lateral'`, e assim por diante), um por face, cada
um fixo no código para aquele empreendimento específico (por isso Tríade tinha um
card "Lazer" e Parc das Artes tinha um card "Parque", cada um hard-coded). No
modelo novo, isso vira um único gráfico de barras, agrupado por
`dim_estrutura[config_2]`, usando a medida `M² Praticado (matriz)` dividida por
`M²ARealizar`: a mesma informação, sem nenhum card fixo no código, e se uma face
nova aparecer no futuro, ela já entra sozinha no gráfico.

### 3.5 O que `config_1`, `config_2` e `config_3` significam em cada produto

O arquivo `base_precos.xlsm` padronizou as colunas de posição como CONFIG_1, 2 e
3, mas o significado de cada uma muda entre produtos verticais e horizontais, o
que é importante na hora de rotular a matriz.

Na matriz do legado, essas colunas se chamam `Prumada`, `Frente/Fundo` e `Final`
nos produtos verticais mais antigos, e `CONFIG_1/2/3` nos mais novos. O loader
normaliza tudo para `config_1`, `config_2` e `config_3`, e o significado de cada
uma por produto fica assim:

| Produto | config_1 | config_2 | config_3 |
|---|---|---|---|
| Arboretto, Fiusa 016, Parc Cidade Jardim, Parc Sul, Parc das Artes, Tríade, Primaveras, Parc das Orquídeas | prumada (faixa de pavimentos, como "01º ao 03º") | face ("Frente", "Fundo", "Lazer", "Parque" ou "Estac.") | final ("1 e 8", "2 e 7") |
| Villas do Parque (Casas e Lotes) | "Esquina" ou "Quadra" | "Muro" ou "Sem Muro" | detalhe do muro |
| Parc Paineira | prumada | | |
| Quinta da Boa Vista | tipologia do lote ("LOTE MISTO...") | | |
| Villa Manacás | "Com suíte" ou "Sem suíte" | | |
| Residencial Quinta dos Ventos | "Lote_Casa" | | |

Nos últimos quatro produtos da lista, a matriz de posição degenera, porque só
existe uma dimensão para cruzar; a página mostra a quebra por bloco ou quadra
contra `config_1`. Isso não é uma falha da migração: é exatamente o que existe na
origem dos dados.

### 3.6 Duas páginas, não uma

A quebra da matriz serve a duas perguntas diferentes, e uma página só não
consegue responder às duas ao mesmo tempo:

| Página | Slicer | Linha da matriz | Pergunta que responde |
|---|---|---|---|
| Carteira | nenhum | `produto` | qual produto está com o estoque parado, e a que preço |
| Preço por Produto | `dim_empreendimento[empreendimento]` | `produto` cruzado com `bloco` | dentro deste produto específico, qual posição está cara ou barata |

A segunda é, na prática, o BI de Preço legado propriamente dito (antes, era uma
página por produto). A primeira não existia no legado: o "Resumo" de lá era 18
tabelas empilhadas uma em cima da outra.

Só as duas medidas de matriz mudam entre as páginas; os KPIs do topo e os painéis
laterais são exatamente os mesmos nas duas.

| Visual | Carteira | Preço por Produto |
|---|---|---|
| matriz de cima | `Matriz M² Realizado HTML` | `Matriz M² Realizado por Bloco HTML` |
| matriz de baixo | `Matriz M² A Realizar HTML` | `Matriz M² A Realizar por Bloco HTML` |

**Atenção:** na página Carteira, as colunas acabam reunindo as 33 grafias
distintas de `config_1` de todos os produtos ao mesmo tempo, misturando a
prumada de um apartamento com a tipologia de um lote na mesma tabela. Isso é
correto, no sentido de refletir fielmente o que existe nos dados, mas resulta em
muitas colunas. Há duas saídas possíveis: deixar a tabela rolar horizontalmente
(o CSS já inclui `overflow-x:auto`), ou trocar o eixo de coluna da Carteira para
algo comum a todos os produtos, como `status_unidade`, ou simplesmente remover
esse eixo, transformando a tabela na matriz mais simples descrita na seção 5.
Vale decidir isso olhando a página já montada.

### 3.7 A versão em HTML Content (é a que está montada hoje)

O desenvolvedor responsável já tinha começado essa página no legado usando o
visual HTML Content, e a réplica seguiu pelo mesmo caminho: são 5 medidas em
`powerbi/PAGINA_PRECO_HTML.dax`, todas já criadas no modelo, dentro da pasta
`Preço/HTML`:

| Medida | Onde é usada | O que substitui |
|---|---|---|
| `KPIs Preço HTML` | na faixa do topo, em largura cheia (cerca de 80px de altura) | os 9 cards |
| `Painel Realizado HTML` | na coluna esquerda, ao lado da matriz de cima | os cards "M² Realizado / Frente / Fundo / Média VGV / Atingimento" |
| `Matriz M² Realizado HTML` | no centro/direita, na parte de cima | a matriz superior |
| `Painel A Realizar HTML` | na coluna esquerda, ao lado da matriz de baixo | os cards de estoque |
| `Matriz M² A Realizar HTML` | no centro/direita, na parte de baixo | a matriz inferior |

Cada uma dessas medidas vai dentro de um visual HTML Content, no campo `content`
(ou `Values`), recebendo a medida diretamente. Não é preciso configurar linha,
coluna ou valor separadamente: a própria medida já monta a tabela inteira.

Há três diferenças propositais entre a versão nova e o rascunho original:

1. **A matriz de estoque agora mostra o preço de tabela** (`M²ARealizar`). No
   rascunho, ela usava `[F16_M²Médio]`, que é a média do preço praticado nas
   vendas, e por isso as duas tabelas acabavam mostrando o mesmo valor de R$/m²
   em todas as células.
2. **Os cards de face agora são dinâmicos**, calculados a partir de `config_2`,
   em vez de fixos no código. O Fiusa mostra Frente e Fundo, Parc das Artes
   mostra Frente, Lateral e Parque, e Tríade mostra Frente e Lazer, tudo sem
   precisar editar nenhuma medida.
3. **O gradiente de cor agora é calculado sobre as células** (a média por linha
   cruzada com coluna), em vez de sobre a unidade solta. No rascunho, o mínimo e
   o máximo vinham da coluna crua, e quase toda célula acabava caindo na faixa
   clara da escala de cor.

Isso foi conferido contra um print do sistema legado, para o produto Fiusa 016:
as colunas ficaram idênticas, o total de 330 unidades bateu, e o valor de R$/m²
por coluna ficou em 5.519, 5.344, 5.737, 6.789, 6.283 e 6.147, contra 5.519,
5.334, 5.737, 6.842, 6.310 e 6.118 no legado, com o atingimento de VGV igual em
57,2%. As pequenas diferenças de 1 a 2 unidades por célula vêm do processo de
match entre unidade e reserva (regra R17), não de um erro na fórmula.

## 4. A página "Histórico"

No legado: slicers de Prumada, Frente/Fundo, Final, Área Privativa e Ano, com um
gráfico de linha mostrando `SUM(M² Praticado)` e `COUNT(M² Praticado)` por ano.

No modelo novo: os mesmos slicers, agora sobre `dim_estrutura[config_1/2/3]` e
`[area_privativa]`, com um gráfico de linha usando `dim_estrutura[ano_venda]`
como eixo, e as medidas `M² Médio Realizado (matriz)` (na linha) e
`VGV Realizado (matriz)` ou a contagem de unidades realizadas (na coluna).

Usar o `ano_venda` de `dim_estrutura`, em vez do `dim_calendario`, é uma escolha
deliberada: ela mantém os slicers de posição funcionando, que é justamente o
ponto central dessa página. Para quem precisar de um recorte mensal ou
trimestral, `fato_reservas` combinada com `dim_calendario` continua disponível
normalmente, só que sem aceitar o corte por posição.

## 5. A página "Carteira" (antiga página "Resumo")

O legado tinha 18 tabelas empilhadas, duas por empreendimento (uma de metragem e
uma de valor), cada uma amarrada às tabelas específicas daquele produto. Isso
virou uma única matriz, com as linhas organizadas por
`dim_empreendimento[empreendimento]`:

`Metragem Total`, `Metragem Vendida`, `MetragemAVender`, `Metragem Permuta`,
`ProjetadoVGV`, `VGV Realizado`, `M² Médio Realizado`, `EstoqueVGV`,
`M²ARealizar`, `MargemViab`, `Margem`, `VSO`, `% IVV Padrão` e
`Diferença IVV x Padrão`.

As três últimas dessa lista não existiam nessa tela no legado, e são justamente
as que respondem à pergunta que a página quer responder: qual produto está com o
estoque parado?

## 6. O que muda de número em relação ao legado

Estas diferenças foram levantadas comparando os dois modelos ao vivo, com o PBIX
legado aberto ao mesmo tempo. O detalhe completo está em
`reconciliacao/preco_legado_vs_gold.md`.

**Desde 12 de agosto de 2026, a pipeline usa a mesma matriz de preço do legado**
(o arquivo `Preço/Apoio/Apoio - BI de Preço.xlsm`), uma decisão do desenvolvedor
relacionada à regra R22. Com isso, o preço de tabela deixou de ser fonte de
divergência: `EstoqueVGV` bate ao centavo em Arboretto e em Primaveras, e
`MargemViab` bate até a 8ª casa decimal em 7 produtos. O que ainda diverge é o
seguinte:

1. **No legado, `EstoqueVGV` incluía permuta**, enquanto `Estoque Qtd` e
   `MetragemAVender` não incluíam, uma inconsistência que já existia no próprio
   sistema legado. O novo `EstoqueVGV` exclui permuta; para reproduzir o
   comportamento antigo, existe a medida `EstoqueVGV (legado, com permuta)`. A
   diferença chega a R$ 16,6 milhões em Arboretto e R$ 15,1 milhões em Parc Sul.
2. **`ProjetadoVGV` agora usa o valor de contrato no realizado**, do mesmo jeito
   que o legado fazia, em vez do preço de tabela. A versão implementada na task
   6.4 inflava esse número.
3. **Uma unidade distratada agora volta ao estoque.** O legado só enxergava
   vendas vivas, porque as planilhas `<Produto> - Resumo.xlsm` só trazem
   `Situação="Vendida"`; a implementação da task 6.4 contava distrato como se
   fosse venda. A regra antiga continua disponível em
   `dim_estrutura[status_unidade_c_distrato]`, para fins de auditoria.
4. O estoque diverge de 1 a 3 unidades por produto, porque a base do legado está
   defasada (o resumo é colado à mão): por exemplo, Parc das Artes aparece com
   22 unidades no legado contra 20 na gold. É o mesmo fenômeno da regra R10 da
   Vendas Consolidadas, e a divergência joga a favor da pipeline nova, que está
   mais atualizada.
5. **O produto F16 diverge 0,007 ponto percentual na MargemViab**, porque o DAX
   legado subtraía 0,097 mas usava 0,9033 no denominador, uma inconsistência que
   já existia dentro do próprio DAX legado, sem bater consigo mesmo. **Parc das
   Orquídeas diverge 0,35 ponto percentual** porque a versão nova usa o estudo de
   viabilidade real da planilha, em vez da constante fixa no DAX (que tinha um
   custo de obra diferente, cerca de R$ 531 mil a mais).

## 7. A regra de ouro ao mexer no modelo por fora (via XMLA ou powerbi-mcp)

**Só mexa em medidas, relacionamentos e propriedades. Nunca em tabela ou coluna.**
Essa lição foi aprendida da forma mais difícil possível, em 12 de agosto de 2026,
duas vezes no mesmo dia:

1. **Uma coluna nova em uma view já importada simplesmente não entra no
   modelo.** O Power Query guarda em cache o schema da fonte durante toda a
   sessão do Desktop. Rodar `column_operations Create` seguido de um refresh
   falha com o erro "A coluna 'x' não existe no conjunto de linhas", e deixa a
   partição marcada como `Incomplete`, o que quebra até o refresh normal do
   desenvolvedor. A única saída é reabrir o Power BI Desktop do zero.
2. **Uma tabela nova criada por XMLA impede que o arquivo seja salvo.** Ela
   entra como uma consulta que o editor do Power Query não reconhece como
   própria, então a barra de "alterações pendentes" aparece, e o botão "Aplicar
   alterações" trava com o erro "Coleção foi modificada; talvez a operação de
   enumeração não seja executada". O modelo em memória fica perfeito, mas o
   `.pbix` não salva, e todo o trabalho se perde ao fechar o programa.

Medidas e relacionamentos não tocam a camada de consultas, e por isso salvam sem
nenhum problema.

## 8. Passos a seguir no Power BI Desktop

Estado em 13 de agosto de 2026: 25 medidas já estão no modelo, organizadas na
pasta "Esteira de reservas", dentro das subpastas `Preço/*`. As colunas novas de
`dim_estrutura` e `fato_reservas` também já entraram, e a `dim_ivv` do modelo já
aponta para `gold.dim_ivv_padrao`, o que já serve o `% IVV Padrão` sem precisar de
uma tabela nova.

1. **Aperte Ctrl+S agora**, antes de qualquer outra coisa, para persistir as 25
   medidas.
2. **Adicione `gold.dim_viabilidade` pela interface**: vá em Obter dados →
   PostgreSQL → `localhost:5433` / `pafil_dw` → marque `gold.dim_viabilidade` →
   Carregar. É a única tabela que ainda falta, e ela precisa entrar pela
   interface, pelo motivo explicado na seção 7.
3. Relacione `dim_viabilidade[codigo_cv]` (o lado "muitos") com
   `dim_empreendimento[codigo_interno_empreendimento]` (o lado "um").
4. Cole as 5 medidas de margem (`Custo de Obra`, `% Receita Líquida`, `Margem`,
   `MargemViab`, `Δ Margem x Viabilidade`), disponíveis em
   `MEDIDAS_ESTOQUE_PRECO.dax`.
5. **Aperte Ctrl+S de novo.**
6. Monte os visuais descritos nas seções 3 a 5. Essa parte é mesmo trabalho
   manual de interface, não dá para fazer pela API.

## 9. Pendências e decisões que dependem da gestão

Já resolvidos em 12 de agosto de 2026, pela troca de matriz de preço combinada
com o preenchimento da viabilidade: a Margem e a MargemViab agora saem para 11
produtos, contra apenas 2 antes; Villa Manacás não tem mais o erro de 1000x (que
existia só no `base_precos.xlsm`); Quinta da Boa Vista bate exatamente; e Parc
Paineira voltou a existir no relatório, com 144 unidades.

O que ainda está em aberto:

- **Crítico: Villas do Pq. Lotes Mistos ficou sem preço.** A matriz do legado
  nunca precificou esses 164 lotes (o `base_precos.xlsm` tinha um valor para
  eles, R$ 23,9 milhões em estoque). Hoje esses lotes aparecem no estoque em
  quantidade e em metragem, mas com o VGV vazio. É preciso decidir: completar o
  preço na planilha do legado, ou fazer o loader recorrer ao `base_precos.xlsm`
  só para as unidades que estão sem preço.
- **Atenção: Residencial Quinta dos Ventos tem uma estrutura diferente entre os
  dois arquivos** (158 unidades e 7.119 m² no legado, contra 161 unidades e
  4.103 m² no `base_precos`). O legado não tinha uma página dedicada a esse
  produto, então nenhuma das duas versões foi validada pelo uso real. É preciso
  conferir qual delas está correta.
- **A regra R1 aplicada ao estoque:** um distrato deve devolver a unidade ao
  estoque? Hoje está implementado que sim, igual ao comportamento do legado, mas
  isso precisa ser confirmado com a gestão.
- **A viabilidade preenchida a partir do DAX legado** (9 produtos) usa
  constantes de uma época desconhecida, recuperadas por engenharia reversa de
  fórmula. Precisa ser validada contra o estudo de viabilidade vigente. Duas
  ressalvas já conhecidas: o custo de obra veio só como valor total (a linha
  "Terreno" ficou em branco de propósito, e o valor inteiro está em
  "Construção"), e Villas do Pq. Casas recebeu a viabilidade do produto inteiro,
  porque o legado tratava Casas e Lotes como um produto só. Se a gestão quiser
  separar os dois, vai ser preciso ratear esse valor.
- **Parc Paineira ainda não tem viabilidade própria** (não existe uma linha para
  ele em `tab_viabil_padrão`), e no DAX legado ele usava as constantes de Parc
  das Orquídeas, o que provavelmente estava errado desde o início.
