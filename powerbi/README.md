# Power BI sobre a camada Gold — passo a passo de importação

> ⚠️ `de_para_classificacao.xlsx` nesta pasta contém dado real (nomes/classificações
> de proposta). Repositório é **privado** — não redistribuir fora dele.

Guia para montar o `.pbix` da apresentação mensal consumindo o **star schema gold**
(substitui o CVCRM manual diário → Vendas Consolidadas → PBIX). A gold entrega os fatos e
dimensões já reconciliados (VGV bate com os slides); rankings/mídia/esteira são montados no BI.

---

## 0. Pré-requisitos
1. **Banco de pé:** `& "$env:LOCALAPPDATA\pafil_pg\pg.ps1" start`
2. **Warehouse aplicado:** `python aplicar_tudo.py` (silver → gold → seeds). Para os
   nomes conformados + House completos: `python aplicar_tudo.py --xlsm "<Vendas Consolidadas.xlsm>"`
   e `python popular_seeds.py --gerentes "<depara_gerentes.xlsx>"`.
3. **Provedor Npgsql:** na 1ª conexão PostgreSQL o Power BI Desktop pede para instalar o
   **Npgsql** — aceite (ou baixe do GitHub do Npgsql e reinicie o Desktop).

---

## 1. Conectar

**Opção A (rápida):** duplo clique em **`conectar_gold.pbids`** → abre o Desktop já no banco.

**Opção B (manual):** *Página Inicial → Obter dados → Banco de dados → Banco de dados PostgreSQL*:
- **Servidor:** `localhost:5433`
- **Banco de dados:** `pafil_dw`
- **Modo:** *Importar*
- Credenciais → aba **Banco de dados**: usuário `postgres`, senha `PafilLocalDev2026`.
- Se reclamar de SSL/criptografia: o banco local está **sem SSL** → desmarque "Criptografar conexão"
  (ou responda para conectar sem criptografia).

---

## 2. Selecionar as tabelas (Navegador)

Marque, do schema **`gold`**:

| Objeto | Para quê |
|---|---|
| `fato_reservas` | a fato (todas as análises de venda) |
| `dim_calendario` | eixo de tempo (x Mês, Acumulado/YTD) |
| `dim_empreendimento` | Vendas x Empreendimento |
| `dim_corretor` | atributos de corretor |
| `fato_leads` | funil de marketing (leads x mídia/origem) |
| `fato_precadastros` | funil de crédito (pré-cadastros) |

> A gold entrega só **fatos e dimensões**. Rankings, Vendas x Mídia, esteira e demais
> agregados são montados **no Power BI** (medidas/visuais sobre `fato_reservas`), usando a
> classificação oficial (origem/canal/mídia, House/Parcerias) que vem da *Vendas Consolidadas*
> por proposta. *Transformar Dados* só se quiser revisar; senão **Carregar**.

---

## 3. Relacionamentos (modo Modelo)

As dimensões ligam à fato (1 → *, direção única):

```
dim_calendario[data]              1─* fato_reservas[data_venda]      (ativo)
dim_empreendimento[id_empreendimento] 1─* fato_reservas[id_empreendimento]
dim_corretor[id_corretor]         1─* fato_reservas[id_corretor]
```

- **Marque `dim_calendario` como Tabela de Datas** (coluna `data`): *Ferramentas de tabela → Marcar como tabela de datas*.
- `fato_leads`/`fato_precadastros` ligam a `dim_calendario` por `data_cad` (e a
  `dim_empreendimento`/`dim_corretor` quando fizer sentido) para os funis de marketing/crédito.
- Opcional: relacionamento **inativo** `dim_calendario[data] → fato_reservas[data_distrato]`
  para distratos no mês do distrato (ativar com `USERELATIONSHIP`).

---

## 4. Medidas

Cole as de **`MEDIDAS_GOLD.dax`** numa tabela de medidas (VGV Bruto/Distrato/Líquido, QTD,
Ticket, Taxa de Distrato, YTD, MoM — mapeadas aos `KPI-*` do `REGRAS_NEGOCIO.md`).

---

