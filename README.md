# Ingestão CVDW → Bronze (PostgreSQL)

Pipeline enxuto (Python + `requests` + `psycopg`) para ingerir dados da API do
**CVDW** (CV Data Warehouse do CVCRM) num PostgreSQL seguindo **arquitetura
medalhão**. Este repositório cobre **descoberta de schema + camada bronze +
ingestão**. As camadas *silver* e *gold* virão depois (pastas já reservadas).

```
CVDW API ──► bronze (cópia fiel + snapshot diário) ──► silver ──► gold ──► Power BI
                         (este projeto)
```

Sem Spark, Databricks, Airflow ou orquestrador pesado: é batch diário de ~19
tabelas de CRM. Agendamento por **cron** ou **GitHub Actions**.

---

## Documentação

| Doc | O quê |
|---|---|
| [`ONBOARDING.md`](ONBOARDING.md) | **Comece aqui** se é a primeira vez — do zero até uma query na `gold` |
| [`CONTEXTO.md`](CONTEXTO.md) | O porquê de negócio, o que já existe, achados-chave (briefing p/ agentes de IA) |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Visão técnica de ponta a ponta, topologia de infra, runbook da VPS, onde moram os segredos |
| [`MODELO_SEMANTICO.md`](MODELO_SEMANTICO.md) | Desenho do star schema (camada gold) |
| [`REGRAS_NEGOCIO.md`](REGRAS_NEGOCIO.md) | Catálogo de regras de negócio herdadas dos 3 PBIX legados |
| [`DEPARAS.md`](DEPARAS.md) | Inventário dos de-paras (mapeamentos manuais) e como recarregar cada um |
| [`SKILL.md`](SKILL.md) | Decisões fechadas do projeto (não reabrir sem motivo) + segurança/LGPD |
| [`ROADMAP.md`](ROADMAP.md) | Fases do projeto e o que está pendente agora |
| [`CONSULTAR.md`](CONSULTAR.md) | Como consultar o warehouse localmente (psql/DBeaver/pgAdmin) |
| [`powerbi/README.md`](powerbi/README.md) | Kit de consumo do Power BI sobre a `gold` |

---

## Estrutura

```
.
├── config/
│   ├── objetos.yml          # lista de objetos (nome_logico -> path -> id) — edite aqui
│   └── settings.py          # carrega .env e monta a configuração
├── cvdw/
│   ├── api.py               # cliente HTTP: auth, throttle, 429, paginação, extração
│   ├── tipos.py             # inferência de tipos BR, nomes de coluna, normalização, hash
│   ├── db.py                # conexão SSL, introspecção, bulk upsert, snapshot, controle
│   └── log.py               # logging estruturado
├── ingestao.py              # ingere -> bronze.<obj> + bronze.<obj>_snapshot (dirigido por sql/bronze/bronze.sql)
├── sql/{bronze,silver,gold} # SQL por camada
└── .github/workflows/ingestao-diaria.yml
```

> `descoberta_schema.py` e `gerar_ddl_bronze.py` (os scripts que originalmente
> mapearam a API e geraram o `bronze.sql`) não fazem mais parte do repositório —
> a API já está mapeada e o `bronze.sql` resultante é a fonte da verdade
> versionada. Ver "Adicionando/alterando objetos" abaixo se a API mudar.

## Como funciona (visão rápida)

- **Descoberta** bate 1x em cada objeto (1 página pequena), infere o tipo de
  cada campo (inclui número/data em **formato brasileiro** que vêm como texto),
  captura exemplo e *nullability*, desce **1 nível** em campos aninhados e
  detecta a **chave de negócio** (com validação de unicidade na amostra).
- **DDL** transforma o schema em `CREATE TABLE` por objeto no schema `bronze`,
  com tipos seguros (`text`/`timestamptz`/`numeric`/`boolean`/`jsonb`), chave
  técnica `_id_tecnico` e índice único `ux_<obj>_chave` (alvo do upsert).
- **Ingestão** é **dirigida pelo catálogo do banco**: lê os tipos das colunas e
  a chave de upsert direto do PostgreSQL. Assim o `bronze.sql` é a única fonte
  da verdade e o JSON de descoberta (gitignored) não é necessário em runtime.

### Estado atual vs. snapshot diário

A API só devolve o **estado atual**. Por isso:

- `bronze.<obj>` — **estado atual**, mantido via *upsert* pela chave de negócio
  (ou pelo `_hash_linha` quando não há id único).
- `bronze.<obj>_snapshot` — **histórico append-only**: a cada execução, o
  snapshot **do dia** é regravado como cópia do estado atual, carimbado com
  `_data_snapshot date`. Rodar duas vezes no mesmo dia **não duplica**
  (substitui o snapshot do dia). É o que viabiliza histórico/SCD na silver.

### Idempotência

- Upsert pela chave (id ou `_hash_linha`) → reexecuções não duplicam o estado.
- Snapshot do dia é apagado e regravado → um snapshot por dia.
- A tabela `bronze._ingestao_controle` guarda a **última data de referência**
  por objeto para o incremental do dia seguinte.

---

## Instalação

Requer **Python 3.10+** (testado em 3.12).

```bash
python -m venv .venv
# Windows (PowerShell):
.venv\Scripts\Activate.ps1
# Linux/macOS:
source .venv/bin/activate

pip install -r requirements.txt
cp .env.example .env   # depois edite o .env com suas credenciais
```

## Variáveis de ambiente

Todos os segredos vêm **só** do ambiente (`.env` local ou secrets do CI). Nunca
são versionados.

