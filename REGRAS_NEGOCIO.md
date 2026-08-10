# Catálogo de Regras de Negócio — Pafil Data Platform

> **O que é:** inventário das regras de negócio corporativas extraídas dos **3 PBIX legados**
> (engenharia reversa em [`../_bi_ref/`](../_bi_ref)). Cada regra registra: **origem**, **lógica**,
> **dependências**, **camada-destino** na arquitetura medalhão e **notas de reimplementação**.
>
> **Por que existe:** o charter define que toda medida DAX / transformação Power Query / relacionamento
> é potencial regra de negócio que precisa ser mapeada, documentada e migrada com cuidado. Os 3 PBIX
> **já divergem entre si** — este catálogo é o passo para estabelecer **um número autoritativo**.
>
> **Como usar:** é a ponte para as duas frentes seguintes —
> (a) **Silver/Gold** reimplementam cada regra marcada `🔜`;
> (b) **reconciliação** confere os KPIs `⭐` contra os PBIX antigos.
>
> **Fontes:** `_bi_ref/RESUMO_Empreendimentos.md` (modelo "Matriz" / BI Comercial),
> `_bi_ref/RESUMO_BIPreco.md` (modelo "Preço"), `_bi_ref/M_Empreendimentos.md` (Power Query / de-paras).

## Legenda

| Símbolo | Significado |
|---|---|
| ⭐ | **KPI autoritativo** — candidato a reconciliação número-a-número vs. PBIX |
| 🔜 | Regra a reimplementar em Silver/Gold |
| 🎨 | **Não é regra de negócio** — formatação/UI (ícones ▲▼, cores, HTML). Descartar na migração |
| ⚠️ | Risco / armadilha / divergência conhecida |

## Mapa origem → destino (visão de 1 página)

```
LEGADO (PBIX)                          NOVA PIPELINE (medalhão)
─────────────────────────────         ──────────────────────────────────
CSV SharePoint relatorios_*.csv  ──►   BRONZE  (cvdw.* via API — já pronto)
Power Query (limpeza, filtros)   ──►   SILVER  (tipagem, dedup, conformação)
de-paras embutidas (.xlsx/JSON)  ──►   SILVER  (tabelas lookup / seed)
Modelo + relacionamentos         ──►   GOLD    (star schema: fatos + dimensões)
Medidas DAX (VGV, distrato...)   ──►   GOLD    (views/medidas oficiais)
Ícones/cores/HTML em DAX         ──►   (descartado — apresentação)
```

> ⚠️ **Achado estrutural:** no legado, **tudo nasce de CSV/Excel manuais no SharePoint**
> (`pafilconstrutora.sharepoint.com/.../BI - Comercial`), não da API. A pipeline nova substitui
> a origem (Bronze via CVDW), então **as regras de limpeza do Power Query existem para consertar
> defeitos do export manual** — várias podem desaparecer quando a origem é a API estruturada
> (ver seção 1). Isso é parte do valor da migração.

---

## 1. Regras de ingestão e limpeza (Power Query → Silver)

Vêm das partições M de `f_reservas`, `f_vendas`, `f_distratos`, `d_estrutura`.
São consertos do CSV manual. Avaliar quais ainda fazem sentido com origem = API.

