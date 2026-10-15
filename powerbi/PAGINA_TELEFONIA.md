# Página "Telefonia" (MDnet)

Volumetria da central telefônica, sobre `gold.fato_chamadas` e `gold.dim_ramal`. As medidas
estão em [MEDIDAS_TELEFONIA.dax](MEDIDAS_TELEFONIA.dax).

A página existe para responder o que o painel da MDnet não responde: de todas as ligações que
chegaram, quantas foram atendidas, quanto a pessoa esperou, o que ela fez dentro da URA e **quem**
atendeu (setor e responsável). As duas últimas só são possíveis porque a gold cruza o CDR com o
relatório de URA e com a planilha de ramais.

## Antes de montar

São quatro passos, e os dois primeiros são só no Desktop.

1. **Importar as duas tabelas.** Obter dados > PostgreSQL (o arquivo `conectar_gold.pbids`, nesta
   pasta, já aponta para o banco), modo Import, e marque `gold.fato_chamadas` e `gold.dim_ramal`.
   Tabela nova é sempre passo de interface: criar tabela pelo XMLA deixa o Desktop sem conseguir
   salvar o arquivo.
2. **Relacionamentos**, os dois do lado "um" na dimensão:
   - `dim_calendario[data]` 1 a muitos `fato_chamadas[data]`, ativo.
   - `dim_ramal[ramal]` 1 a muitos `fato_chamadas[ramal]`.
3. **Medidas.** Cole o conteúdo de `MEDIDAS_TELEFONIA.dax`. Dá para fazer pelo XMLA (medida e
   relacionamento não mexem na camada de consultas).
4. **Salvar com Ctrl+S.** O que o XMLA escreve fica só no modelo em memória, e some se o arquivo
   fechar sem salvar.

Duas propriedades de coluna que vale ajustar, porque o visual ordena errado sem elas:

- `fato_chamadas[ura_opcao]`: Classificar por coluna > `ura_opcao_ordem`.
- `fato_chamadas[dia_semana_nome]`: Classificar por coluna > `dia_semana`.

E esconder o que é técnico: `chamada_id`, `protocolo`, `direcao_cartao`, `estado_cartao`,
`lado_desligamento`, `motivo_desligamento`, `ura_opcao_ordem`, `ura_codigo_opcao`, `dia_semana`.

Confira também que a `dim_calendario` cobre o mês corrente. Se terminar antes, nada reclama e todo
visual por dia vem vazio.

## Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. Faixa de KPIs (HTML Content)                                     │
├────────────────────────────────────┬─────────────────────────────────┤
│  2. Entradas por dia               │  3. Funil da URA                │
│     (colunas empilhadas)           │     (barras por opção)          │
├────────────────────────────────────┼─────────────────────────────────┤
│  4. Quem atendeu: setor e ramal    │  5. Hora x dia da semana        │
│     (matriz)                       │     (mapa de calor)             │
├────────────────────────────────────┴─────────────────────────────────┤
│  6. Rodapé de qualidade do dado (três cartões pequenos)              │
└──────────────────────────────────────────────────────────────────────┘
```

## 1. Faixa de KPIs

**Visual:** HTML Content. **Medida:** `[KPIs Telefonia HTML]`.

Oito cartões, no mesmo CSS da faixa de Atendimento. As cores têm sentido: vermelho é o que dói
(ligação de gente de verdade que ninguém atendeu, e a taxa de atendimento) e cinza é o ruído, que
não é cliente.

Três coisas para saber ler:

- **"Entradas" é tudo que chegou**, inclusive robocall. Entradas = Atendidas + Não atendidas
  (reais) + Ruído, e os três cartões fecham por soma.
- **"% Atendimento" é a taxa REAL**, sem o ruído. O subtítulo mostra a bruta entre parênteses, que é
  a que o painel web da MDnet mostra. Em setembro/2026 foram 19,0% contra 14,1%, e em agosto 32,0%
  contra 15,7%, porque agosto teve uma onda de robocall (1.155 ligações). Quem comparar com o painel
  tem que olhar a bruta.
- **"Espera" conta o tempo dentro da URA.** É a duração total menos o tempo falado, então o piso já é
  de dezenas de segundos para quem passou pela URA.

## Ajustes pedidos pelo Igor (14/out/2026)

1. **KPIs na nova ordem:** Entradas, Ruído, Atendidas, Não atendidas, **% Não atendimento** (nova,
   `[% Não Atendimento Entrada Real]`), % Atendimento, Espera, Conversa. O cartão "Escolheram na URA"
   saiu para abrir espaço (a rosca da URA e o painel de critérios já mostram esse número). As duas
   taxas somam 100%.
2. **Medida nova para a rosca da URA:** `[Ligações URA Não Atendidas]` (total da URA menos as atendidas,
   no período de 01/01 a 31/10: 2.319 de 3.055) e `[% Não Atendimento URA]`.
3. **Tabela da opção do menu**, 8 colunas: Opção, Total ligações, Não atendidas, Atendidas, Tx não
   atendidas, Tx atendidas, Espera, Conversa. Tabelas de **setor** e **ramal** com as mesmas 7 colunas.
   A pílula da Tx não atendidas é o espelho da outra (vermelha a partir de 75%).
4. **Tabela de ramal** (`[Linha Ramal HTML]`): mesmo desenho, uma linha por número, com o setor em cinza ao
   lado. Montagem igual à do setor, com **Granularity = `dim_ramal[ramal]`**, Tooltips =
   `[Ligações Entrada Atendidas]`, classificar por ela decrescente (assim a linha "Sem ramal registrado",
   que concentra as não atendidas, não vai para o topo) e o mesmo estilo
   `[CSS Tabela URA (linhas)]`. Em vez de drill Setor > Ramal (o HTML Content não tem hierarquia),
   o clique na tabela de setor já filtra a de ramal: é o "abrir" do setor.
5. **Drill Mês > Dia** nos dois gráficos (hierarquia `dim_calendario[Mês > Dia]`, já criada no modelo):
   no eixo X, troque `ano_mes` por essa hierarquia, ligue as setas de drill no visual, e use
   o botão de "abrir no próximo nível" (seta dupla) para ver os dias do mês clicado. No eixo do dia,
   Formatar > Eixo X > Tipo: Categórico, para os dias não virarem linha do tempo contínua.

**Pegadinha das tabelas de setor e ramal:** ligação não atendida quase nunca tem ramal (poucas têm, como
3 de 1.142 no ramal 8260). Por isso o "Total" e as "Não atendidas" por setor ou ramal são quase só
atendidas, e a quase totalidade das não atendidas fica na linha **Sem ramal registrado**, em cinza e
itálico. As colunas servem para ver quem atendeu e quanto esperou, não para a taxa de atendimento do
setor. Total de setor/ramal usa ligações reais (sem ruído). Dá para tentar atribuir a não atendida ao setor
pela opção da URA, mas é regra nova, e vale combinar com o Igor antes.

## 2. Entradas por dia

**Visual:** colunas empilhadas. **Eixo X:** `dim_calendario[data]`. **Valores:**
`[Ligações Entrada Atendidas]`, `[Ligações Entrada Não Atendidas Reais]` e
`[Ligações Entrada Ruído]` (cinza).

Empilhado, e com o ruído como terceira série, porque o total do dia continua sendo a entrada
bruta e o leitor enxerga de uma vez quanto do dia foi gente e quanto foi robô. Nos picos de março e
agosto, uma parte grande da coluna é cinza (39% das entradas de março e 51% das de agosto).

## 3. A URA: dois visuais, duas perguntas

A URA responde duas coisas diferentes, então são dois visuais. Uma barra com "Ligações URA" e "Ligações
URA Atendidas" lado a lado não funciona: a segunda é um pedaço da primeira, e o leitor não sabe o que
comparar.

### 3a. O que acontece com quem entra na URA

**Visual:** gráfico de rosca. **Legenda:** `fato_chamadas[ura_resultado]`. **Valores:** `[Ligações URA]`.
Rótulo "Categoria, porcentagem do total", sem legenda separada.

Cinco fatias, com a cor de cada uma: Chegou a um destino `#003254`, Não digitou nada `#8FB3CC`, Desligou no
menu principal `#B8433F`, Desistiu no submenu `#E0A526` e Menu antigo `#C5CAD3`. A leitura é direta: só cerca de 34% de
quem entra na URA escolhe uma opção, e o resto desiste ou deixa o tempo estourar.

### 3b. Cada opção do menu, quantas são atendidas

**Visual:** HTML Content, com clique que filtra a página. **Medida:** `[Linha Opção URA HTML]`.