| Variável | Obrigatória | Padrão | Descrição |
|---|---|---|---|
| `CVCRM_SUBDOMINIO` | sim | — | subdomínio do CVCRM (`https://<sub>.cvcrm.com.br`) |
| `CVCRM_EMAIL` | sim | — | e-mail de autenticação (header) |
| `CVCRM_TOKEN` | sim | — | token de autenticação (header) |
| `CVCRM_HEADER_EMAIL` | não | `email` | nome do header do e-mail (ajuste se der 401/403) |
| `CVCRM_HEADER_TOKEN` | não | `token` | nome do header do token (ajuste se der 401/403) |
| `CVDW_MAX_REQ_POR_MINUTO` | não | `18` | throttle (limite real da API = 20) |
| `CVDW_REGISTROS_POR_PAGINA` | não | `500` | registros por página (máx 500) |
| `CVDW_TIMEOUT` | não | `60` | timeout HTTP (s) |
| `CVDW_BUFFER_INCREMENTAL_HORAS` | não | `24` | margem subtraída da última marca no incremental |
| `PG_HOST` | sim | — | host do Postgres (Azure) |
| `PG_PORT` | não | `5432` | porta |
| `PG_DB` | sim | — | banco |
| `PG_USER` | sim | — | usuário |
| `PG_PASSWORD` | sim | — | senha |
| `PG_SSLMODE` | não | `require` | modo SSL (Azure exige; `require` ou `verify-full`) |
| `BRONZE_SCHEMA` | não | `bronze` | schema de destino |

---

## Uso (na ordem)

### 1. Aplicar o DDL da bronze

O schema da API já foi descoberto e o DDL já está gerado e versionado em
`sql/bronze/bronze.sql` — não é preciso regenerá-lo para rodar o projeto.
Aplique no banco:

```bash
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_DB user=$PG_USER sslmode=require" \
  -f sql/bronze/bronze.sql
```

> Alternativa: rodar a ingestão com `--criar-tabelas`, que aplica o `bronze.sql`
> automaticamente antes de carregar.

### 2. Ingerir

```bash
# Carga inicial completa (primeira vez):
python ingestao.py --full --criar-tabelas

# Cargas seguintes (delta diário):
python ingestao.py --incremental

# Limitando a alguns objetos:
python ingestao.py --incremental --objetos reservas,vendas,comissoes
```

Erro num objeto **não derruba** os outros; ao final há um resumo com OK/ERRO
por objeto (e o processo sai com código ≠ 0 se houve qualquer falha).

---

## Agendamento

### Cron (Linux/servidor)

Editar com `crontab -e`. Exemplo: incremental às 03:10 todo dia.

```cron
# m  h  dom mon dow   comando
10 3  *   *   *   cd /opt/cvdw-ingestao && /opt/cvdw-ingestao/.venv/bin/python ingestao.py --incremental >> /var/log/cvdw_ingestao.log 2>&1
```

> O `.env` na raiz do projeto é carregado automaticamente. Garanta que o cron
> tenha permissão de leitura nele.

### Windows (Agendador de Tarefas)

```powershell
schtasks /Create /TN "CVDW Ingestao Diaria" /SC DAILY /ST 03:10 ^
  /TR "cmd /c cd /d C:\caminho\projeto && .venv\Scripts\python.exe ingestao.py --incremental >> cvdw_ingestao.log 2>&1"
```

### GitHub Actions

O workflow [`.github/workflows/ingestao-diaria.yml`](.github/workflows/ingestao-diaria.yml)
roda incremental diariamente (06:00 UTC ≈ 03:00 BRT) e aceita disparo manual
(*Run workflow* → escolher `full`/`incremental`).

Configure em **Settings → Secrets and variables → Actions**:

- **Secrets**: `CVCRM_SUBDOMINIO`, `CVCRM_EMAIL`, `CVCRM_TOKEN`, `PG_HOST`,
  `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASSWORD`.
- **Variables** (opcionais): `CVCRM_HEADER_EMAIL`, `CVCRM_HEADER_TOKEN`,
  `PG_SSLMODE`, `BRONZE_SCHEMA`.

> O runner do GitHub precisa de rede até o Azure Postgres. Se o servidor tiver
> firewall, libere os IPs do GitHub Actions ou use um self-hosted runner.

---

## Decisões de design

- **Tipagem leve na bronze**: cópia o mais fiel possível; a tipagem forte e a
  limpeza ficam para a silver. Na dúvida, `text`. Aninhados viram `jsonb`.
- **Hash da linha** (`_hash_linha`): chave de upsert para objetos sem id único
  (ex.: históricos, condições, campos adicionais), garantindo idempotência.
- **Snapshot a partir da tabela atual** (via SQL): retrato *point-in-time*
  completo a cada dia, sem chamadas extra à API.
- **Ingestão dirigida pelo catálogo**: tipos e chave de upsert vêm do próprio
  banco; o `bronze.sql` é a fonte da verdade do schema.
- **Resiliência**: throttle por janela deslizante, retry único em 429,
  isolamento de falhas por objeto e resumo final.

## Adicionando/alterando objetos

Drift pequeno (a API passou a devolver colunas novas num objeto já mapeado) não
exige nada: a ingestão avisa nos logs e ignora as colunas desconhecidas —
edite `sql/bronze/bronze.sql` à mão para adicionar a coluna.

Para mapear um objeto **novo** do zero (a API do CVDW passou a expor um
endpoint que não existia), os scripts que faziam isso (`descoberta_schema.py` +
`gerar_ddl_bronze.py`) não estão mais neste repositório — eram ferramentas de
uma única vez, usadas quando a estrutura da API ainda era desconhecida. Eles
continuam disponíveis localmente na máquina do dev (fora do controle de
versão); se precisar remapear algo, é só rodá-los de novo apontando pro objeto
novo em `config/objetos.yml` e colar o DDL gerado em `sql/bronze/bronze.sql`.