| ID | Regra | Origem (legado) | Lógica | Destino | Notas |
|---|---|---|---|---|---|
| ING-01 | ⚠️ Descartar linhas-lixo do CSV | `f_reservas` M | Remove linhas onde `Reserva` contém `"JÁ ANEXEI"`, `"Financiamento: R$ ..."`, `"Sistema Antigo/Atual"`, `"Subsídio: R$ ..."`, ou `Aprovada = "Localização"` | 🔜 Silver (ou some) | Artefatos de quebra de linha no export manual. **Com a API provavelmente não existem** — validar e só então decidir se mantém o filtro defensivo |
| ING-02 | Reserva válida começa com dígito | `f_reservas` M | Mantém só linhas onde `Reserva` começa com `1`–`9` | 🔜 Silver | Idem — defensivo contra CSV malformado |
| ING-03 | Extrair `Reserva` entre aspas | `f_reservas` M | `Text.BetweenDelimiters(_, '"','"', FromEnd)` | 🔜 Silver | Específico do CSV; na API `idreserva` já vem limpo |
| ING-04 | ⭐ "Ajuste Castro" | `f_reservas` M | Se `Corretor = "JOSÉ ROBERTO DE CASTRO JUNIOR"` então `Responsável imobiliária` = o próprio nome dele (senão mantém) | 🔜 **Silver** | **Regra de negócio real** (não defeito de CSV). Esse corretor responde pela própria imobiliária. Reimplementar como CASE no Silver |
| ING-05 | ⭐ `f_vendas` = reservas vendidas dedup | `f_vendas` M | `f_reservas` filtrado a `Situação = "Vendida"`, remove nulos de `Código interno da unidade`, **dedup por unidade** (1 venda por unidade) | 🔜 Silver/Gold | Define o grão de "venda". ⚠️ dedup por unidade pode esconder revendas |
| ING-06 | Normalizar nomes de empreendimento | `d_estrutura` M | ~7 `ReplaceValue`: `Tríade`→`Triade Fiúsa Home Resort`, `Primaveras`→`Parc Das Primaveras`, `Arboretto`→`Arboretto Residenciale`, etc. | 🔜 Silver (de-para) | Conformação de nome de produto. Virar tabela de-para `silver.dpara_empreendimento` |
| ING-07 | `Permuta?` derivada | `d_estrutura` M | `if Permuta = "Permuta" then "Sim" else "Não"` | 🔜 Silver | Flag booleana de permuta |
| ING-08 | Dedup matriz por Código Interno | `d_estrutura` M | `Table.Distinct(..., {"Código Interno"})` | 🔜 Silver | 1 linha por unidade na dimensão de estrutura/preço |
| ING-09 | ⭐ Normalizar NOME DE PESSOA (corretor/gerente/supervisor) | novo (21/jul/2026) | `silver.nome_proprio()` = Title Case pt-BR com conectivo (de/da/do/das/dos/e) minúsculo, trim e espaço colapsado; `silver.chave_nome()` = minúscula + sem acento (translate, sem depender da extensão `unaccent`) | ✅ Silver (funções) | O nome é digitado à mão nos DOIS lados (headcount do backoffice e CVCRM) e é a **única chave comum** entre eles. Par exibição/chave: `nome_proprio` mostra, `chave_nome` junta. Aplicado em `gold.dim_corretor_headcount`, `gold.fato_leads` ("Corretor Trat" + `corretor_chave`) e `gold.fato_precadastros` (`corretor_tratado` + `corretor_chave`). Antes: 14/17 ativos casavam por sorte de digitação; agora 17/17. `initcap` puro NÃO serve (devolve "De Paula E Silva" e, em locale C, quebra acento sem COLLATE ICU) |

---

## 2. De-paras / tabelas de conformação (Power Query → Silver seeds)

Cada uma é uma **regra de classificação**. No legado vivem como `.xlsx` no SharePoint ou JSON embutido.
Na Silver viram tabelas lookup (seed) versionadas — **tirar do SharePoint é ganho de governança**.

