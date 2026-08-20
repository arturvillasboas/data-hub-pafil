# Marketing N1: como replicar a página na gold

Mapa visual a visual, ligando o PBIX legado (`BI V.2\BI Matriz\BI Matriz.pbix`,
página "Marketing N1") ao modelo novo ("Esteira de reservas"). Extraído do
`Report/Layout` do próprio `.pbix` legado (zip + JSON UTF-16, 90
visualContainers) em 19 de agosto de 2026, combinado com o DAX das 26 medidas
originais, puxado ao vivo via `powerbi-mcp` (não adivinhado a partir do nome).

As medidas novas ficam em `powerbi/PAGINA_MARKETING_N1_HTML.dax` — já criadas
no modelo vivo via XMLA (medida não mexe na camada de consultas, salva
normal). Este documento cobre só o que falta: os visuais nativos, que são
passo manual do Desktop (posicionar/formatar visual não dá pela API/TOM).

---

## 1. Fonte de dados nova: Metas Performance Digital.xlsx

Diferente do `Meta.xlsx` (que só cobre metas de venda/House, já usado em
`dim_metas_empreendimentos`), esta página depende de uma planilha separada do
time de marketing: `BI V.2\BI Matriz\Metas Performance Digital.xlsx`, aba
`Planilha1`, grão empreendimento x mês. Carregada por
`popular_seeds.py --metas-performance-digital` (env
`METAS_PERFORMANCE_DIGITAL_XLSX`) em `silver.d_metas_performance_digital` →
`gold.dim_metas_performance_digital`.

⚠️ **A tabela entrou no Desktop com um typo no nome**: `dim_metas_performace_digital`
(sem o "n" de "performance"). Todas as medidas do `.dax` referenciam esse nome
exatamente como está — se alguém renomear a tabela no Desktop pra corrigir o
typo, as medidas quebram e precisam ser atualizadas junto.

Cobertura: 312 das 480 linhas da planilha casaram com um `codigo_cv` da
`dim_empreendimento` (65%); as 168 restantes são produtos antigos/descontinuados
que não existem mais no CVCRM (Altier, Dualle, Trivion Home Resort, Villa das
Aroeiras, Condomínio Comercial Parc Sul, Parc Gramado, "Parc Paineras" com essa
grafia específica). Todos os empreendimentos ativos relevantes pra este ano
casaram normalmente.

---

## 2. Os 4 slicers dropdown (topo)

| Slicer legado | Campo novo | Observação |
|---|---|---|
| Empreendimento | `dim_empreendimento[empreendimento_conformado]` | |
| Regional | `dim_empreendimento[regional]` | |
| Assinatura | `dim_empreendimento[assinatura]` | Coluna nova (ago/2026) — só entra depois de fechar/reabrir o Desktop uma vez |
| Share | `fato_reservas[Share]` | Classificação oficial da venda (Vendas Consolidadas), não o Share do corretor |

## 3. Slicer de meses

No legado é um slicer horizontal em estilo "blocos" (`orientation: Horizontal`,
seleção única forçada), ligado a uma tabela oculta de Auto Date/Time. No modelo
novo, use `dim_calendario[mes_nome]` (já vem ordenado por `mes` — não precisa
criar tabela de data extra):

1. Segmentação → campo `dim_calendario[mes_nome]`.
2. Formatar → Estilo de segmentação → **Blocos** (tiles), orientação horizontal.
3. Formatar → Seleção → **Seleção única** ligado (`Single select` = On), sem
   opção "Selecionar tudo".

## 4. Os 9 cards de KPI

Já prontos na medida `[KPIs Marketing N1 HTML]` (visual HTML Content, mesmo
padrão de `[KPIs Leads HTML]`/`[KPIs Preço HTML]`). Ordem e fonte:

| # | Card | Medida "Realizado" | Medida "Meta" | Fonte da meta |
|---|---|---|---|---|
| 1 | Qtd Leads | `[Qtd Lead]` (já existia) | `[Meta Lead (Mkt N1)]` | `SUM(...[lead])` |
| 2 | MQL | `[Qtd MQL (Mkt N1)]` | `[Meta MQL (Mkt N1)]` | `SUM(...[mql])` |
| 3 | % Qualificação | `[Tx MQL (Mkt N1)]` | `[Meta Qualificação (Mkt N1)]` | `AVERAGE(...[pct_mql])` |
| 4 | Vendas House | `[Qtd Vendas House (Mkt N1)]` | `[Meta Vendas House (Mkt N1)]` | `SUM(...[meta_vendas_house])` |
| 5 | Vendas Marketing | `[Qtd Vendas Marketing (Mkt N1)]` | `[Meta Venda Marketing (Mkt N1)]` | `SUM(...[meta_vendas_mkt])` |
| 6 | Vendas Mkt House % | `[Vendas Marketing House % (Mkt N1)]` | `[Meta Vendas Marketing House % (Mkt N1)]` | `AVERAGE(...[pct_meta_venda_mkt])` |
| 7 | Vendas Digitais | `[Qtd Vendas Digital (Mkt N1)]` | `[Meta Venda Digital (Mkt N1)]` | `SUM(...[meta_vendas_digital])` |
| 8 | % Vendas Digitais House | `[% Vendas Digitais House (Mkt N1)]` | `[Meta Share Digital House (Mkt N1)]` | `AVERAGE(...[pct_meta_venda_digital])` |
| 9 | VGV | `[VGV Vendas Marketing (Mkt N1)]` | `[Meta VGV Marketing (Mkt N1)]` | fórmula própria (média VGV/reserva × meta de contagem, igual ao legado) |

