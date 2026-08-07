# Roadmap — Dados CVCRM → Power BI (plano faseado)

Plano ajustado após o alinhamento com a gestão (jun/2026). Objetivo: **entregar
valor já**, sem depender de infra de terceiros, **sem abrir mão do histórico** no
médio prazo.

> Contexto da decisão: a gestão pediu para simplificar e não depender de VPS
> pessoal (a infra precisa ser da Pafil, sem risco de corte por pagamento). Ao
> mesmo tempo, a API do CVDW **só devolve o estado atual** — então o histórico
> (tendências, comparativos no tempo) **só existe se nós o guardarmos**. O
> faseamento abaixo concilia os dois pontos.

---

## Fase 0 — Demo / entrega rápida (SEM infra)  ✅ pronto
- **O quê:** Power BI conectado **direto na API do CVDW** (Power Query), para
  painéis que precisam apenas do **estado atual**.
- **Entrega:** `demo/powerbi_bronze_demo.m` + fluxograma de apresentação.
- **Por que:** mostra valor imediato, zero infraestrutura, valida o interesse
  da gestão.
- **Limite consciente:** sem histórico, sem snapshot, sujeito ao limite de
  20 req/min da API (manter poucas tabelas/refresh espaçado).

## Fase 1 — Infra própria da Pafil (governança)  ⏳ VPS ainda não solicitada
- **O quê:** **Postgres self-hosted em VPS no nome da empresa** (DigitalOcean Ubuntu,
  separada da VPS pessoal/n8n) — decisão fechada (ver `SKILL.md` seção 2, que prevalece
  em caso de conflito). Azure Database for PostgreSQL (gerenciado) fica como opção de
  **produção futura**, em aberto — gatilho: quando operar o banco (backup/patch/HA)
  pesar mais que pagar a Microsoft, ou governança exigir tenant Microsoft único.
  Reversível: re-apontar connection string + reaplicar `bronze.sql` + `--full`.
- **Por que:** barata, da empresa, sem assinatura paga, sem fricção de procurement;
  always-on serve a reconciliação diária melhor que Docker local; stack 100% open
  source (alinhado ao charter).
- **Resultado:** preencher `PG_*` no `.env` com o host/porta da VPS (acesso só via
  SSH tunnel/allowlist de IP — porta do Postgres nunca exposta à internet).

## Fase 2 — Bronze + ingestão (histórico)  🟡 código pronto, aguarda Fase 1
- **O quê:** apontar `PG_*` para o banco da Pafil, aplicar `sql/bronze/bronze.sql`
  e rodar `ingestao.py --full --criar-tabelas`; depois `--incremental` agendado
  (cron/GitHub Actions).
- **Por que:** garante o **snapshot diário** (histórico que a API não guarda) e
  performance (sem martelar a API a cada refresh).
- **Status:** descoberta concluída (19/19), `bronze.sql` gerado e revisado.

## Fase 3 — Silver (limpeza / tipagem forte)  🔜 futuro
- Padronização de datas/valores (formato BR), deduplicação, e os ajustes de
  tipagem já mapeados: forçar TEXT em identificadores (CEP/CPF/CNPJ/RG/
  documento/código) e re-descoberta com amostra maior para acertar valores/datas
  que vieram vazios em 10 linhas.
- **Insumo:** [`REGRAS_NEGOCIO.md`](REGRAS_NEGOCIO.md) — catálogo das regras dos PBIX
  legados (engenharia reversa em `../_bi_ref/`). A Silver implementa as regras `ING-*`
  (limpeza) e materializa as `DP-*` (de-paras) como seeds.

## Fase 4 — Gold + Power BI definitivo  🟡 gold pronta; falta montar o .pbix
- ✅ Star schema implementado (`sql/gold/`): `fato_reservas`, `fato_leads`,
  `fato_precadastros` + dims (calendário, empreendimento, unidade, corretor). Agregados
  (rankings, mídia, esteira, funis) ficam no Power BI sobre a fato.
- ✅ Kit de consumo em [`powerbi/`](powerbi/README.md): `.pbids` de conexão,
  `MEDIDAS_GOLD.dax` (KPIs reimplementados) e guia de relacionamentos.
- ✅ **Reconciliação prova o paralelo:** distratos maio/2026 idêntico ao centavo;
  vendas (VGV Praticado) 98,8% das propostas idênticas (`reconciliacao/`).
- 🔜 Montar o `.pbix` sobre a gold (passo manual no Desktop) e, no run de produção,
  reapontar o `.pbids`/gateway para a VPS com a carga completa.

> **Reconstruir o warehouse num banco novo (após a bronze):** `python aplicar_tudo.py`
> (silver → gold → seeds). Com `--xlsm "<Vendas Consolidadas.xlsm>"` popula também
> o de-para de produtos.

---

## Decisões em aberto
1. Solicitar a VPS da empresa (DigitalOcean) e provisionar o Postgres (Fase 1) —
   ver `ARCHITECTURE.md` para specs recomendadas e runbook de hardening.
2. Rodar `ingestao.py --full --criar-tabelas` na VPS e validar os primeiros dados
   (Fase 2) — a carga local hoje é parcial (~4.756 de ~6.000+ reservas reais).
3. Reconciliar totais com os relatórios PBIX existentes (validação do paralelo).
4. Definir como os de-paras de planilha (OneDrive/SharePoint) serão atualizados
   depois que a fonte deixar de ser a máquina local (ver `ARCHITECTURE.md`).
