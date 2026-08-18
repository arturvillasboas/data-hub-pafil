# CONTEXT — Pafil Data Platform

> **Como usar:** cole este arquivo no início de cada sessão do Claude Code (ele é stateless entre sessões).
> Este documento é o **estado atual e as decisões já fechadas** do projeto. Ele complementa o `Pafil Data Platform.txt`,
> que define o **papel e os princípios** (genérico, sem decisões concretas). Em caso de conflito, este arquivo prevalece
> sobre suposições; o `Pafil Data Platform.txt` prevalece sobre comportamento/postura.

---

## 1. Onde o projeto está

Migração de uma arquitetura frágil e manual (exports CSV diários → Power Query → DAX → Power BI, com **3 PBIX** de modelos
duplicados que **já divergem entre si**) para um data warehouse centralizado em arquitetura medalhão.

A arquitetura **já está definida** e existe um **piloto v1 bastante completo** (ver seção 4). A descoberta de schema, o
DDL bronze e os scripts de ingestão **já estão prontos**. O **único bloqueio real é provisionar o Postgres** — feito isso,
aplica-se o `bronze.sql`, roda-se `--full` e começa a ingestão diária + run paralelo.

---

## 2. Decisões fechadas (não reabrir sem motivo)

| Tema | Decisão | Justificativa |
|---|---|---|
| Engine | **PostgreSQL** (open source) | Requisito fixo do projeto; engine portável, sem lock-in de dados |
| Hospedagem (demo + produção) | **Postgres self-hosted em instância AWS EC2 da EMPRESA** — decisão fechada em 07/ago/2026, substitui a antiga VPS DigitalOcean | TI confirmou licenciamento AWS corporativo já existente que cobre EC2, sem custo adicional de infra; aproveita conta já contratada pela empresa. Postgres continua 100% open source (só o SO/servidor passa a ser da AWS) |
| Hospedagem (produção definitiva — em aberto) | **Manter EC2 self-hosted** ou **migrar p/ um Postgres gerenciado** (RDS/Azure Database) | Gatilho p/ migrar: quando operar o banco (backup/patch/HA) pesar mais que o custo do serviço gerenciado, OU governança exigir um único provedor. Reversível: re-apontar connection string + re-aplicar `bronze.sql` + `--full` |
| Arquitetura | Medalhão **bronze / silver / gold** | Bronze = próximo da origem, sem regra de negócio; silver = limpeza/padronização/dedup/conformação; gold = indicadores oficiais, fatos e dimensões |
| Transformação | **dbt Core** — **adiado** até o schema estabilizar | Não faz sentido modelar dbt sobre schema ainda em descoberta |
| Orquestração | **GitHub Actions ou cron** | Airflow descartado como over-engineering para a escala atual |
| Migração | **Strangler-fig** — extrações PBIX antigas rodam em paralelo até reconciliação número-a-número confirmar a nova pipeline | Trocar o sistema sem big-bang |
| Reporting | **Power BI Pro** (trial; compra de 1 seat pendente de validação do projeto). Service → Postgres na EC2 via **On-premises Data Gateway** (não expor o banco publicamente) | — |

> **NÃO usar Neon/Supabase nem a VPS pessoal do chefe.** A primeira é nuvem de terceiros com PII; a segunda mistura dado de cliente da empresa com workflow pessoal (n8n/"Paty") = problema de LGPD/governança.

---

## 3. Fonte de dados — CVCRM / CVDW

- CRM imobiliário brasileiro. Subdomínio do cliente: **`pafil.cvcrm.com.br`**.
- Hoje acessado por **exports CSV manuais diários** (a ser substituído por ingestão Python via API).
- **19 objetos/endpoints mapeados:**
  `reservas`, `contratos`, `comissoes`, `historico/situacoes`, `condicoes`, `leads`, `infos`, `conversoes`,
  `comissoes/pagamentos`, `precadastros`, e dimensões: `unidades`, `corretores`, `imobiliarias`, `pessoas`,
  `campos_adicionais`, `vendas`, `distratos`.

### Restrições da API (projetar a ingestão em torno disto)
- **Paginação:** 500 registros por página.
- **Rate limit:** 20 requisições/minuto → resposta **429** e **bloqueio de 60s**.
- **Auth:** headers estáticos de **email + token**.
- **Incremental:** parâmetro **`a_partir_data_referencia`**.

---

## 4. O que já existe (piloto v1 — pronto)

O piloto **v1** já entrega, validado contra a API viva:

- **`cvdw_descoberta_schema.py`** — descoberta de schema. Infere tipos (datas/decimais BR), nullability; gera
  `cvdw_schema_report.md` + **`cvdw_schema.json`** (~199 KB, 19 objetos já descobertos). Aceita env vars **`CVDW_*`** e **`CVCRM_*`**.