| ID | De-para | Mapeia | Origem | Destino | Notas |
|---|---|---|---|---|---|
| DP-01 | `dpara_gerente_contexto` | `Gerente Responsável` (texto cru do CVCRM, campos_adicionais) → `Gerente Apelido`, `Share`, `House/Parcerias`, `Regional` | xlsx SharePoint (aba "contexto") | ✅ Silver seed | Usado SÓ p/ resolver a classificação da RESERVA (não existe ID p/ isso no CRM). Gap conhecido: ~388 reservas (`Marcio Lima`, `Jose Castro*`) sem linha — pendente confirmação da gestão. Ver histórico da investigação (ID `bronze.leads.idgestor` descartado como fonte de equipe — mistura SDR/robô) em [[depara-gerentes-reestruturacao-v2]]. |
| DP-13 | `dpara_imobiliaria_house` | `Imobiliária` (escritório) → `Share`, `House/Parcerias`, `Regional` | xlsx SharePoint (depara_gerentes.xlsx, aba "imobiliaria") | ✅ Silver seed | **É por aqui que LEADS e PRÉ-CADASTROS ganham a classificação** que a reserva já tem via DP-01: essas fatos não têm "Gerente Responsavel", mas o headcount (DP-12) diz o ESCRITÓRIO do corretor, e o escritório determina Share/House/Regional. Exposto em `gold.dim_corretor_headcount`; as fatos herdam pelo relacionamento `corretor_chave`. A junção usa a coluna `Imobiliaria` do headcount, **não** a `House` de lá (2 linhas com "EP - RP" arrastado — Carlos Roberto é SCA e João Victor é URA; decisão do dev 21/jul/2026). Era hard-code em `seeds.sql`; virou aba do xlsx porque classificação comercial não pode morar escondida no SQL. Grafia nova de imobiliária = linha nova na aba (o HC escreve "NEGOCIO" singular, o CVDW "NEGOCIOS"). |
| DP-12 | `dpara_corretor_headcount` | `Nome` (corretor) → `Gerente`, `Supervisor`, `Imobiliaria`, `House` | xlsx Backoffice (HeadCount/Base Corretores Pafil, aba "Base Pafil", só Ativos) | ✅ Silver seed | **Fonte autoritativa da EQUIPE do corretor** (21/jul/2026, passo atrás): "o que vem do CVDW como equipes é falho" (dev) — nem `bronze.leads.idgestor` (mistura SDR/robô) nem a derivação via reserva mais recente são confiáveis. A planilha manual do backoffice é. `gold.dim_corretor.equipe` agora prioriza `Supervisor` daqui; a derivação antiga via reserva vira fallback só p/ corretor fora do headcount (Parcerias). Cobre só o quadro próprio da Pafil (House RP/SC/UB), ~17 ativos hoje. |
| DP-02 | `dpara_canal/midia_*` (out24/nov24/dc) | `CONCAT canal/mídia` → `Canal`, `Mídia` | xlsx + JSON | 🔜 Silver seed | ⚠️ **3 versões coexistem** (out24, nov24, D.C) — convergir numa só e datar a vigência |
| DP-03 | `dpara_ativo_receptivo` | `Canal` → `Lead`/`Prospect` (`atv/recept`) | JSON embutido | 🔜 Silver seed | Classifica origem ativa vs receptiva |
| DP-04 | `dpara_qualificacao_lead` | `Situação` → `Qualificado?` | JSON embutido | 🔜 Silver seed | Base do MQL |
| DP-05 | `dpara_etapa_precadastro` | `Etapa WKF` → `Etapa precadastro BI` / `BI Detalhada` | xlsx SharePoint | 🔜 Silver seed | Base do funil de crédito (Montagem→Crédito Aprovado) |
| DP-06 | `dpara_equipe_corretor` | `Corretor` → `Categoria` | xlsx SharePoint | 🔜 Silver seed | — |
| DP-07 | `de_para profissões` | `Profissão original` → `Micro`/`Macro` | xlsx SharePoint | 🔜 Silver seed | Perfil de cliente |
| DP-08 | `dpara_ordem_etapa` | `Etapa` (situação) → `Ordem` | JSON embutido | 🔜 Silver seed | Ordenação do funil de situação da reserva |
| DP-09 | `dpara_diretoria` / `d_equipes` | `Corretor` → `Gerente`, `Imobiliária` (+ append) | JSON + xlsx | ✅ `dpara_corretor_gerente` (override) + derivação automática (gerente da reserva mais recente, em `gold.dim_corretor`) | ⚠️ legado tinha ajustes manuais hard-coded — replicar via seed se necessário |
| DP-10 | `d_imobiliarias` | `Imobiliária` → `Gestor` | xlsx SharePoint | 🔜 Silver seed | ⚠️ filtra SAO CARLOS/UBERABA e renomeia gestores ("(Imob)") |
| DP-11 | `dpara_feriados_2025` | `Data` → `Feriado` | xlsx SharePoint | 🔜 Silver seed | Calendário útil (tempo de resposta SDR/corretor) |
| DP-12 | `fluxo_investidor` / `retira_reservas` | listas fixas de `Reserva` | JSON embutido | 🔜 Silver seed | ⚠️ listas manuais de exceção — confirmar se ainda valem |

---

## 3. Dimensões e fatos (modelo → Gold star schema)

Já há um esboço em [`MODELO_SEMANTICO.md`](MODELO_SEMANTICO.md). O legado confirma o grão:

