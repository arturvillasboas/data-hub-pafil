# Onboarding — do zero até uma query na `gold`

> Para quem está pegando o projeto pela primeira vez (novo dev, ou você mesmo numa
> máquina nova). Assume Windows + PowerShell (ambiente atual do projeto); os passos
> de Python/Postgres valem para Linux/macOS com ajustes triviais de caminho.

## 1. Clonar e montar o ambiente

```powershell
git clone <url-do-repo-privado>
cd v2
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## 2. Preencher o `.env`

```powershell
Copy-Item .env.example .env
```

Depois edite o `.env` com os valores reais. De onde vem cada um:

| Variável | De onde vem |
|---|---|
| `CVCRM_SUBDOMINIO`/`CVCRM_EMAIL`/`CVCRM_TOKEN` | Peça um token de API ao administrador do CVCRM da Pafil (subdomínio `pafil`). **Nunca** reuse um token que já circulou fora do `.env` — gere um novo. |
| `PG_*` | Depende de onde você vai rodar (ver seção 3: local ou VPS). |
| `DEPARA_*_XLSX`/`XLSM`, `VENDAS_CONSOLIDADAS_XLSM` | Caminhos para planilhas do SharePoint **COMERCIAL**, sincronizadas via OneDrive na sua máquina. Peça acesso à pasta `BI - Comercial / Relatórios Comercial` ao time comercial/backoffice; depois de sincronizado, aponte para o caminho local do OneDrive. Ver inventário completo em `DEPARAS.md`. |

Sem as planilhas, o pipeline **bronze→silver→gold ainda funciona** (as tabelas
de-para só ficam vazias/desatualizadas) — não é bloqueante para começar.

## 3. Subir um Postgres

### Opção A — instância local de dev (recomendada para começar)

Se sua máquina não tem direitos de admin (caso comum aqui), crie uma instância
**user-space** com `initdb` (não precisa instalar nada, não usa o serviço 5432 do
sistema):

```powershell
$bin = "C:\Program Files\PostgreSQL\16\bin"   # ajuste se a versão instalada for outra
$data = "$env:LOCALAPPDATA\pafil_pg\data"
& "$bin\initdb.exe" -D $data -U postgres -A scram-sha-256 --pwfile=<arquivo-ascii-sem-BOM-com-a-senha> -E UTF8
Add-Content "$data\postgresql.conf" "`nport = 5433"
```

Suba com `pg_ctl start -D $data` (ou monte um wrapper `pg.ps1`, ver
`local-postgres-userspace` nas notas do projeto). Aponte `.env`:
`PG_HOST=localhost`, `PG_PORT=5433`, `PG_SSLMODE=disable`.

> A instância cai no logoff/reboot — é normal, é só validação local. Guia completo
> de consulta: `CONSULTAR.md`.

### Opção B — conectar direto na VPS de produção

Se a VPS já estiver provisionada (ver `ARCHITECTURE.md` seção 3) e você tiver
acesso liberado (túnel SSH ou IP allowlisted — a porta do Postgres nunca fica
aberta à internet), aponte `PG_HOST`/`PG_PORT`/`PG_SSLMODE=require` para lá.
**Cuidado:** isso é o banco real, com PII de clientes — evite rodar experimentos
destrutivos.

## 4. Construir o warehouse

```powershell
python criar_database.py                 # cria o database, se ainda não existir
python ingestao.py --full --criar-tabelas # bronze.sql + carga completa da API
python aplicar_tudo.py                    # silver -> gold -> seeds (sem planilhas)
# ou, com as planilhas configuradas no .env:
python aplicar_tudo.py --xlsm "$env:VENDAS_CONSOLIDADAS_XLSM"
```

Nas próximas vezes, sem recriar tudo: `python ingestao.py --incremental` para o
dado novo do CRM (silver/gold são views, refletem na hora).

## 5. Validar que deu certo

```powershell
python conferir_carga.py       # compara total da API vs. bronze, objeto a objeto
.\consultar.ps1 -c "SELECT count(*) FROM gold.fato_reservas"
```

Veja `CONSULTAR.md` para o passo a passo completo de exploração (psql, DBeaver/
pgAdmin, consultas de exemplo por camada).

## 6. Mapa de leitura recomendado

1. `CONTEXTO.md` — o porquê de negócio, o que já existe, achados-chave.
2. `ARCHITECTURE.md` — visão técnica de ponta a ponta + infra.
3. `MODELO_SEMANTICO.md` — o desenho do star schema (gold).
4. `REGRAS_NEGOCIO.md` — catálogo de regras herdadas dos PBIX legados.
5. `DEPARAS.md` — inventário dos de-paras e como recarregar.
6. `SKILL.md` — decisões fechadas (não reabrir sem motivo forte).
7. `ROADMAP.md` — fases e o que está pendente agora.
