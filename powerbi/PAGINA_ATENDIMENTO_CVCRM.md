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
└──────────────────────────────────────────────────────────────────────┘
```

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
