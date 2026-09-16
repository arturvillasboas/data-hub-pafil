# Página "Atendimento (CVCRM)"

Sobre `gold.fato_atendimentos_cvcrm`. As medidas estão em
[MEDIDAS_ATENDIMENTO_CVCRM.dax](MEDIDAS_ATENDIMENTO_CVCRM.dax).

**Não confundir com a página "Atendimento" já existente**
([PAGINA_ATENDIMENTO.md](PAGINA_ATENDIMENTO.md)), que é o chat de WhatsApp via
Blip. Esta página é o módulo de protocolo/ticket de pós-venda do próprio
CVCRM — assistência técnica, financeiro, renegociação de contrato — um
domínio diferente, sem nenhuma relação entre os dois fatos hoje. Ver DP-17 em
`REGRAS_NEGOCIO.md` para como o endpoint foi descoberto e integrado.

## Antes de montar

**O volume ainda é muito baixo para valer um layout cheio de gráficos**: o
ambiente `pafil` tem hoje só 10 atendimentos no total (não é amostra — é a
população inteira, conferida direto na API). Com esse tamanho, qualquer
gráfico de série temporal ou ranking vai ter uma ou duas barras. Por isso o
layout abaixo é deliberadamente enxuto — uma faixa de KPIs e uma tabela de
detalhe — em vez de replicar o layout cheio da página de Blip. Ele foi
desenhado para crescer: as mesmas medidas e a mesma tabela detalhe continuam
válidas quando o volume aumentar, e é aí que valem visuais de tendência
(criados x finalizados por mês, ranking por empreendimento/assunto).

**HTML/CSS desde já, por decisão do dev** (16/set/2026): mesmo com volume
baixo, a faixa de KPIs e a tabela de detalhe usam HTML Content, na mesma
linguagem visual das páginas de Blip e Performance (fonte, azul `#003254`,
cantos arredondados) — para a página já nascer com a cara do resto do
relatório, em vez de precisar de um retrabalho de estilo quando o volume
crescer. As medidas HTML estão na seção "HTML/CSS" de
`MEDIDAS_ATENDIMENTO_CVCRM.dax`.

Confirme que a `dim_calendario` cobre o mês corrente antes de montar
(mesmo aviso da página de Blip: relacionamento de data "quebrado" por range
não dá erro nenhum, só fica tudo em branco).

## Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. Faixa de KPIs (HTML Content, 7 cartões)                          │
├──────────────────────────────────────────────────────────────────────┤
│  2. Slicers: Empreendimento · Situação · Assunto · Prioridade        │
├──────────────────────────────────────────────────────────────────────┤
│  3. Tabela de detalhe (HTML Content, 1 linha por atendimento)        │
├──────────────────────────────────────────────────────────────────────┤
│  4. Esteira (HTML Content, kanban — réplica da tela nativa do CVCRM) │
└──────────────────────────────────────────────────────────────────────┘
```

A esteira (seção 4) é opcional e pode virar uma página separada se a página
principal ficar muito cheia — ela replica uma tela inteira do CVCRM
("Andamento dos atendimentos"), então tem uma pegada visual própria, diferente
da faixa de KPIs + tabela.

## 1. Faixa de KPIs

**Visual:** HTML Content. **Medida:** `[KPIs Atendimento CVCRM HTML]`.

Sete cartões: TOTAL, EM ABERTO (cinza), FINALIZADOS, CANCELADOS (vermelho),
TX CANCELAMENTO (vermelho), TEMPO DE FINALIZAÇÃO, AVALIAÇÃO. As cores seguem
a mesma convenção da faixa de Blip: vermelho é a métrica que dói (cancelado
custa tempo de atendente e frustra cliente), cinza é a única foto do
momento em vez de medida do período.

Dois cuidados de leitura:

- `[Atendimentos Em Aberto]` (dentro da medida HTML) é uma foto do momento
  (`REMOVEFILTERS` no calendário), igual ao cartão equivalente da página de
  Blip — não soma com Finalizados + Cancelados dentro de um período filtrado.
- `[Tempo Médio de Finalização (dias)]` e `[Avaliação Média]` mostram "--"
  quando não há nenhum atendimento finalizado/avaliado no filtro corrente
  (hoje só 1 dos 10 tem avaliação) — não é erro de relacionamento, e o
  cartão de avaliação sempre mostra quantos atendimentos entraram na média,
  já que 1 avaliação isolada não é a mesma confiança que 50.

## 2. Slicers

Quatro slicers simples, lado a lado: `fato_atendimentos_cvcrm[empreendimento]`,
`[situacao]`, `[assunto]`, `[prioridade]`. Não use `[origem]` como slicer de
negócio: é um código de 2 letras (ex.: "PC"/"GE") que por enquanto parece
indicar como o ticket foi aberto (painel do cliente vs. gestor), não canal de
marketing — não tem de-para ainda e não deve ser confundido com a origem/mídia
de leads (domínio diferente, ver `gold.dim_origem`).

## 3. Tabela de detalhe (com clique)

**Visual:** HTML Content, configurado para o clique numa linha filtrar o
resto da página (igual à tabela do Blip) — o que exige o campo Granularity
preenchido, e não só Values. Sem Granularity, o visual recebe o HTML inteiro
de uma vez, como um texto único, e clicar não faz nada; é a diferença entre
esta versão e a tabela estática que veio antes dela.

Configuração do visual:

| Campo | Valor |
|---|---|
| Values | `[Linha Atendimento CVCRM HTML]` |
| Granularity | `fato_atendimentos_cvcrm[id_atendimento]` |
| Tooltips | `[Data do Atendimento CVCRM (ordenação)]` |
| Classificar por | Data do Atendimento CVCRM (ordenação), decrescente |
| Formatar > Stylesheet > fx | `[CSS Tabela Atendimentos CVCRM]` |
| Formatar > Cross-filtering | Ativar, Transparency 0 |
| Formatar > No data message | "Nenhum atendimento no período selecionado." |

Colunas: protocolo, data, empreendimento, cliente, assunto, situação (com
selo colorido: vermelho para Cancelado, verde para Finalizado, cinza para as
demais), equipe e avaliação.

**Por que Granularity é o campo `id_atendimento`, e não `protocolo`:** é a
chave técnica do grão do fato — uma linha da tabela é sempre um atendimento,
nunca dois com o mesmo id, então o clique nunca ambiguiza qual registro foi
selecionado. `protocolo` até funcionaria hoje (também é único), mas
`id_atendimento` é a chave de verdade do modelo.

Com 10 linhas, a tabela de detalhe carrega mais peso analítico do que os
cartões — é nela que a gestão consegue de fato ler cada ticket, o que os
agregados ainda não sustentam sozinhos. E com o clique ativo, selecionar uma
linha já filtra a faixa de KPIs pra aquele atendimento específico — útil pra
conferir um caso pontual sem sair da página.

## 4. Esteira (kanban)

Réplica da tela nativa "Andamento dos atendimentos" do CVCRM: 6 colunas fixas,
**na ordem certa agora** (Novo Atendimento → Triagem → Time Cobrança → Time
Atendimento → Time Crédito → Em Atendimento — o `ASC` por nome da primeira
versão embaralhava isso alfabeticamente, corrigido), cabeçalho na cor da
paleta de KPIs (azul `#003254` na primeira coluna, vermelho `#8A1C1C` nas
demais — mesma paleta da faixa de KPIs da seção 1, pedido de harmonia
visual), e um cartão por atendimento com protocolo, cliente, bloco/unidade +
empreendimento, assunto/subassunto e um rodapé "+ INFORMAÇÕES". Cancelado e
Finalizado ficam de fora — a tela nativa mostra o que está em andamento, não
o histórico encerrado. Fontes bem maiores que o resto do arquivo, calibradas
pro tamanho real desta página (4500×3800) e deste visual (4253 de largura ×
876 de altura, ~708px por coluna).

**Passe o mouse sobre um cartão** para expandir um bloco de estatísticas —
CRIADO HÁ, NA SITUAÇÃO, INTERAÇÕES, ÚLT. ATUALIZAÇÃO —, inspirado na tela
expandida que você mandou de exemplo. As três linhas de "VENCIMENTO DE SLA"
daquele print (por assunto/subassunto/workflow) **não entraram**: a API do
CVDW não expõe prazo de SLA em nenhum dos 60 campos de `atendimentos` — é
cálculo interno do CVCRM que não sai no endpoint. Mostrar essas datas seria
inventar dado; se a gestão precisar delas, é um pedido de campo novo pro
CVCRM, não algo que o pipeline resolve sozinho.

