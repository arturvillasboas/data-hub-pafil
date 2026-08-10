# Contexto do Projeto — Pafil Data Platform (briefing para agentes de IA)

> Texto de contexto. Resume o objetivo, o que foi construído e o estado atual, para um
> agente continuar o trabalho sem conhecimento prévio. Diretório ativo: `v2/`.

## Objetivo
Migrar a BI da Pafil (construtora/incorporadora imobiliária) de uma arquitetura manual e
frágil — exports CSV diários no SharePoint → Power Query → DAX em **3 PBIX que já divergem
entre si** — para um data warehouse em **arquitetura medalhão**:
**CVCRM (API CVDW) → Python → PostgreSQL → camadas bronze/silver/gold → Power BI.**
Princípio de governança: toda medida DAX / de-para / transformação do legado é **regra de
negócio potencial** — mapear, documentar e migrar com cuidado, estabelecendo "um número autoritativo".

## Contexto de negócio e processo manual atual (o "porquê")
A Pafil é construtora/incorporadora — **o que move a empresa é venda**. O dono do projeto é
analista de dados full-stack alocado no **Comercial**, responde ao **Igor** (gestor comercial,
que faz gestão direta dele + 1 SDR). **Entregável final = a apresentação mensal de fechamento**
("Reunião de Fechamento", PPTX) para gestores, corretores, SDRs, diretores, CEO e marketing —
**montada por ele**. As análises comerciais da apresentação: **Vendas Acumuladas (YTD), Vendas x
Mês, Vendas x Empreendimento, segmentação por House/share (ex.: "HOUSE RPO"), Vendas x Mídia,
Ranking Corretores e Ranking Gerentes (VGV e unidades)** — hoje montadas às pressas no PBIX.

**Cadeia manual atual de fechamento (o que a pipeline vem substituir):**
1. **CVCRM extraído manualmente TODO DIA** → colado numa planilha-base (a que "contém 2024") →
   colunas adicionais "pintadas de cinza" preenchidas à mão por regras de negócio → alimenta a
   **"Vendas Consolidadas"**.
2. O **financeiro** envia por e-mail a planilha dos **distratos reais do mês** (já validada; base
   extraída do **MEGA**).
3. Os distratos são **confrontados manualmente** com a Vendas Consolidadas e ajustados.
4. A Vendas Consolidadas (manual + validada) é consumida → **PBIX** → apresentação mensal.

**MEGA** = banco/sistema central da empresa (financeiro, contábil, maioria dos processos), mas
**sem acesso aos dados** — só interface de sistema/relatórios. Por isso o caminho histórico é
CVCRM + planilhas manuais. A pipeline nova (CVCRM API → gold) **automatiza a perna
CVCRM→Vendas Consolidadas** (já comprovado: reproduz a Vendas Consolidadas em 98,8% e os distratos
ao centavo). A validação de distratos do financeiro/MEGA e algumas regras manuais seguem, por ora,
como passo humano. **Objetivo de médio prazo: alimentar essas análises comerciais direto da `gold`**
(ver `gold.fato_reservas` + dims; ranking por gerente/House e Vendas x Mídia são montados no
Power BI sobre a fato, com a classificação oficial da *Vendas Consolidadas* por proposta).

## Fonte de dados
CRM imobiliário **CVCRM** (subdomínio `pafil.cvcrm.com.br`), API **CVDW**, 19 objetos.
Paginação 500/página, rate limit ~20 req/min (429 + bloqueio 60s), auth por email+token
(no `.env`, nunca no repo). Incremental por `a_partir_data_referencia` + snapshots diários.

## Infra
PostgreSQL (open source, fixo). **Validação LOCAL** = instância PostgreSQL user-space na
**porta 5433** (sem admin; o serviço 5432 da empresa tem senha desconhecida), db `pafil_dw`,
senha local `PafilLocalDev2026`, sem SSL. Subir: `%LOCALAPPDATA%\pafil_pg\pg.ps1 start`
(cai no logoff). **Produção** = VPS da empresa (DigitalOcean) — **ainda NÃO provisionada**.
NÃO usar Neon/Supabase/VPS pessoal (PII/LGPD). dbt Core adiado até o schema estabilizar.

## O que está pronto (tudo aplicado e validado no banco local)
- **Bronze** (`sql/bronze/bronze.sql`, `ingestao.py`): 20 tabelas cruas da API + `_snapshot`
  de cada. ⚠️ A carga local é **PARCIAL** (4.756 reservas; ~1.302 propostas do legado faltam)
  — o run completo vai para a VPS.
- **Silver** (`sql/silver/silver.sql`, `aplicar_silver.py`): 6 **views** conformadas
  (`reservas`, `vendas`, `distratos`, `unidades`, `corretores`, `imobiliarias`) — tipagem forte
  (datas text→timestamptz via funções tolerantes; CNPJ/CRECI→text) e flags de regra. A limpeza
  de CSV do legado (ING-01..03) **não** foi portada (era conserto de export manual; a API já vem estruturada).
- **Seeds de-para** (`sql/silver/seeds.sql`, `popular_seeds.py`): 11 tabelas `dpara_*`; 6
  populadas decodificando o JSON base64+DEFLATE embutido no Power Query legado + a aba
  `DE_PARA_PRODUTOS` do xlsm. Pendentes (vêm de planilha SharePoint): feriados, profissões,
  etapa_precadastro, equipe_corretor.