⚠️ **Cuidado de nomenclatura, não confundir:** as medidas `[Qtd Lead Quali]` /
`[Tx_Qualif_Leads]` já existentes (pasta "Leads") foram redefinidas em
23/jul/2026 pra lógica por ETAPA da esteira, não são mais MQL — por isso os
cards MQL/% Qualificação desta página usam medidas próprias `(Mkt N1)`, com a
definição MQL original (`fato_leads["MQL 2"]="SIM"`).

**Popup de hover (CSS-only):** só nos cards **Vendas Marketing** e **VGV**,
quebrando em House x Parcerias (quantidade + VGV) — é o único par de cards
onde essa quebra faz sentido matemático (os outros 7 ou já são só House, ou
são taxas/percentuais). Passe o mouse sobre o card pra ver. Se quiser estender
a quebra pra outro card, ela precisa ser desenhada com um corte que faça
sentido pra aquela métrica específica — não dá pra copiar direto.

## 5. VGV por Empreendimento

Combo chart (barras + linha), visual nativo `lineStackedColumnComboChart`:
- Eixo: `dim_empreendimento[empreendimento_conformado]`
- Coluna (barras): `[VGV Vendas Marketing (Mkt N1)]`
- Linha: `[Qtd Vendas Marketing (Mkt N1)]`

## 6. Os 2 donuts

| Donut legado | Campo | Valor |
|---|---|---|
| Canal da Venda | `fato_reservas[Canal]` | `[Qtd Vendas Marketing (Mkt N1)]` |
| Pago x Orgânico | `fato_reservas[Pago ou Orgânico]` | `[Qtd Vendas Marketing (Mkt N1)]` |

Ambos os campos já vêm prontos em `fato_reservas` (merge da classificação
oficial já aplicado no Power Query do modelo vivo — confirmado, não é só
documentação).

⚠️ **NÃO usar `dim_origem["canal 2.0"]` aqui**, mesmo parecendo o candidato
óbvio pelo nome. `gold.dim_origem` é `SELECT DISTINCT` só de `gold.fato_leads`
(ver comentário em `gold.sql`) — cobre leads/pré-cadastro, não vendas. O
relacionamento `fato_reservas[Concat_origem] → dim_origem[origem_chave]`
existe no modelo, mas só casa por coincidência (quando a mesma combinação de
origem também apareceu do lado de leads); numa venda qualquer, o mais comum é
não achar par nenhum e a fatia virar 100% "(Em branco)" — achado em
19/ago/2026 tentando montar esse exato donut.

⚠️ **KEEPFILTERS obrigatório**: as medidas de vendas desta página (`Qtd/VGV
Vendas House/Marketing/Digital`, `% Vendas Digitais House`) filtram
`Canal`/`Share` **dentro do próprio `CALCULATE`**. Sem `KEEPFILTERS`, um
visual que agrupe por essa mesma coluna (como estes 2 donuts) mostra o MESMO
total em toda fatia — o filtro da medida substitui o contexto do eixo em vez
de cruzar com ele. Corrigido em 19/ago/2026; se criar uma medida nova nesse
padrão (filtro explícito de coluna dentro de CALCULATE) e for usá-la como
valor de um visual agrupado por essa coluna, lembrar do `KEEPFILTERS`.

## 7. Os 2 gráficos "Meta x Realizado" (colunas agrupadas, por mês)

| Gráfico legado | Realizado | Meta |
|---|---|---|
| Meta x Realizado Marketing | `[Qtd Vendas Marketing (Mkt N1)]` | `SUM(dim_metas_performace_digital[meta_vendas_mkt])` |
| Meta x Realizado Digital | `[Qtd Vendas Digital (Mkt N1)]` | `SUM(dim_metas_performace_digital[meta_vendas_digital])` |

Eixo: `dim_calendario[mes_abrev]` (já ordenado por `mes`).

## 8. Leads, MQL e Vendas por Mês

Gráfico de área empilhada, eixo `dim_calendario[mes_abrev]`, 3 séries:
`[Qtd Lead]`, `[Qtd MQL (Mkt N1)]`, `[Qtd Vendas Marketing (Mkt N1)]`.

## 9. Ícone de home

Imagem estática (canto superior direito) com ação de navegação pra página
inicial do relatório — mesmo padrão de outras páginas do modelo novo, se já
existir um ícone equivalente reaproveite-o.

---

## 10. Checklist de montagem no Desktop

1. Conferir que `dim_empreendimento[assinatura]` aparece no painel de campos
   (se não aparecer, feche e reabra o Desktop uma vez).
2. Nova página em branco, tamanho 16:9.
3. Os 4 slicers dropdown (§2) + o slicer de meses em blocos (§3).
4. 1 visual HTML Content com `[KPIs Marketing N1 HTML]` (§4), ocupando a
   largura toda, altura baixa (mesma proporção dos outros `*_HTML`).
5. Combo chart VGV por Empreendimento (§5), donuts (§6), colunas Meta x
   Realizado (§7) e área empilhada (§8), nas posições equivalentes à print de
   referência.
6. **Ctrl+S ao final** — todo o trabalho de medida feito por XMLA só existe no
   modelo em memória até isso.

## 11. Validação: como confiar nos números

O ambiente local tem bronze parcial (mesma ressalva de sempre — ver
`powerbi/README.md`, §6). Além disso, a `dim_metas_performace_digital` só tem
classificação `Share`/`Canal` fechada em `fato_reservas` até maio/2026 —
junho a agosto ficam com esses campos em branco até o próximo fechamento
manual da Vendas Consolidadas (comportamento esperado, documentado em
`powerbi/de_para_classificacao_venda.m`). Pra validar os cards com dado
completo, filtre um mês ≤ 2026-05.