**⚠️ Atenção antes de confiar nesta seção:** as 6 colunas são valores
esperados do campo `fato_atendimentos_cvcrm[situacao]`, só que **só um deles
foi confirmado de verdade** contra o banco — "Em Atendimento", que já existe
num dos 10 registros de hoje. Os outros cinco nomes (Novo Atendimento,
Triagem, Time Cobrança, Time Atendimento, Time Crédito) foram copiados da
captura de tela que você mandou, mas nunca apareceram nos dados: é uma aposta
de que são valores de `situacao`, não uma confirmação. Se algum atendimento
passar por uma dessas etapas e a coluna dele continuar vazia, o texto exato
provavelmente diverge — corrija a grafia direto na tabela `Esteira Colunas`
(coluna `situacao`). É possível também que "Time Cobrança"/"Time
Atendimento"/"Time Crédito" não sejam 3 valores de `situacao`, e sim uma
combinação de situação com a equipe (`fato_atendimentos_cvcrm[equipe]`) —
sem um atendimento real nessas etapas pra conferir, não dá pra saber qual
das duas é.

### Sobre o clique: filtra por COLUNA (situação), não por cartão individual

Foi pedido clique que filtre a página igual à tabela de detalhe — mas manter
as 6 colunas sempre visíveis (mesmo com 0 atendimentos, que é o caso de 5 das
6 hoje) e ter clique por CARTÃO individual são **tecnicamente incompatíveis**
neste visual: o HTML Content só cross-filtra quando o campo Granularity tem
uma linha por "coisa clicável", e se essa linha fosse por cartão
(`id_atendimento`), uma coluna sem nenhum atendimento não teria nenhuma linha
pra existir — o visual mostraria só a mensagem genérica de "sem dados" no
lugar, sem cor, sem cabeçalho, sem "0 Registro(s)". Esse caminho foi testado
primeiro e descartado por isso.

A solução foi Granularity por COLUNA: clicar em qualquer lugar de uma coluna
(cabeçalho ou fundo, em qualquer cartão dentro dela) seleciona aquela
situação inteira e filtra o resto da página — inclusive a faixa de KPIs e a
tabela da seção 3. Pra clique por atendimento individual, a tabela de
detalhe da seção 3 já resolve isso.

**Passo a passo pra montar (precisa de duas coisas novas no modelo, não só
colar medida):**

1. **Criar a tabela de apoio:** Modelagem → Nova tabela → cole o conteúdo de
   `Esteira Colunas` (é uma DATATABLE, 6 linhas: situação, tema de cor,
   ordem). Não é medida — não cole como "Nova medida".
2. **Criar o relacionamento:** Modelagem → Gerenciar relacionamentos → Nova:
   `'Esteira Colunas'[situacao]` (lado 1) → `fato_atendimentos_cvcrm[situacao]`
   (lado vários). Direção do filtro: única (padrão).
3. Colar as medidas `Ordem Esteira CVCRM (ordenação)`, `Coluna Esteira CVCRM
   HTML` e `CSS Esteira Atendimentos CVCRM` na pasta `Atendimento CVCRM`,
   igual às outras.
4. Configurar o visual HTML Content:

| Campo | Valor |
|---|---|
| Values | `[Coluna Esteira CVCRM HTML]` |
| Granularity | `'Esteira Colunas'[situacao]` |
| Tooltips | `[Ordem Esteira CVCRM (ordenação)]` |
| Classificar por | Ordem Esteira CVCRM (ordenação), crescente |
| Formatar > Stylesheet > fx | `[CSS Esteira Atendimentos CVCRM]` |
| Formatar > Cross-filtering | Ativar, Transparency 0 |
| Formatar > No data message | (deixe em branco — com a tabela de apoio, o Granularity nunca fica vazio, então essa mensagem nunca aparece) |

## Pendências conhecidas

- `id_corretor`/`corretor` vêm vazios nos 10 registros de hoje — sem
  relacionamento com `dim_corretor` por ora (ver nota no `gold.sql`). Ligar
  quando o campo passar a vir preenchido.
- Unidade de `tempo_resposta`/`tempo_finalizado` (segundos) é inferida, não
  confirmada pela documentação da API — conferir contra a tela do CVCRM assim
  que houver um caso real pra comparar.
- `origem` (2 letras) e `canal` (Telefone/Email/Whatsapp) ainda não têm
  de-para nem página de referência — expostos crus, prontos pra virar slicer
  quando fizer sentido de negócio.