- **Gold** (`sql/gold/gold.sql`, `aplicar_gold.py`): star schema — `fato_reservas` (reservas
  ⨝ distratos), `fato_leads`, `fato_precadastros` + dims (`calendario`, `empreendimento`,
  `unidade`, `corretor`). Agregados/rankings/esteira ficam por conta do Power BI. Conformação de
  nome de empreendimento via `silver.conformar_empreendimento()` (case-insensitive).
  **Task 6.4** (ago/2026) somou `dim_estrutura` (preço/estoque por unidade), `dim_metas_empreendimentos`
  (metas/forecast) e `dim_viabilidade` (parâmetros de margem) — as 3 tabelas do BI de Preço/
  Empreendimento x Meta que não vêm da API (input manual da gestão), carregadas via
  `popular_seeds.py` a partir de planilhas do SharePoint (`base_precos.xlsm`, `Meta.xlsx`,
  `d_para empreendimentos.xlsx`). Medidas DAX de referência em `powerbi/MEDIDAS_ESTOQUE_PRECO.dax`.
  Logo em seguida (mesmo dia) somou `dim_distratos_2025` — detalhe financeiro de distrato
  (multa/pago/devolução/parcelas) de `relatorio_distratos.xlsx`, que a API também não tem;
  ainda sem chave pra relacionar à `fato_reservas` (ver R2/nota na view).
- **Orquestrador**: `aplicar_tudo.py` (silver→gold→seeds num comando).
- **Power BI**: `powerbi/` (.pbids de conexão + `MEDIDAS_GOLD.dax` + guia). O `.pbix` em si
  ainda **não foi montado** (passo manual no Desktop).

## Regra-chave (R1)
"Venda" tem **duas definições** no legado: `{Vendida}` vs `{Vendida, Distrato}`. Ambas expostas
(`eh_venda` / `eh_venda_ou_distrato`); a autoritativa é **decisão da gestão**, não técnica.

## Reconciliações (provam o paralelo — "o demo que vende o projeto")
- **Distratos maio/2026** (`reconciliar_distratos.py` vs CSV legado `rel_distratos`):
  **bate ao centavo** — 54 vs 54 distratos, VGV R$ 12.888.599,11 idêntico.
- **Vendas** (`reconciliar_vendas.py` vs `Vendas Consolidadas.xlsm`): `valor_contrato` (API) =
  "VGV (Praticado)" (planilha) em **1.869/1.892 propostas (98,8%)**. Achados: **420 propostas**
  que o legado conta como venda viva já são **Distrato** no CRM (o fechamento manual **defasa**);
  status manuais (`Validada`, `Venda distratada`, `Repassada`, `Envio Mega`) **não existem na API**
  (camada de reclassificação manual).

## Documentação no repo
- `REGRAS_NEGOCIO.md` — catálogo de regras (IDs `ING-*`, `DP-*`, `KPI-*`, riscos `R1..R12`):
  origem → camada-destino → reimplementação. `_bi_ref/` = engenharia reversa dos 3 PBIX.
- `MODELO_SEMANTICO.md` — desenho do star schema. `ROADMAP.md` — fases. `SKILL.md` — decisões.
- `CONSULTAR.md` + `consultar.ps1` — como consultar o banco local (psql/pgAdmin/DBeaver).
- `reconciliacao/` — relatórios das reconciliações.

## Como rodar / consultar
1. Subir o banco: `pg.ps1 start`.
2. Reconstruir o warehouse (após a bronze existir): `python aplicar_tudo.py`.
3. Consultar: `.\consultar.ps1` (psql) ou pgAdmin/DBeaver em `localhost:5433`, db `pafil_dw`,
   user `postgres`. Schemas: `bronze` (cru), `silver` (conformado + de-paras), `gold` (star/KPIs).

## Em aberto / próximos passos
- Provisionar a VPS + rodar a **carga completa** (a partir daí a reconciliação de totais fecha).
- Montar o `.pbix` sobre a `gold` (manual).
- Validar **com a gestão** as regras: R1 (def. de venda), R3 (versão de canal/mídia),
  R6 (listas de exceção), R9/R10 (status manuais / defasagem do fechamento).
- Popular as de-paras de planilha pendentes; investigar as 23 divergências de VGV (padrão ~R$ 9,5k).

## Armadilhas conhecidas (para agentes)
- **Bronze local é PARCIAL** → não reconciliar **totais**, só por chave (proposta/idreserva).
- `CREATE OR REPLACE VIEW` no Postgres **não** deixa inserir/renomear coluna no meio — só
  **append** no fim (bateu 2x na construção).
- Console Windows é **cp1252** → scripts que imprimem acentos/→/emoji reconfiguram stdout p/ UTF-8;
  `consultar.ps1` usa `PGCLIENTENCODING=WIN1252`.
- `openpyxl` instalado no venv só para ler os `.xlsm` legados — **fora** do `requirements.txt` da pipeline.
- Credenciais CVCRM e PII real (leads/pessoas): banco só em infra da empresa; token compartilhado deve ser rotacionado.