É a mesma tabela da página de Atendimentos do CVCRM (grade em CSS grid, cabeçalho fixo, linha zebrada,
destaque ao passar o mouse, clique que filtra o resto, Ctrl+clique que acumula), com cinco colunas:
opção do menu, ligações (com barra de volume), atendidas, **% atendidas** (pílula verde, cinza ou
vermelha) e espera média. A pílula é o que torna a tabela didática: o olho vai direto na opção que está
em vermelho. Em setembro/2026 é a de **Vendas, com 10%** (5 de 48).

Montagem, na ordem:

1. **Values:** `[Linha Opção URA HTML]`.
2. **Granularity:** `fato_chamadas[ura_opcao]`.
3. **Tooltips:** `[Ordem Opção URA (ordenação)]`. Não é pelo tooltip, é para a medida aparecer em
   "Classificar por".
4. **Classificar por** essa medida, **crescente**. Sem isso a tabela vem em ordem alfabética.
5. **Formatar > Stylesheet > fx** e apontar para `[CSS Tabela URA (linhas)]`. Ele é derivado do CSS do
   CVCRM, então ajuste de estilo feito lá chega aqui.
6. **Formatar > Cross-filtering:** ativar, e Transparency em 0.
7. **Formatar > No data message:** "Nenhuma ligação na URA no período selecionado."
8. **Filtros neste visual:** nenhum (15/out/2026). O filtro "Chegou a um destino" saiu, para a tabela
   mostrar também quem não chegou a um destino (não digitou, desligou, desistiu no submenu, menu antigo).

Essas linhas vêm depois das opções do menu, na ordem de `ura_opcao_ordem` (90 a 99), com desempate alfabético em
`[Ordem Opção URA (ordenação)]`.

## 4. Quem atendeu

**Visual:** HTML Content, com clique que filtra a página. **Medida:** `[Linha Setor HTML]`.

Mesma tabela da URA e da página de Atendimentos do CVCRM, com uma linha por **setor** e cinco colunas:
setor (com a unidade, SEDE ou HOUSE, em cinza ao lado), atendidas (com barra de volume), % do total,
espera média e conversa média. Usa a **mesma folha de estilo** da tabela da URA.

Montagem, na ordem:

1. **Values:** `[Linha Setor HTML]`.
2. **Granularity:** `dim_ramal[setor_grupo]`.
3. **Tooltips:** `[Ligações Entrada Atendidas]`.
4. **Classificar por** essa medida, **decrescente**.
5. **Formatar > Stylesheet > fx:** `[CSS Tabela URA (linhas)]`.
6. **Formatar > Cross-filtering:** ativar, e Transparency em 0.
7. **Formatar > No data message:** "Nenhuma ligação atendida no período selecionado."

Setor é o nível que dá para confiar. O responsável é a foto de hoje da planilha de ramais: o ramal 8256
está "Vago" e atendeu 134 entradas de janeiro a abril, e o 8257 oscila (249 atendidas em fevereiro,
nenhuma em junho). Por isso a tabela mostra o setor e não a pessoa.

**Só vale de fevereiro em diante.** Em janeiro/2026, 92% das ligações atendidas não têm ramal (a MDnet
registrava o atendimento pelo número chamado). Comece o slicer de data em 01/02/2026. A linha
"Atendida sem ramal registrado", em cinza e itálico, é o que sobra: ligação atendida sem ramal.

Dois achados desta tabela, com os dados de fevereiro em diante:

- Quem **não digita nada** na URA cai nos ramais da **HOUSE** (principalmente o Backoffice, depois a
  Recepção House), e não em Relacionamento, Suprimentos ou Financeiro. Isso parece acidental e vale
  decidir com a operação. Clique em "Não digitou nada" na rosca da URA e olhe esta tabela.
- A opção de Suprimentos e a de Financeiro transbordam para a HOUSE e a Engenharia quando o ramal
  principal não atende.

## 5. Hora x dia da semana

**Visual:** HTML Content, com clique que filtra a página. **Medida:** `[Linha Hora x Dia HTML]`.

Um mapa de calor com uma linha por hora (de 7h a 19h) e uma coluna por dia da semana, de segunda a
domingo. A **cor é a taxa de atendimento de ligações reais** (sem ruído), e o centro da escala é a taxa
**média do período**, que aparece na legenda do rodapé: **azul acima da média, vermelho abaixo**. A cor
chega ao máximo quando a taxa é o dobro da média (azul) ou zero (vermelho). Assim sempre há contraste,
mesmo quando todas as taxas ficam abaixo de 50%.

