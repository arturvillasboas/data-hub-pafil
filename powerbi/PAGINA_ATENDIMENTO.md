# Página "Atendimento" (Blip)

Réplica das telas do painel nativo do Blip, sobre `gold.fato_atendimentos`. As
medidas estão em [MEDIDAS_ATENDIMENTO.dax](MEDIDAS_ATENDIMENTO.dax).

A página existe por dois motivos. O primeiro é tirar a gestão de dentro do
painel do Blip, que ninguém acompanha porque vive em outra ferramenta. O
segundo é o que o painel nativo não faz: cruzar atendimento com empreendimento,
e no futuro com venda e lead, já que as dimensões são as mesmas do resto do
modelo.

## Antes de montar

Confirme que a `dim_calendario` cobre o mês corrente. Se ela terminar antes, os
relacionamentos de data continuam existindo, o Power BI não reclama de nada, e
todo visual por dia vem vazio. É o erro mais caro de diagnosticar aqui.

## Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. Faixa de KPIs (HTML Content)                                     │
├────────────────────────────────────┬─────────────────────────────────┤
│  2. Criados x Fechados por dia     │  3. Tickets por situação        │
│     (gráfico de linhas)            │     (barras horizontais)        │
├────────────────────────────────────┴─────────────────────────────────┤
│  4. Tabelas de corte (HTML): atendente, fila, empreendimento         │
├──────────────────────────────────────────────────────────────────────┤
│  5. Rodapé de qualidade do dado (dois cartões pequenos)              │
└──────────────────────────────────────────────────────────────────────┘
```

## 1. Faixa de KPIs

**Visual:** HTML Content (o mesmo já usado nas outras páginas).
**Medida:** `[KPIs Atendimento HTML]`.

Oito cartões, no mesmo CSS da faixa de Performance. As cores não são
decorativas: o par vermelho é o de abandono, que é a métrica que dói, e o cinza
é o único cartão que mostra uma foto do momento em vez de uma medida do
período.

Isso importa na leitura: filtrar a página para "agosto" muda os sete cartões e
**não** muda "EM ABERTO", porque ticket em aberto não tem data de fechamento e
não pertence a mês nenhum. Vale deixar isso claro para quem for usar a página,
ou alguém vai reportar como bug.

## 2. Criados x Fechados por dia

**Visual:** Gráfico de linhas.
**Eixo X:** `dim_calendario[data]`.
**Valores:** `[Tickets Criados]` e `[Tickets Fechados]`.

Linha, e não coluna, porque a leitura aqui é de ritmo ao longo do tempo, não de
comparação entre categorias. As duas séries juntas mostram se a operação está
dando conta: quando a linha de criados fica sistematicamente acima da de
fechados, a fila está crescendo.

`[Tickets Criados]` usa `USERELATIONSHIP` para passar pela data de criação, já
que o relacionamento ativo é o de fechamento. Isso já está dentro da medida,
não precisa fazer nada no visual.

## 3. Tickets por situação

**Visual:** Gráfico de barras empilhadas horizontal.
**Eixo Y:** `fato_atendimentos[situacao]`.
**Valores:** contagem de `sequential_id`.

Barra horizontal em vez de rosca porque são seis categorias com nomes longos, e
rosca com seis fatias vira legenda ilegível. Se a gestão preferir a leitura de
proporção, troque para barras 100% empilhadas em vez de rosca.

## 4. As tabelas de corte

São as três abas do painel (Atendentes, Filas, Tags). Há dois caminhos, e eles
resolvem problemas diferentes.

### Caminho principal: as três tabelas em HTML

**Visual:** HTML Content, um para cada.
**Medidas:** `[Tabela Atendentes HTML]`, `[Tabela Filas HTML]`,
`[Tabela Empreendimentos HTML]`.

As três compartilham `[CSS Tabela Atendimento]`, então ajuste de estilo entra
num lugar só. Três coisas que a tabela HTML entrega e a matriz nativa não:

- **Ordenação por quantidade que funciona de verdade.** Acontece no DAX, sobre
  o número. Na matriz nativa, ordenar por uma coluna de tempo cai no texto
  formatado e coloca `09:00:00` depois de `10:00:00`.
- **Barra de volume atrás da quantidade**, proporcional ao maior da tabela.
- **Cabeçalho fixo ao rolar**, e largura de coluna que não depende de ninguém
  arrastar nada.

Para reproduzir as abas do painel, coloque as três no mesmo lugar da página e
troque com indicadores (bookmarks) mais um navegador de indicadores.

A tabela de empreendimento cobre metade da aba "Tags" do painel, que é a metade
que interessa ao comercial. Para a outra metade, copie a medida trocando as duas
ocorrências de `'dim_empreendimento'[empreendimento]` por
`'fato_atendimentos'[motivo_encerramento]` e o cabeçalho para MOTIVO.

### Caminho alternativo: matriz nativa com parâmetro de campo

**Visual:** Matriz.
**Linhas:** a coluna de campos de `Seleção Corte Atendimento`.
**Slicer:** a coluna de texto do mesmo parâmetro.
**Valores:** `[Tickets Finalizados]`, `[Tempo Médio 1a Resposta]`,
`[Tempo Médio Espera Fila]`, `[Tempo Médio Resposta]`, `[Tempo Médio Atendimento]`.

Um visual só, com um slicer trocando a dimensão da linha, e sem indicador
nenhum para manter. Vale quando você quiser exportar os dados pelo menu do
visual ou fixar o visual num painel do Serviço, que a tabela HTML não permite.

Aqui a limitação da ordenação se aplica: deixe ordenando por
`[Tickets Finalizados]`, e se precisar ordenar por um tempo, acrescente a
medida `(seg)` correspondente ao visual.

## 5. Rodapé de qualidade do dado

**Visual:** dois cartões.
**Medidas:** `[% Tickets com Empreendimento]` e `[% Tickets sem Tag de Empreendimento]`.

Parecem detalhe e não são. O corte por empreendimento falha por omissão: ticket
cuja tag não casa com a de-para some do visual filtrado por produto, sem erro e
sem aviso. Estes dois cartões são a única coisa que denuncia isso.

As duas medem coisas diferentes. A segunda é atendente que não marcou a tag (na
base de setembro, 42% dos fechados). A primeira, quando fica abaixo do
complemento da segunda, é grafia do Blip que falta na de-para de
empreendimentos, e a correção é na planilha do backoffice, não no SQL. A view
`gold.blip_tags_sem_empreendimento` lista exatamente quais faltam.

## Slicers da página

`dim_calendario[data]` como intervalo, mais `dim_fila[fila_exibicao]`,
`dim_atendente[atendente]` e `fato_atendimentos[canal]`.

Vale acrescentar `dim_fila[cadastrada_no_blip]` e
`dim_atendente[cadastrado_no_blip]` como slicers escondidos de diagnóstico. Elas
marcam a fila ou o atendente que aparece nos tickets mas não no cadastro do
Blip, que é o caso da fila `DIRECT_TRANSFER` e de qualquer atendente desligado.

## O que não está aqui, e por quê

Duas telas do painel ficaram de fora por falta de fonte, não por decisão de
layout.

**Atingimento SLA.** A regra está configurada dentro do Blip e não é exposta por
nenhum endpoint da API. Assim que alguém informar qual é (tempo até primeira
resposta, qual limite, se varia por fila), ela vira uma medida calculada sobre
`ate_primeira_resposta_seg` e entra na matriz como mais uma coluna.

**Disponibilidade de atendentes.** O painel mostra tempo acumulado por estado
(Online, Em pausa, Invisível). A API só devolve o estado do instante, e não há
recurso de histórico, então não dá para reconstruir o passado. Exigiria um
coletor próprio de alta frequência, e ele só produziria dados daqui para frente.

## Conferência antes de publicar

Filtre a página numa janela fechada e compare com o painel do Blip na mesma
janela, cartão a cartão. Para 3 a 9 de setembro de 2026 os números do painel
eram 353 fechados, 341 finalizados, 12 abandonados, e os tempos 01:09:12,
00:11:12, 01:29:28, 01:11:06 e 10:23:43.

Uma diferença de forma que não é erro: acima de 24 horas o painel escreve
`1d 10:18` e as medidas daqui escrevem `34:18:00`. A escolha foi proposital,
porque valor monotônico ordena certo numa tabela e `1d 10:18` não.