| Entidade | Grão | Origem legado → Bronze nova | Notas |
|---|---|---|---|
| `fato_reservas` | 1 reserva (`idreserva`) | `f_reservas` ← CSV → `cvdw.reservas` | Estado da reserva; `f_vendas`/`f_distratos` são views filtradas dela (ING-05) |
| `fato_series` | 1 parcela | `f_series` ← CSV → `cvdw.reservas_condicoes`(?) | ⚠️ confirmar mapeamento (pergunta aberta do SKILL) |
| `dim_empreendimento` | `codigo_cv` | `d_empreendimentos` (xlsx) → derivar de `unidades` | de-para de nome (ING-06) |
| `dim_estrutura/unidade` | `Código Interno` | `d_estrutura` (base_precos.xlsm) → `cvdw.unidades` | ✅ **`gold.dim_estrutura`** (task 6.4, ago/2026): preço/área/permuta/status_unidade (Estoque/Realizado/Permuta) por unidade. Fonte: `silver.d_estrutura` (seed, `popular_seeds.py --estrutura-precos`), 3.543 unidades das 13 abas `Matriz_*`. Status calculado via join `(codigo_cv, bloco, unidade)` contra `fato_reservas` — ⚠️ achado na carga: produto de torre única tem `reservas.bloco` = nome do empreendimento (não NULL como em `d_estrutura`); normalizado no join (ver comentário na view) |
| `dim_corretor` | corretor | `f_equipes` → `cvdw.corretores` | categoria/nível |
| `dim_imobiliaria` | imobiliária | → `cvdw.imobiliarias` | não materializada como dim na gold; nome fica em `fato_reservas`/`dim_corretor` |
| `d_metas_empreendimentos` | mês×empreend. | xlsx `Meta.xlsx` | ✅ **`gold.dim_metas_empreendimentos`** (task 6.4): 1.704 linhas (`meta_2`, aba base_meta), seed via `--metas-empreendimentos`. Continua **sem origem na API** (input manual da gestão) |
| `d_viabilidade` | empreend. | xlsx | ✅ **`gold.dim_viabilidade`** (task 6.4): pivot EAV → 1 linha/`codigo_cv` (receita bruta, terreno/construção/deduções/despesas), seed via `--viabilidade`. Parametriza a medida de Margem — ver KPI-17 |
| `d_calendario` | dia | gerada (DAX/M) | gerar na Gold |

> ⚠️ **Metas, viabilidade e verba de marketing não existem na API CVDW** — são planejamento da
> gestão. Permanecem como tabelas de input (seed/Excel controlado) alimentando a Gold.

---

## 4. KPIs autoritativos (medidas DAX → Gold)

As medidas-núcleo, em ordem de prioridade para reconciliação. DAX condensado; ver `RESUMO_*.md` para o original.

### 4.1 Vendas / VGV ⭐

| ID | Medida | Lógica (condensada) | Dependências | Notas |
|---|---|---|---|---|
| KPI-01 | ⭐ **VGV Bruto** | `SUM(f_reservas[Valor do contrato])` | fato_reservas | Base de quase tudo |
| KPI-02 | ⭐ **VGV Distrato** | `SUM(distratos[Valor do Contrato])` | f_distratos | ⚠️ usa tabela `'distratos 2025'` (xlsx separado), não a fato — convergir |
| KPI-03 | ⭐ **VGV Líquido** | `[VGV Bruto] − [VGV Distrato]` | KPI-01,02 | Número de vendas líquidas |
| KPI-04 | ⭐ **QTD Bruto** | `DISTINCTCOUNT(f_reservas[Reserva])` | fato_reservas | — |
| KPI-05 | ⭐ **QTD Distratos** | `DISTINCTCOUNT(distratos[Contrato])` | distratos | — |
| KPI-06 | ⭐ **QTD Líquido** | `[QTD Bruto] − [QTD Distratos]` | KPI-04,05 | — |
| KPI-07 | **Somente Vendas** | `COUNTROWS(f_reservas)` com `Situação = "Vendida"` | — | ⚠️ vs "Qtd Vendas 2" que inclui `{"Vendida","Distrato"}` — **duas definições de "venda" coexistem** |
| KPI-08 | **Qtd Vendas 2** | `COUNTROWS` com `Situação IN {"Vendida","Distrato"}` | — | "Venda" = vendida OU já distratada (foi venda um dia) |
| KPI-09 | **Ticket Médio / preco_medio** | `DIVIDE(SUM[Valor contrato], SUM[M² da unidade])` | — | preço médio por m² praticado |
| KPI-10 | Média Vendas 6M | média de `[Qtd Vendas 2]` nos últimos 6 meses fechados | d_calendario | EOMONTH |