Duas proteções contra leitura errada: a célula com **menos de 10 ligações reais fica esmaecida** (100%
de 2 ligações não é 100%), e passar o mouse mostra quantas ligações há por trás dela.

Montagem, na ordem:

1. **Values:** `[Linha Hora x Dia HTML]`.
2. **Granularity:** `fato_chamadas[hora]`.
3. **Tooltips:** `[Hora (ordenação)]`.
4. **Classificar por** essa medida, **crescente**.
5. **Formatar > Stylesheet > fx:** `[CSS Tabela Hora x Dia (linhas)]`.
6. **Formatar > Cross-filtering:** ativar, e Transparency em 0.
7. **Filtros neste visual:** `fato_chamadas[hora]` com **Filtragem avançada**, "é maior ou igual a 7"
   E "é menor ou igual a 19". Das ligações atendidas, 100% caem nesse intervalo.

O clique filtra por **hora** (a linha inteira), não por célula. Responde onde a equipe falta: de
fevereiro a outubro, o **meio-dia** fica em vermelho (cerca de 15% de atendimento, contra 29% da média)
e o fim do dia, às **18h**, é quase todo zero. As terças e quartas às 16h estão entre as células mais
azuis.

## 6. Rodapé de qualidade do dado

**Visual:** três cartões. **Medidas:** `[% Atendidas com Ramal]`, `[Ramais Sem Cadastro]` e
`[% Ruído sobre Entrada]`.

- `% Atendidas com Ramal`: acima de 90% de fevereiro em diante. Abaixo disso, o corte por setor
  está perdendo ligação.
- `Ramais Sem Cadastro`: ramais que atenderam e não estão na planilha. Hoje é 1, o 8223 (63
  atendidas de abril a setembro, sai da lista de ativos). Se subir, a correção é uma linha na
  planilha de ramais, e não no SQL.
- `% Ruído sobre Entrada`: quando sobe de repente, é onda de robocall, e não piora de atendimento.

## Slicers

`dim_calendario[data]` como intervalo, fora do painel (**comece em 01/02/2026**). Não precisa de
slicer de direção: as medidas de entrada, saída e interna já fixam a direção delas.

**Painel "Filtros" (decisão de 13/out/2026).** O mesmo painel lateral da página de Atendimentos do
CVCRM, com seis slots: três listas suspensas, uma lista em duas colunas, uma linha de blocos e uma
lista alta. Os seis filtros, de cima para baixo:

| # | Slot (estilo) | Filtro | Campo | Valores em 13/out/2026 (só entradas) |
|---|---|---|---|---|
| 1 | Lista suspensa | Desfecho | `fato_chamadas[desfecho]` | Cliente desligou 8.837, PABX encerrou 7.455, Atendida 5.179, Outro 17, Origem cancelou 0 |
| 2 | Lista em 2 colunas | Dia da semana | `fato_chamadas[dia_semana_nome]` | 7 |
| 3 | Lista suspensa | Faixa de duração | `fato_chamadas[faixa_duracao]` | 0 a 3 s 5.712, 4 a 10 s 3.449, 11 a 30 s 3.041, 31 a 60 s 2.328, mais de 60 s 6.958 |
| 4 | Blocos | Transferida | `fato_chamadas[e_transferida]` | Sim 1.374 (6,4%), Não 20.114 |
| 5 | Lista suspensa | Unidade | `dim_ramal[unidade]` | sem ramal 17.463, SEDE 3.444, HOUSE 518, Sem cadastro 63 |
| 6 | Lista alta | Setor | `dim_ramal[setor_grupo]` | 16 setores com ligação atendida (a lista do slicer pode ter mais, de ramais sem atendimento) |

**Painel v2 (15/out/2026, pedido do Igor): tudo na página tem que ser filtrável por setor, ramal, opção
do menu, data (mês e dia) e unidade.** Os seis slots mantêm o estilo e mudam de campo, de cima para baixo:

| # | Slot (estilo) | Filtro | Campo |
|---|---|---|---|
| 1 | Lista suspensa | Mês | `dim_calendario[ano_mes]` |
| 2 | Lista em 2 colunas | Dia da semana | `fato_chamadas[dia_semana_nome]` (igual) |
| 3 | Lista suspensa | Opção do menu | `fato_chamadas[ura_opcao]` |
| 4 | Blocos | Unidade | `dim_ramal[unidade]` |
| 5 | Lista suspensa | Setor | `dim_ramal[setor_grupo]` |
| 6 | Lista alta | Ramal | `dim_ramal[ramal]` |

Saíram Desfecho, Faixa de duração e Transferida: não foram pedidos, são cortes técnicos e o painel só tem
seis slots. O intervalo de dias fica no slicer de Data da própria página (fora do painel), e o Mês
completa o pedido de "mês e dia". Unidade, Setor e Ramal continuam tirando do filtro as ligações sem ramal
(ver o aviso abaixo). Os critérios da versão anterior seguem valendo para o que ficou.

**Critério da escolha (versão anterior):** o painel cobre o que os visuais da página não filtram por clique. A opção da
URA, o resultado da URA, o setor e a hora já se filtram clicando na tabela, na rosca e no mapa de calor.
Dia da semana, desfecho, faixa de duração e transferida não estão em nenhum visual clicável. Os três
primeiros são de comportamento da ligação, e os dois últimos (Unidade e Setor) são de "quem atendeu", e
ficam juntos no fim do painel de propósito.

**Unidade e Setor tiram do filtro as ligações sem ramal.** Elas vêm da `dim_ramal`, e ligação não
atendida não tem ramal, então ao escolher um setor sobram só as ligações que ele atendeu. Com "Relacionamento"
marcado, NÃO ATENDIDAS vai a zero e % ATENDIMENTO vai a 100%. Não é erro: é a pergunta "o que este setor
atendeu". Limpe os dois antes de olhar as não atendidas. O mesmo vale para o clique na tabela de setores
(seção 4). Os dois também são em cascata: escolher uma unidade já reduz a lista de setores.

**Campos avaliados e descartados:**

- `numero_chamado` (era o slicer da primeira versão): 56 números de telefone crus, e a linha
  principal concentra 59% das entradas. Sem de-para de nome, não diz nada a quem lê a página.
- `rota_entrada`: códigos crus (88830015, 88810, 88860) e uns lixos de poucas ligações. Mesmo problema.
- `e_ruido` e `atendida`: parte das medidas fixa essas condições (`[Ligações Entrada Atendidas]`
  fixa `atendida = TRUE` e `direcao = "Entrada"`, por exemplo) e parte não (`[Ligações Entrada]` só
  fixa a direção). Um slicer sobre elas faria os cartões se contradizerem: ATENDIDAS ignoraria a
  escolha e ENTRADAS obedeceria. Para filtrar por atendida, use o Desfecho "Atendida".
- `tipo_transferencia`: 99,6% é "CEGA".
- `passou_ura`: a rosca da URA já responde.
- `e_dia_util`: o dia da semana cobre.
- `ramal`: 26 ramais atenderam, e vale mais olhar pelo setor. Fica de reserva para auditoria.

"Origem cancelou" só existe em saída e interna (0 entradas), então marcar essa opção esvazia a
página de entradas. Não é erro.

## Como a página explica os próprios critérios (13/out/2026)

Quem vê a página pela primeira vez pergunta o que é ruído, por que a taxa não bate com a do painel da
MDnet e o que a espera inclui. A resposta fica na tela, em quatro camadas, da mais rápida para a mais
completa:

1. **Subtítulo em cada visual** (propriedade nativa Subtítulo, sem medida). Uma linha de critério:
   - Entradas por mês: "Cinza = ruído: robocall e spam que ninguém atendeu. Passe o mouse na coluna."
   - Taxa de atendimento: "Sem ruído = atendidas ÷ entradas sem ruído. Bruta = a do painel da MDnet."
   - Rosca da URA total: "Todas as ligações que passaram pela URA, por desfecho."
   - Rosca da URA atendidas: "Só as ligações atendidas que passaram pela URA."
2. **Nomes de série em português claro**, renomeados no poço do visual (clique duas vezes no campo; a
   medida não muda): "Atendidas", "Não atendidas (pessoas)", "Ruído (robocall e spam)" no gráfico de
   colunas, e "Bruta (painel MDnet)" e "Sem ruído (real)" no de linhas.
