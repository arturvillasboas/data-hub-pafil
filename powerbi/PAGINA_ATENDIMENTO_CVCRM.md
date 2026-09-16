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
layout abaixo é deliberadamente enxuto — uma faixa de números e uma tabela de
detalhe — em vez de replicar o layout cheio da página de Blip. Ele foi
desenhado para crescer: as mesmas medidas e a mesma tabela detalhe continuam
válidas quando o volume aumentar, e é aí que valem visuais de tendência
(criados x finalizados por mês, ranking por empreendimento/assunto).

Confirme que a `dim_calendario` cobre o mês corrente antes de montar
(mesmo aviso da página de Blip: relacionamento de data "quebrado" por range
não dá erro nenhum, só fica tudo em branco).

## Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. Faixa de cartões (Total, Em Aberto, Finalizados, Cancelados,     │
│     Taxa de Cancelamento, Tempo Médio de Finalização, Avaliação)     │
├──────────────────────────────────────────────────────────────────────┤
│  2. Slicers: Empreendimento · Situação · Assunto · Prioridade        │
├──────────────────────────────────────────────────────────────────────┤
│  3. Tabela de detalhe (1 linha por atendimento)                      │
└──────────────────────────────────────────────────────────────────────┘
```

## 1. Faixa de cartões

**Visual:** cartões simples (Card / New Card), um por medida — sem HTML
Content por ora. Com 10 registros no total, uma faixa HTML com CSS dedicado
(como a de Performance ou a de Blip) seria trabalho de estilização sem público
proporcional ainda; migrar para HTML quando o volume justificar.

Medidas, na ordem: `[Total Atendimentos]`, `[Atendimentos Em Aberto]`,
`[Atendimentos Finalizados]`, `[Atendimentos Cancelados]`,
`[Taxa de Cancelamento]`, `[Tempo Médio de Finalização (dias)]`,
`[Avaliação Média]`.

Dois cuidados de leitura:

- `[Atendimentos Em Aberto]` é uma foto do momento (`REMOVEFILTERS` no
  calendário), igual ao cartão equivalente da página de Blip — não soma com
  Finalizados + Cancelados dentro de um período filtrado.
- `[Tempo Médio de Finalização (dias)]` e `[Avaliação Média]` ficam em branco
  quando não há nenhum atendimento finalizado/avaliado no filtro corrente
  (hoje só 1 dos 10 tem avaliação) — não é erro de relacionamento.

## 2. Slicers

Quatro slicers simples, lado a lado: `fato_atendimentos_cvcrm[empreendimento]`,
`[situacao]`, `[assunto]`, `[prioridade]`. Não use `[origem]` como slicer de
negócio: é um código de 2 letras (ex.: "PC"/"GE") que por enquanto parece
indicar como o ticket foi aberto (painel do cliente vs. gestor), não canal de
marketing — não tem de-para ainda e não deve ser confundido com a origem/mídia
de leads (domínio diferente, ver `gold.dim_origem`).

## 3. Tabela de detalhe

**Visual:** Table, ordenada por `data_cad` decrescente.

Colunas sugeridas: `protocolo`, `data_cad`, `empreendimento`, `cliente`,
`assunto`, `subassunto`, `situacao`, `prioridade`, `equipe`, `responsavel`,
`data_finalizado`, `avaliacao`.

Com 10 linhas, a tabela de detalhe carrega mais peso analítico do que os
cartões — é nela que a gestão consegue de fato ler cada ticket, o que os
agregados ainda não sustentam sozinhos.

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