> ⚠️ **Divergência-chave a resolver na reconciliação:** o que conta como "venda"?
> `{"Vendida"}` (KPI-07) vs `{"Vendida","Distrato"}` (KPI-08). Os PBIX usam as duas em contextos
> diferentes. Definir a regra **autoritativa** é entregável da migração.

### 4.2 Estoque / Preço / VSO (modelo "Preço" + Matriz) ⭐

Padrão repetido por empreendimento (PA, TR, PSU, PCJ, ARB, PO, PR, F16, QBV, VM, PPN, VLPQ):

| ID | Medida (padrão `XX_`) | Lógica | Notas |
|---|---|---|---|
| KPI-11 | ⭐ ✅ **EstoqueVGV** | `SUM(Matriz[Preço])` para unidades **NOT IN** `VALUES(Vendas[Cód. unidade])` | unidade não vendida = estoque. Reimplementado em `powerbi/MEDIDAS_ESTOQUE_PRECO.dax` sobre `gold.dim_estrutura[status_unidade]` |
| KPI-12 | ✅ **Estoque_Qtd** | `COUNT(Matriz[Cód.])` NOT IN vendas E `Permuta <> "Permuta"` | exclui permuta |
| KPI-13 | ⭐ ✅ **ProjetadoVGV** | `[EstoqueVGV] + SUM(Vendas[Valor do contrato])` | VGV potencial total |
| KPI-14 | ✅ **MetragemAVender** | `SUM(Matriz[Área Privativa])` estoque, sem permuta | — |
| KPI-15 | ✅ **M²Médio / M²ARealizar** | `AVERAGE(Vendas[M² Praticado])`; `EstoqueVGV / MetragemAVender` | — |
| KPI-16 | ✅ **VSO** | `DIVIDE(unidades realizadas, unidades totais)` | Velocidade de vendas (d_estrutura `status_unidade="Realizado"`) |
| KPI-17 | ⭐ ✅ **Margem / MargemViab** | `(Projetado − custo − %ded − %desp) / (Projetado × fator)` | Parametrizado (ver nota abaixo) |

> ✅ **Task 6.4 (ago/2026) resolveu a duplicação (R4):** o modelo "Preço" repetia as MESMAS 8
> medidas para ~12 empreendimentos com constantes coladas no DAX. Na Gold virou **UMA** medida
> parametrizada por `gold.dim_viabilidade` (custo de obra = `|terreno_valor + construcao_valor|`,
> %deduções/%despesas por `codigo_cv`) — `powerbi/MEDIDAS_ESTOQUE_PRECO.dax`. Fórmula validada à
> mão contra os números de Parc das Artes (`codigo_cv` 10093) no `_bi_ref/RESUMO_BIPreco.md`.

### 4.3 Distratos ⭐

| ID | Medida | Lógica | Notas |
|---|---|---|---|
| KPI-18 | ⭐ **Taxa de Distrato** | `DIVIDE([Distratos], [Reservas Vendidas])` | KPI oficial |
| KPI-19 | `eh_distrato` | `Situação = "Distrato"` (ou motivo preenchido) | flag na fato |
| KPI-20 | ⚠️ múltiplas fontes de distrato | `f_distratos` (xlsx), `'distratos 2025'` (xlsx), `rel_distratos` (CSV) | **3 fontes**. `cvdw.distratos`/`silver.distratos` (API, fonte viva) já cobre motivo/data/valor — bate ao centavo (R11 da reconciliação). `'distratos 2025'` importada como **detalhe financeiro complementar** (multa/pago/devolução/parcelas, que a API não tem) em `gold.dim_distratos_2025` (ago/2026); ainda não relacionada à fato por falta de chave comum — ver nota na view. `f_distratos`/`rel_distratos` seguem não importadas (redundantes com a API pro que já é coberto) |

### 4.4 Funil de Leads / Performance Digital