- **`gerar_ddl_bronze.py`** + **`sql/bronze/bronze.sql`** (~64 KB) — DDL bronze gerado e revisado.
- **`ingestao.py`** — modos **full + incremental + snapshots diários**.
- **Camadas silver/gold** (`sql/silver`, `sql/gold` + `aplicar_*.py`) — star schema pronto p/ o Power BI.
- **Modelo semântico (star schema)** documentado; **workflow GitHub Actions** pronto.

> Roda na máquina do vp / na instância EC2 — **não** no sandbox do Claude (precisa bater na API viva).
> **Atenção:** o zip do v1 incluía o `.venv`; verificar se também vazou um `.env` com token vivo (ver seção 7).

---

## 5. Princípios operacionais da migração

- Os **3 PBIX já discordam entre si**. A migração é a chance de estabelecer **um número autoritativo**, não um risco de
  introduzir nova discrepância.
- **Divergência durante o run paralelo é ACHADO, não falha.** O sistema antigo **não** é baseline limpa.
- Toda medida DAX / transformação Power Query / relacionamento / tabela calculada existente é **potencial regra de negócio
  corporativa** → mapear, documentar e migrar com cuidado (ver seção Governança do charter).

---

## 6. Próximos passos

1. **Provisionar instância AWS EC2 no nome da empresa** (licenciamento já confirmado pela TI) e instalar PostgreSQL.
2. Blindar o Postgres: porta fechada à internet, SSL/TLS, security group com allowlist de IP, backup criptografado.
3. Aplicar `sql/bronze/bronze.sql` na instância EC2.
4. Rodar `ingestao.py --full` → carga inicial.
5. **Reconciliação número-a-número** (nova pipeline vs. os 3 PBIX antigos) — este é o demo que vende o projeto.
6. Agendar ingestão incremental diária (GitHub Actions/cron).
7. Instalar **On-premises Data Gateway** na instância EC2 para o Power BI Service alcançar o banco.
8. Fechar a camada **dbt Core** quando o schema estabilizar.
9. Case para seat Power BI Pro + decisão produção (manter EC2 self-hosted vs. RDS/Azure gerenciado) com a pipeline já provada.

### Perguntas em aberto
- Confirmar se o "relatório de séries" mapeia para **`reservas/condicoes`** (tentativo).
- Campos custom **`cf_*`** em `leads`: como o v1 já rodou a descoberta contra a API viva, provavelmente **já estão no
  `cvdw_schema.json`**. Verificar antes de tratar como pendência:
  `grep -o '"cf_[a-zA-Z0-9_]*"' cvdw_schema.json | sort -u`

---

## 7. Segurança & LGPD

- **O token da API compartilhado anteriormente deve ser ROTACIONADO.** Verificar também se o zip do v1 trouxe um `.env`
  com token vivo e se esse zip foi commitado em algum lugar.
- Token e email **nunca** vão para o repositório. Usar `.env` (com `.env.example` versionado) + segredos do GitHub Actions.
- **PII de clientes reais** nos dados (`leads`, `pessoas`). Por isso: banco **só** em infra da empresa (EC2 no nome da
  empresa ou serviço gerenciado), **nunca** em conta pessoal/tier free de terceiros nem dividindo box com workflow pessoal.
- Postgres self-hosted = **você é o DBA**: backup, patching de segurança, firewall, monitoramento são sua responsabilidade.

### 7.1 Onde cada segredo mora (desde a versionamento no GitHub, ago/2026)

| Segredo | Onde mora | Nunca vai para |
|---|---|---|
| `CVCRM_TOKEN`/`CVCRM_EMAIL` | `.env` local + GitHub Actions Secrets | Repositório, logs, mensagens, PRs |
| `PG_PASSWORD` (EC2/produção) | `.env` local (dev) + GitHub Actions Secrets | Repositório |
| `PG_PASSWORD` (instância local de dev) | `.env` local — senha de instância descartável, sem exposição de rede além de `localhost` | Ainda assim, só documentada em `CONSULTAR.md`/`powerbi/README.md` porque o repo é **privado**; se a visibilidade mudar, trocar a senha e redigir os docs |
| Caminhos de planilha (`DEPARA_*_XLSX/XLSM`) | `.env` local — específicos de máquina, não segredo em si | `.env.example` (usa placeholder) |

### 7.2 Política de rotação de token

- Rotacionar o `CVCRM_TOKEN` sempre que: (a) ele tiver circulado fora do `.env`
  (chat, e-mail, print), (b) alguém sair do time com acesso ao `.env`, ou
  (c) por rotina, pelo menos 1x/ano.
- Rotação: gerar novo token no painel do CVCRM → atualizar `.env` local →
  atualizar o secret `CVCRM_TOKEN` em Settings → Secrets do repositório GitHub →
  confirmar que a próxima execução do workflow `ingestao-diaria.yml` passou.

### 7.3 Regra geral de clone/dado local

PII real só deve existir em (a) infra da empresa (EC2/gerenciado) ou (b) a instância
local de dev **enquanto for necessária para desenvolver** — não deixar clones
"esquecidos" com carga completa em notebooks pessoais além do que o trabalho do
dia exige. Ver `ARCHITECTURE.md` seção 5 para o detalhamento por componente.