## 5. Montar os visuais da apresentação

| Slide | Como |
|---|---|
| **Vendas x Mês** | Gráfico de colunas: eixo `dim_calendario[mes_abrev]`, valor `[VGV Bruto]` (filtro de Ano) |
| **Vendas Acumuladas (YTD)** | Linha: eixo `dim_calendario[data]`, valor `[VGV Bruto YTD]` |
| **Vendas x Empreendimento** | Barras: eixo `fato_reservas[empreendimento_conformado]`, valor `[VGV Bruto]` |
| **Vendas x Mídia** | Barras sobre a fato: eixo `fato_reservas[midia]`, valor `[VGV Bruto]`, slicer `ano_mes_venda` |
| **Ranking Corretores** | Tabela sobre a fato: eixo `fato_reservas[corretor]`, valor `[VGV Bruto]`/`[QTD]`, filtre House RPO pela classificação oficial, ordene por VGV desc |
| **Ranking Gerentes** | Tabela sobre a fato: eixo `fato_reservas[gerente_responsavel]`, valor `[VGV Bruto]`, filtre House pela classificação oficial, ordene por VGV desc |
| **House RPO (slides 6-11)** | Mesmos visuais da fato com o filtro House/RPO da classificação oficial |

> A regra House/Parcerias e origem/canal/mídia vêm da **classificação oficial** (*Vendas
> Consolidadas*) mesclada por proposta no Power BI, não de colunas da fato. Campos extras na
> fato: `cf_tipo_venda`, `cf_modalidade_financiamento`, `cf_motivo_distrato`, `gerente_responsavel`.
> A exclusão de corretores de coordenação (antes na `ranking_corretores`) vira um filtro no visual
> pela seed `silver.dpara_corretor_fora_ranking`.

### Página "Esteira de vendas" (funil de reservas)

Monte o funil **sobre a `fato_reservas`**, usando `situacao_tratada`/`situacao_ordem`
(já disponíveis na fato):

1. **Ordenar a situação:** selecione `situacao_tratada` → *Ferramentas de coluna → Classificar por
   coluna → `situacao_ordem`*. (Assim o funil sai na ordem certa, não alfabética.)
2. **Funil de etapas** (visual *Funil* ou colunas): categoria `situacao_tratada`, valor
   `Contagem de id_reserva` (ou `[VGV Bruto]`).
3. **Tabela esteira/gerente** (visual *Matriz*): linhas `gerente_responsavel`, colunas
   `situacao_tratada`, valores contagem de reservas. É a "esteira por gerente" do BI legado.
4. **Segmentações (slicers):** `regional`, `empreendimento_conformado`, `ano_mes_venda` (House/Parcerias
   e share pela classificação oficial).
5. **Só pipeline aberto:** filtre `situacao_ordem <= 13` (antes de Vendida/Cancelada/Distrato).
   Obs.: "Vencida" (12) é reserva expirada — use `situacao_ordem <= 11` se quiser só o funil ativo.

### Página "Pré Cadastro" (funil de crédito)

Reimplementação da página "Pré Cadastro" do BI Matriz legado (35 visuais, decifrados
de `_bi_ref/matriz_report.json`/`matriz_model.bim`). Fonte: `fato_precadastros`
(schema montado 24/jul/2026 — ver `MEDIDAS_PRECADASTROS.dax` para as medidas e as
notas de DP-05/esteira/equipe). **Antes de montar:** clicar **Atualizar** no Desktop
(a `fato_precadastros` ganhou colunas novas — `etapa_bi`, `etapa_bi_detalhada`,
`situacao_anterior`, `situacao_reserva`, `id_reserva`, `eh_venda_reserva`,
`eh_distrato_reserva`, `aprovacao_credito`, `encaminhado_cca` — e o Desktop só as
popula reprocessando o mashup pelo botão, não por refresh via API/TOM). Cole as
medidas de `MEDIDAS_PRECADASTROS.dax` na tabela `Medidas` (pasta "Pré-Cadastro")
antes de montar os visuais.