| ID | Medida | Lógica | Dependências |
|---|---|---|---|
| KPI-21 | Qtd Prospect | `DISTINCTCOUNT(f_leads[Id])` | f_leads |
| KPI-22 | Qtd Leads | distinct Id com `canal 2.0 = "Lead"` | DP-02 |
| KPI-23 | Qtd Lead Quali (MQL) | `canal 2.0="Lead"` E `MQL 2="SIM"` | DP-04 |
| KPI-24 | Tx_Qualif_Leads | `MQL.../Lead...` | DP-04 |
| KPI-25 | Qtd Pastas | `COUNTROWS(f_precadastros)` exceto `{"Montagem","Cancelada"}` | DP-05 |
| KPI-26 | Qtd Crédito Aprovado | etapa IN `{"Crédito Aprovado","Com Reserva","Ajustes"}` | DP-05 |
| KPI-27 | Conversões (lead→pasta→venda) | série de `DIVIDE` entre os acima | KPI-21..26 |
| KPI-28 | Tempos médios (SDR/corretor/quali) | `AVERAGEX(... × 60)` formatado HH:MM:SS | DP-11 (feriados) |
| KPI-29 | CAC / ROI / CPL | `verba / vendas`, `(VGV Lead − verba)/verba` | verba (xlsx) |
| KPI-30 | % Vendas Digitais (House) | vendas com `canal vendas consolidadas="Lead"` ÷ total | DP-01, DP-02 |

### 4.5 Metas / Forecast

| ID | Medida | Lógica | Notas |
|---|---|---|---|
| KPI-31 | ✅ meta_start / meta_replan | `SUM(d_metas[meta_vgv])` por `status_meta` | input gestão. `gold.dim_metas_empreendimentos` (task 6.4) |
| KPI-32 | ✅ Diferenca_meta_* / % Atingimento | `VGV ÷ meta` | acumula YTD — `powerbi/MEDIDAS_GOLD.dax` |
| KPI-33 | ✅ Forecast (% Forecast, Dif Forecast) | `Realizado ÷ Meta VGV` | `VGV Vendas` xlsx — `powerbi/MEDIDAS_GOLD.dax` |

### 4.6 Comissões / Repasses / Receita

| ID | Medida | Lógica | Notas |
|---|---|---|---|
| KPI-34 | Valor Custas | `SUMX(f_reservas, [Valor contrato] × 0.029)` | ⚠️ 2,9% hard-coded |
| KPI-35 | Total comissão/prêmio | colunas da fato (`Comissão corretor/imob...`) | já vêm no CSV/API |
| KPI-36 | Valor Liq. Finan. / Recebimento Obra / À Receber | `repasses`: `financiado − terreno`, `× obra acumulada` | tabela `repasses` (API: contratos/repasses?) |
| KPI-37 | Valor Aprovado Sem Duplicados | `SUMX(DISTINCT(Id), MAX(Valor Aprovado))` | f_precadastros |

---

## 5. Simulador de preço / Pró-Soluto (modelo "Matriz", aba simulador)

Regras de **política comercial** (limites de parcelamento), valiosas mas fora do core de reporting:

| ID | Regra | Lógica | Notas |
|---|---|---|---|
| SIM-01 | ⭐ Limite de Pró-Soluto por produto | `SWITCH(Produto, "Fiusa 016",15, "Villa Manacás",10, ...)` % | **política comercial hard-coded** — virar seed `dpara_limite_prosoluto` |
| SIM-02 | Alerta Pró-Soluto | `🟢 dentro` se `%ProSoluto ≤ limite` | depende SIM-01 |
| SIM-03 | Parcela / Valor Entrada / Valor Ato | aritmética de financiamento | usa `f_precadastros[Valor Aprovado]` |
| SIM-04 | VGV/QTD Possível | conta unidades "dentro do limite" × preço | — |

---

## 6. Itens a DESCARTAR na migração (🎨 não são regra de negócio)

Para não poluir Silver/Gold. São pura apresentação:

- **Ícones:** `*_Icone` (▲▼ via `UNICHAR(9650/9660)`) — Meta Lead, Venda Digital, Qualificação, Vendas House...
- **Cores:** `*_Cor` / `*_Variacao_Cor` (`"Green"/"Yellow"/"Red"` por faixa) — semáforos.
- **Cards/HTML:** `Cards Fiusa 016`, `Tabela Fiusa 016 ...`, `KPI Sparkline`, `Tabs Período`, `Métrica Card ...` — HTML/SVG embutido em DAX para visuais customizados.
- **LocalDateTable_*:** ~50 tabelas de data auto-geradas pelo Power BI — substituídas por 1 `dim_calendario`.