3. **Tooltip do gráfico "Entradas por mês"** (seção abaixo): passar o mouse numa coluna mostra o ruído
   daquele mês, o que ele faz com a taxa e como foi identificado.
4. **Painel "Como ler esta página"**, aberto por botão: o glossário completo, com números ao vivo.
   Medida `[Critérios Telefonia HTML]` (pasta `Telefonia\Critérios`). Nove critérios: entradas, atendida,
   não atendida, ruído, % atendimento, espera, URA, setor e ramal, origem e atualização dos dados.

Montagem do painel (o mesmo mecanismo de indicadores do painel de Filtros):

1. Um retângulo de fundo e um visual **HTML Content** por cima, com `[Critérios Telefonia HTML]` em
   Values. Sem Granularity e sem Stylesheet: o CSS vem dentro da medida. Em Formatar, desligue título,
   fundo e borda do visual.
2. Um botão X (fechar) no canto do painel. Agrupe retângulo, visual e botão.
3. Dois indicadores na página, só com Exibição e Página atual ligados: "Critérios aberto" (grupo
   visível) e "Critérios fechado" (grupo oculto no Painel de seleção).
4. Um botão "Critérios" no cabeçalho, com ação do indicador "aberto", e o X com o "fechado".

O tamanho do texto é todo em `em`, a partir do `font-size:16px` da classe `.g` na medida. Numa tela
grande o texto sai pequeno: aumente esse número (por exemplo, 36px) e deixe o visual com cerca de dois
terços da largura da página. O painel mostra o período e os filtros da página, então o número que o
leitor vê no painel é o mesmo do cartão.

Referência dos números (período inteiro, 01/01 a 31/10/2026): 21.465 entradas, 5.175 atendidas, 11.294
não atendidas e 4.996 de ruído (23,3%), com a conta fechando (diferença zero). A taxa real é 31,4% e a
bruta 24,1%.

### Roteiro de perguntas prováveis, com as respostas e os números

- **"Por que a taxa não bate com a do painel da MDnet?"** O painel mostra a bruta (24,1% no período). A
  página mostra a real (31,4%) e escreve a bruta no subtítulo do cartão. Para conferir com o painel,
  olhe a bruta. Em agosto, 32,0% contra 15,7%.
- **"Quem decidiu o que é ruído?"** Duas regras objetivas (formato internacional; ou o mesmo número
  ligando 10 vezes ou mais no mês, com 3% ou menos de atendimento e ligações de até 10 s). Os limites
  foram escolhidos na construção e ficam no SQL (`sql/gold/mdnet.sql`, repetidos em `e_ruido` e em
  `motivo_ruido`: ao ajustar, mude nos dois). Dá para mudar se a operação discordar.
- **"E se um cliente de verdade foi marcado como ruído?"** Ligação atendida nunca é ruído (nenhuma
  atendida está marcada). O corte de duração separa robocall (a linha cai em segundos) de cliente
  insistindo (espera dezenas de segundos). E o ruído é marcado, não apagado: continua visível, em cinza,
  na coluna.
- **"Por que o ruído é tão grande?"** Pouca gente gera muito: a regra de repetição, que é 69% do ruído
  (3.437 ligações), vem de cerca de 66 números. Agosto teve uma onda: 1.155 ligações de ruído em 2.260
  entradas (51%), e um único número ligou 546 vezes. Março: 1.278 de 3.271 (39%). Setembro: 385 de
  1.513 (25%). O tooltip mostra isso mês a mês.
- **"Por que setor e ramal só valem de fevereiro?"** Em janeiro, 92% das atendidas não têm ramal: a
  MDnet registrava o atendimento pelo número chamado.
- **"A espera inclui a URA?"** Sim. É o tempo desde que a ligação entra até ser atendida, então o piso
  já é de dezenas de segundos.
- **"Os dados estão atualizados?"** A carga roda de hora em hora, das 06:15 às 18:15. O painel web é em
  tempo real e pode estar alguns minutos à frente.

## Como o ruído é definido

Marca ligação de **entrada não atendida** que cai numa de duas regras:

1. a origem está em formato internacional (`00...`), que no CDR é telemarketing de São Paulo
   escrito como `00 55 11 ...`;
2. a mesma origem liga 10 vezes ou mais no mês, com 3% ou menos de atendimento **e** duração média
   de até 10 segundos.