| Visual (nome no legado) | Tipo | Como montar aqui |
|---|---|---|
| Pastas Imobiliária | Barras | eixo `fato_precadastros[imobiliaria]`, valor `[Qtd Pastas]` |
| Pastas House/Parcerias | Rosca | eixo `depara_corretor_headcount[house_parcerias]`, valor `[Qtd Pastas]` |
| Cadastro x Etapa | Colunas | eixo `fato_precadastros[etapa_bi_detalhada]` (ordenar por texto — já vem numerado "0."→"6."), valor `[Qtd Pastas]` |
| Pastas Gerentes House | Barras | eixo `depara_corretor_headcount[supervisor]`, valor `[Qtd Pastas]`, filtro `house_parcerias="House"` |
| Pastas Corretor | Barras | eixo `fato_precadastros[corretor_tratado]`, valor `[Qtd Pastas]` |
| Cadastro x Produto | Colunas agrupadas | eixo `fato_precadastros[empreendimento_conformado]`, valor `[Qtd Pastas]` |
| Analítico dos Leads, Pastas e Reservas | Tabela | `data_cad`, `corretor_tratado`, `id_lead`, `situacao`, `etapa_bi_detalhada`, `empreendimento_conformado`, `imobiliaria`, `id_reserva` |
| Cards (topo) | HTML Content | `[KPIs Pré-Cadastro HTML]` — 6 cards (Pastas/Avaliado/Tx Avaliação/Aprovado/Tx Aprovação/Vendas), mesmo padrão visual do `KPIs Leads HTML` |
| Funil Pastas→Crédito Analisado→Crédito Aprovado→Venda | HTML Content | `[Funil Pré-Cadastro HTML]` — mesmo padrão visual do `Funil Comercial HTML` (4 estágios em vez de 3; não é um visual nativo do legado, adaptado a pedido do dev) |
| Slicers | Segmentação | `fato_precadastros[imobiliaria]`, `fato_precadastros[empreendimento_conformado]`, `depara_corretor_headcount[supervisor]` (Equipe Corretor), `depara_corretor_headcount[regional]`, `dim_calendario` (Ano/Mês/Dia — marcar hierarquia) |
| Aprovação de Crédito | Rosca | eixo `fato_precadastros[aprovacao_credito]`, valor `[Qtd Pastas]` (ou `COUNTROWS`) — cobertura baixa é esperada (~9%, só pastas tocadas pelo time de crédito) |
| Encaminhado ao CCA | Rosca | eixo `fato_precadastros[encaminhado_cca]`, valor `[Qtd Pastas]` (ou `COUNTROWS`) — mesma ressalva de cobertura |

> Os 2 donuts acima vieram de `silver.precadastros_credito_manual` (novo, 24/jul/2026),
> carregado do export "Relatório Web" do CVCRM (`relatorios_precadastro.xlsx`) via
> `popular_seeds.py --credito-manual` — a API CVDW não traz essas 2 colunas.

**Fora do escopo por falta de fonte** (ver notas no `.dax`):
- "Pastas por Corretor (House)" com HC mensal (linha comparando `Qtd Pastas` com
  headcount do mês) — falta a série mensal `dpara headcount` (DATA/REGIONAL/HC);
  o de-para está listado em `config/deparas.yml` mas sem loader/tabela silver ainda.

---

## 6. Validação (confiança nos números)

Antes de apresentar, confira contra os relatórios em `reconciliacao/`:
- Ranking de corretores House RP (maio/26): Alessandra/Rafael/Wallace — deve bater com o visual da fato.
- Ranking de gerentes (maio/26): Matheus Santamaria 6un/R$1,75Mi ("Liga das vendas").
- Distratos e VGV já reconciliados ao centavo / 98,8%.

> ⚠️ Bronze local é **parcial**. Para o relatório de produção, rodar a carga completa na VPS
> e reapontar o `.pbids`/servidor; **o modelo e as medidas não mudam**.

## 7. Atualizar mês a mês
- Após a carga incremental (`ingestao.py --incremental`) + `aplicar_tudo.py`, é só
  **Atualizar** no Power BI. Em produção (VPS) o Power BI Service atualiza via **gateway**.