> Regra: **lógica de cor/ícone/HTML fica no Power BI (camada de visual), nunca na Gold.**
> A Gold entrega o número; o relatório decide a cor.

---

## 7. Riscos e divergências conhecidas (consolidado)

| # | Risco | Onde | Ação |
|---|---|---|---|
| R1 | ⚠️ "Venda" tem 2 definições (`{Vendida}` vs `{Vendida,Distrato}`) | KPI-07/08 | Definir autoritativa na reconciliação |
| R2 | ⚠️ Distratos vêm de 3 fontes distintas | KPI-20 | Unificar em `cvdw.distratos` |
| R3 | ⚠️ Canal/Mídia tem 3 versões de de-para | DP-02 | Convergir + datar vigência |
| R4 | ✅ Margem/Viab com constantes hard-coded por empreend. | KPI-17 | Parametrizado via `gold.dim_viabilidade` (task 6.4, ago/2026) |
| R5 | ✅ Metas/viabilidade/verba não existem na API | seção 3 | Metas e viabilidade importadas como seed (task 6.4); verba de marketing segue pendente |
| R6 | ⚠️ Listas de exceção manuais (fluxo investidor, retira reservas) | DP-12 | Confirmar vigência com gestão |
| R7 | ⚠️ dedup de venda por unidade pode ocultar revenda | ING-05 | Validar grão na Silver |
| R8 | ⚠️ Ajustes pessoais hard-coded (Castro, Marcio) | ING-04, DP-09/10 | Mover para de-para versionada |
| R9 | ⚠️ "Vendas Consolidadas" tem status MANUAIS sem correspondência na API (`Validada`, `Venda distratada`, `Repassada`, `Envio Mega`, `Validação Comercial`) | planilha legada | Virar de-para `dpara_status_venda` (situacao CRM → status operacional) OU input operacional; NÃO vêm do CRM |
| R10 | 🔴 Fechamento manual **defasa**: 420/1892 propostas que a planilha conta como venda viva já são **Distrato** no CRM | reconciliação vendas | Ganho da pipeline (número sempre atual). Documentar p/ gestão |
| R11 | ✅ `valor_contrato` (API) = "VGV (Praticado)" (planilha) ao centavo em **1869/1892** (98,8%) | reconciliação vendas | Valida KPI-01. **Investigado** as 23 divergências: 1 buraco de dado no CRM (proposta 337, `valor_contrato=0` mas financ+subsídio+FGTS=~207k); 7 usaram `vgv_tabela` (preço de tabela) no legado; 15 ajustes/arredondamentos manuais (vários ~R$ 9,5k de desconto) que não batem com nenhuma coluna do CRM. **`valor_contrato` é o número autoritativo.** |
| R12 | ✅ DE_PARA_PRODUTOS extraída → `dpara_empreendimento` (25 linhas) + `silver.conformar_empreendimento()` case-insensitive na gold | DP-06/ING-06 | Resolve "FIUSA 016" vs "Fiusa 016" etc. Aba também traz `EP` (espaço de negócios) |
| R13 | ✅ **House = escritório próprio Pafil** (imobiliária `ESPACO DE NEGOCIOS PAFIL <regional>`); **House RP = RIBEIRAO PRETO/RPO**. Ranking é **só House** e **exclui** corretor de coordenação ("Regiane..."). | apresentação (ranking) | Confirmado: reproduz o pódio de maio/2026 ao centavo (Alessandra/Rafael/Wallace). Seeds `dpara_imobiliaria_house` + `dpara_corretor_fora_ranking`; House/regional vêm da classificação oficial no Power BI, onde o ranking por corretor é montado sobre a `fato_reservas` (a exclusão da coordenação é filtro pela seed). `dpara_gerentes` recarregado do `depara_gerentes.xlsx` (43 linhas, House/Parcerias×Regional) |
| R14 | ✅ **Ranking por GERENTE destravado** (slides 17-19): "Gerente Responsavel" **existe na API** como campo customizado em `campos_adicionais` (não em coluna própria). 68% das vendas preenchidas, 39 gerentes, casa com `dpara_gerente_contexto`. `silver.campo_adicional()` extrai; `silver.reservas.gerente_responsavel`; ranking por gerente montado no Power BI sobre a `fato_reservas` (House pela classificação oficial). **Validado:** Matheus Santamaria 6un/R$1,75Mi = slide 18 ("Liga das vendas", 6un/1,7Mi). NÃO precisou de de-para manual. |
| R15 | ✅ Outros campos do BI legado em `campos_adicionais` **extraídos** p/ silver/gold: `cf_tipo_venda` (98%: Financiamento na Planta/Venda Direta/...), `cf_modalidade_financiamento` (97%: MCMV/PAFIL/SBPE), `cf_motivo_distrato`, `cf_classificacao_vendas_internas`. Ainda disponíveis sob demanda: "Data de Distrato", "Premiação Tá Fácil", "Reciprocidade", "IRPF Futuro" via `silver.campo_adicional()` | reservas | — |
| R16 | ⚠️ Qualidade: alguns "Gerente Responsavel" trazem nome de EQUIPE ("Equipe Pitangueiras") ou "N/D" em vez de pessoa; 32% nulos. Nomes às vezes divergem do `dpara_gerente_contexto` (ex.: "Marcio Lima" 328 reservas, "Jose Castro*" 60 reservas — ~8% do total; ver DP-01) | ranking gerentes | Confirmar com a gestão e adicionar linha na aba "contexto" do depara_gerentes.xlsx |
| R17 | ⚠️ `gold.dim_estrutura` não tem código de unidade 1:1 com a API (a CVDW não expõe o "Código interno da unidade" do CSV legado) — o status Estoque/Realizado casa por `(codigo_cv, bloco, unidade)` normalizado. Achado durante a carga (task 6.4): em produto de torre única `silver.reservas.bloco` vem com o NOME DO EMPREENDIMENTO em vez de vazio (`d_estrutura.bloco` fica NULL) — sem normalizar isso o match zerava (Parc das Artes deu 0 "Realizado"). Corrigido tratando bloco=nome-do-empreendimento como NULL dos dois lados antes do join | `gold.dim_estrutura` | Corrigido nesta task; se outro produto aparecer com taxa de match baixa, investigar variação de grafia de bloco/unidade (não há mais fallback por código) |