O corte de duração é o que separa robocall (a linha cai em segundos) de cliente de verdade
insistindo (espera dezenas de segundos e ninguém atende). Sem ele, a contagem pura apagaria
justamente os clientes com a pior experiência do mês. Ligação **atendida nunca é ruído**. A flag
marca e não apaga, e cada medida de entrada existe nas duas versões.

### Tooltip do gráfico "Entradas por mês" (explica o ruído ao passar o mouse)

Uma página de tooltip com um visual HTML Content em tela cheia. As medidas estão no fim de
`MEDIDAS_TELEFONIA.dax` (pasta `Telefonia\Tooltip do ruído`) e o texto mostrado muda com o mês sob
o mouse: quanto foi de ruído, o que ele faz com a taxa (bruta contra sem ruído), quantas
ligações caíram em cada regra e o retrato (números diferentes, duração média, número mais
insistente).

1. **Nova página** com o nome `Tooltip Ruído`. Em Formatar a página: *Informações da página* ->
   ligar **Permitir uso como dica de ferramenta**. Em *Tamanho da tela*: Tipo **Personalizado**,
   largura **640**, altura **700**. *Plano de fundo da tela*: branco, transparência 0.
2. Ainda nessa página, esconda-a da navegação (botão direito na aba -> Ocultar página).
3. Inserir o visual **HTML Content**, em 0,0 e do tamanho da página (640 x 700). Campo
   **Values**: `[Tooltip Ruído HTML]`. Em Formatar, desligar o *Título*, o *Plano de fundo* e a
   *Borda*. Nenhum Granularity e nenhum Stylesheet: o CSS vem dentro da própria medida.
4. Na página `Telefonia`, selecionar o gráfico de colunas -> Formatar visual -> aba **Geral** (não a
   Visual) -> *Dicas de ferramenta*: ligar a chave, e só então aparecem o Tipo (**Página de
   relatório**) e a Página (**Tooltip Ruído**). Se a lista de páginas vier vazia, a página de tooltip
   está sem *Permitir uso como dica de ferramenta* ligado (passo 1). Num Desktop com o painel de
   formatação antigo, o cartão fica no fim da lista do próprio visual.
5. Passar o mouse numa coluna. Em março e agosto o ruído é grande (1.278 e 1.155), e em
   agosto um único número ligou 546 vezes no mês, o que o tooltip mostra no retrato.

Limites do Power BI: o tooltip some quando o mouse sai da coluna e não aceita clique, e o
visual HTML Content não executa JavaScript. O movimento (barras crescendo, linhas surgindo em
sequência) é CSS puro. Não é possível mostrar um tooltip diferente por segmento da coluna, porque
o contexto que chega é só o mês. Tamanho: tudo é em `em` a partir de `font-size:16px` na classe
`.t`, então para um tooltip maior ou menor mude esse número e o tamanho da página.

## O que não está aqui, e por quê

**Atingimento de SLA.** Não há meta de tempo de atendimento definida. Quando houver, vira uma
medida sobre `espera_s`, ao lado de `[% Atendidas em até 1 min]`, que é só um corte de exemplo.

**Telefone do cliente.** O CDR traz o número de quem ligou e a gold não o repassa: a fato tem
`chamador_id`, um identificador derivado, que basta para contar clientes distintos e quem insiste.
Se a operação precisar ligar de volta para quem não foi atendido, a lista sai da silver, com
acesso controlado, e não de um visual.

**Histórico dos menus antigos da URA.** O painel só mostra a configuração atual. As 245
ligações do menu antigo de agosto aparecem como "fora da URA" e só existem no CSV de 30/08 que
alguém guardou. A carga horária da VM passa a acumular o que o painel mostrar daqui para a frente.

## Conferência antes de publicar

Antes de abrir o Power BI, rode `python conferir_mdnet.py --de 2026-01-01 --ate 2026-10-05 --gold`:
a fato tem que ter o mesmo número de linhas da silver real, nenhum ramal pode ficar sem linha na
dimensão e nenhuma ligação atendida pode estar marcada como ruído. Depois filtre a página numa
janela fechada e compare com `--silver --ura`. Para setembro/2026, os números da gold são:

| | Valor |
|---|---|
| Entradas | 1.513 |
| Atendidas | 214 (14,1% bruto) |
| Ruído | 385 |
| % Atendimento real | 19,0% |
| Entraram na URA | 1.012 (196 atendidas) |

