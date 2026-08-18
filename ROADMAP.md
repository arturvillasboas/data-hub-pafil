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

## Fase 1 — Infra própria da Pafil (governança)  ⏳ EC2 ainda não provisionada
- **O quê:** **Postgres self-hosted em instância AWS EC2 da empresa** — decisão fechada
  em 07/ago/2026 (TI confirmou licenciamento AWS corporativo já existente que cobre
  EC2, sem custo adicional de infra; ver `SKILL.md` seção 2, que prevalece em caso de
  conflito). **Substitui a opção anterior de VPS DigitalOcean.** Um Postgres gerenciado
  (RDS/Azure Database) fica como opção de **produção futura**, em aberto — gatilho:
  quando operar o banco (backup/patch/HA) pesar mais que o custo do serviço gerenciado.
  Reversível: re-apontar connection string + reaplicar `bronze.sql` + `--full`.
- **Por que:** aproveita uma licença AWS que a empresa já paga, sem fricção de
  procurement; always-on serve a reconciliação diária melhor que Docker local; o
  Postgres em si continua 100% open source (só o SO/servidor passa a ser da AWS).
- **Resultado:** preencher `PG_*` no `.env` com o host/porta da instância EC2 (acesso
  só via túnel SSM/SSH — porta do Postgres nunca exposta à internet pública).
- **Preparação concluída (12/ago/2026):** runbook executável e scripts em
  [`infra/`](infra/README.md) — provisionamento do Postgres 16 (Ubuntu **e** AL2023),
  tuning, `pg_hba` só-local, roles `pafil_app`/`pafil_bi`, backup diário, systemd timer
  da ingestão e grants do Power BI. O pedido formal para a TI é
  [`infra/PEDIDO_TI.md`](infra/PEDIDO_TI.md). Falta apenas a instância existir.

## Fase 2 — Bronze + ingestão (histórico)  🟡 código pronto, aguarda Fase 1
- **O quê:** apontar `PG_*` para o banco da Pafil, aplicar `sql/bronze/bronze.sql`
  e rodar `ingestao.py --full --criar-tabelas`; depois `--incremental` agendado
  (cron/GitHub Actions).
- **Por que:** garante o **snapshot diário** (histórico que a API não guarda) e
  performance (sem martelar a API a cada refresh).
- **Status:** descoberta concluída (19/19), `bronze.sql` gerado e revisado.

## Fase 3 — Silver (limpeza / tipagem forte)  ✅ pronta, validada localmente
- **O quê:** `sql/silver/silver.sql` + `aplicar_silver.py` — 6 views conformadas
  (`reservas`, `vendas`, `distratos`, `unidades`, `corretores`, `imobiliarias`) com
  tipagem forte (datas/documentos) e as seeds de-para (`sql/silver/seeds.sql`,
  `popular_seeds.py`). Também cobre leads/pré-cadastros (`silver.leads`,
  `silver.precadastros`, `silver.leads_conversoes`).
- **Insumo:** [`REGRAS_NEGOCIO.md`](REGRAS_NEGOCIO.md) — catálogo das regras dos PBIX
  legados (engenharia reversa em `../_bi_ref/`). A Silver implementa as regras `ING-*`
  (limpeza) e materializa as `DP-*` (de-paras) como seeds.
- **Falta:** rodar contra a carga completa (Fase 2 na EC2) — hoje só validada com a
  carga local parcial; e popular os de-paras que ainda vêm de planilha SharePoint
  (feriados, profissões, etapa de crédito).

## Fase 4 — Gold + Power BI definitivo  🟡 gold pronta; falta montar o .pbix
- ✅ Star schema implementado (`sql/gold/`): `fato_reservas`, `fato_leads`,
  `fato_precadastros` + dims (calendário, empreendimento, unidade, corretor). Agregados
  (rankings, mídia, esteira, funis) ficam no Power BI sobre a fato.
- ✅ Kit de consumo em [`powerbi/`](powerbi/README.md): `.pbids` de conexão,
  `MEDIDAS_GOLD.dax` (KPIs reimplementados) e guia de relacionamentos.
- ✅ **Reconciliação prova o paralelo:** distratos maio/2026 idêntico ao centavo;
  vendas (VGV Praticado) 98,8% das propostas idênticas (`reconciliacao/`).
- 🔜 Montar o `.pbix` sobre a gold (passo manual no Desktop) e, no run de produção,
  reapontar o `.pbids`/gateway para a instância EC2 com a carga completa.

> **Reconstruir o warehouse num banco novo (após a bronze):** `python aplicar_tudo.py`
> (silver → gold → seeds). Com `--xlsm "<Vendas Consolidadas.xlsm>"` popula também
> o de-para de produtos.

---

## Decisões em aberto
1. Provisionar a instância AWS EC2 da empresa e instalar o Postgres (Fase 1) —
   runbook pronto em [`infra/README.md`](infra/README.md); pedido em
   [`infra/PEDIDO_TI.md`](infra/PEDIDO_TI.md). **Pendente da TI:** sistema operacional
   (Ubuntu LTS vs Amazon Linux 2023) e forma de acesso (SSM vs SSH por chave).
2. Rodar `ingestao.py --full --criar-tabelas` na EC2 e validar os primeiros dados
   (Fase 2) — a carga local hoje é parcial (~4.756 de ~6.000+ reservas reais).
3. Reconciliar totais com os relatórios PBIX existentes (validação do paralelo).
4. Definir como os de-paras de planilha (OneDrive/SharePoint) serão atualizados
   depois que a fonte deixar de ser a máquina local (ver `ARCHITECTURE.md`).
5. **Onde mora o On-premises Data Gateway.** Ele só roda em **Windows**, então não
   cabe numa EC2 Linux — o desenho anterior (gateway "na própria VPS") não fecha.
   Opções: host Windows always-on que a empresa já tenha (custo zero), segunda EC2
   Windows pequena, ou adiar (o Desktop segue funcionando por túnel; só a atualização
   agendada no Service fica bloqueada). Não bloqueia as etapas 7.2–7.4.