---

## 8. Próximos passos a partir deste catálogo

1. ✅ **Silver** (`sql/silver/`): ING-04 virou seed `dpara_responsavel_imobiliaria`; ING-01..03 não
   portadas (eram lixo de CSV); 6 views de conformação. DP-* como seeds (`seeds.sql`).
2. ✅ **Gold** (`sql/gold/`): star schema (fatos + dims) sobre a silver; KPI-01..06/09/18 viram medidas DAX no Power BI (`powerbi/MEDIDAS_GOLD.dax`).
3. ✅ **Reconciliação** (`reconciliar_distratos.py`): distratos maio/2026 **bate ao centavo**
   (54 vs 54; VGV R$ 12.888.599,11 idêntico). Relatório em `reconciliacao/`.
4. ✅ **Seeds populados** (`popular_seeds.py`): DP-02/03/04/08 + DP-01(gerentes) decodificados do
   JSON embutido do legado (343 linhas). Pendentes (planilha SharePoint): feriados, profissões,
   etapa_precadastro, equipe_corretor.

5. ✅ **Reconciliação de vendas** (`reconciliar_vendas.py`): vs. planilha `Vendas Consolidadas.xlsm`.
   VGV bate ao centavo em 98,8% das propostas do overlap (R11); revelou o drift do fechamento
   manual (R10) e a camada de status manual (R9). Relatório em `reconciliacao/RECONCILIACAO_VENDAS.md`.

### Ainda em aberto
- **Rodar no bronze COMPLETO (VPS)** — o bronze local é parcial (1.302 propostas do legado faltam);
  a reconciliação de totais só fecha com a carga cheia.
- **Investigar as 23 divergências de VGV** (R11) — padrão de ~R$ 9,5k sugere sinal/desconto sistemático.
- **Validar com a gestão** R1 (def. de "venda"), R3 (canal/mídia), R6 (exceções), R9/R10 (status manual/defasagem).
- **Power BI** consumir a camada `gold` (substituir o direto-API da Fase 0).

> Cobertura desta versão: modelo "Matriz" (~150 medidas, 40+ tabelas) e modelo "Preço" (12 empreend.).
> Medidas de UI (🎨) catalogadas como descarte. Próxima revisão: detalhar DAX completo dos KPIs ⭐
> escolhidos para reconciliação.