E para agosto/2026: 2.260 entradas, 354 atendidas (15,7% bruto), 1.155 de ruído e 32,0% de
atendimento real. O painel web da MDnet mostra a taxa bruta, então compare com ela.

## Conferência com o painel web

O painel web da MDnet (Relatórios > Registro de chamadas) tem cartões, e a página de Telefonia tem que
bater com eles, **no mesmo período e na mesma hora**. Para conferir:

1. Atualize o Power BI (Atualizar) logo depois de uma carga. A carga roda de hora em hora, das 06:15 às
   18:15, então o painel web está sempre alguns minutos à frente do banco.
2. Rode `python conferir_mdnet.py --de AAAA-MM-DD --ate AAAA-MM-DD --gold`, com o mesmo período do painel. A
   primeira tabela reproduz os cartões do painel e põe a fato da gold ao lado.

O que o Power BI mostra e o painel mostra, e por que cada diferença existe:

| Cartão do painel | Medida do Power BI | Bate? | Por quê |
|---|---|---|---|
| TOTAL ENTRADA | `Ligações Entrada` | Sim | A fato segue a regra do painel: com perna de entrada, é Entrada |
| ATENDIDA (entrada) | `Ligações Entrada Atendidas` | Sim | Estado da perna de entrada |
| NÃO ATENDIDA (entrada) | `Ligações Entrada Não Atendidas` | Sim | Inclui o ruído, como o painel |
| (faixa de KPIs) NÃO ATENDIDAS | `Ligações Entrada Não Atendidas Reais` | **Não, de propósito** | Tira o ruído: 16.137 do painel = 11.135 reais + 4.937 de ruído, menos as diferenças de carga |
| CAPILARIDADE DA ENTRADA | `Capilaridade da Entrada` | Quase | A gold agrupa variantes do mesmo telefone e conta cerca de 1% a menos |
| TOTAL SAÍDA | `Ligações Saída` | Total sim, atendidas **não** | O total do painel bate com a regra do painel (1.064). As **atendidas** não: o painel mostra 251 e o estado da perna de saída diz 514. Testado em 07/out/2026 com dois períodos: até 30/04 o painel mostra 135 de 488 e a perna diz 246; de 01/05 em diante, 116 de 576 contra 268. Não é corte por data, nem tempo falado, nem lado que desligou, e nenhuma regra simples dos campos do CDR reproduz o painel. A nossa conta (estado da perna, 93% com desligamento normal e mediana de 65 s de conversa) é a que usamos, e a pergunta fica para a MDnet |
| TOTAL INTERNA | `Ligações Internas` | **Não, de propósito** | O painel conta 1.055 pernas de transferência e 440 recursos do PABX (captura de chamada *8); a fato só tem interna real |
| CHAMADAS TOTAIS | (sem medida) | **Não, de propósito** | Soma tudo, inclusive recurso e perna de transferência |
| OCUPAÇÃO MÁXIMA | (sem medida) | Não existe | Pico de ligações simultâneas, ainda não calculado |

**A divergência corrigida em 07/out/2026.** A primeira versão da Gold lia a direção pela perna que o CSV
mostra. O CSV sem filtro mostra uma perna só por ligação, e às vezes é a perna errada: uma ligação que
entrou, foi atendida e foi encaminhada para um número de fora aparece como "Saída". Eram 52 ligações
reais lidas como Saída e 8 como Interna (em 05/out), o que deixava a Entrada do Power BI **44 abaixo** do
painel e as atendidas **43 abaixo** (0,8%). Agora a fato segue a regra do painel, e Entrada, Atendidas e
Não atendidas fecham com os cartões (21.151, 5.105 e 16.046 na carga de 05/out, igual ao painel).
Quase todas essas ligações são de janeiro, quando a MDnet registrava o atendimento por número externo.

**A diferença que sobra é de relógio.** O painel web é em tempo real e o Power BI mostra o que foi
carregado até a última atualização. Em 07/out às 10h o painel mostrava 21.266 entradas e o Power BI 21.144,
uma diferença que a correção acima explica em 44 e o relógio em mais de 80 (a atualização do Power BI era
de 06/out por volta das 11h).

Uma diferença que não é erro: a `direcao` de Saída e de Interna da gold continua sendo a nossa leitura,
sem recurso do PABX nem perna de transferência.
