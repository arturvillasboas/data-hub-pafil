# Arquitetura — Pafil Data Platform

> Visão consolidada de ponta a ponta: de onde o dado vem, como ele é transformado, onde
> mora, e como o Power BI consome. Complementa `CONTEXTO.md` (o "porquê" de negócio),
> `MODELO_SEMANTICO.md` (o desenho do star schema) e `SKILL.md` (decisões fechadas).

## 1. Visão de ponta a ponta

```mermaid
flowchart LR
    subgraph Fonte
        CVCRM[("CVCRM API\n(CVDW)")]
        Planilhas[["Planilhas SharePoint/OneDrive\n(de-paras, Vendas Consolidadas)"]]
    end

    subgraph Postgres["PostgreSQL — arquitetura medalhão"]
        Bronze[("bronze\ncópia fiel + snapshot diário")]
        Silver[("silver\nviews conformadas + seeds de-para")]
        Gold[("gold\nstar schema: fatos + dimensões")]
        Bronze --> Silver --> Gold
    end

    CVCRM -- "ingestao.py\n(full / incremental)" --> Bronze
    Planilhas -- "popular_seeds.py\n(manual, periódico)" --> Silver

    Gold -- "On-premises Data Gateway" --> PBI[["Power BI\n(Desktop / Service)"]]
    PBI --> Apresentacao["Apresentação mensal\nde fechamento"]
```

## 2. Topologia de infraestrutura

| Componente | Hoje (dev) | Alvo (produção) |
|---|---|---|
| Postgres | Instância **user-space** na porta 5433, `%LOCALAPPDATA%\pafil_pg` — sem admin, volátil, cai no logoff | **VPS da empresa** (DigitalOcean Ubuntu), always-on, porta do Postgres **nunca exposta** à internet |
| Ingestão bronze (`ingestao.py`) | Rodada manualmente da máquina do dev | **GitHub Actions** (`.github/workflows/ingestao-diaria.yml`), cron diário — já parametrizado via secrets, só falta a VPS existir |
| Seeds de-para (`popular_seeds.py`) | Rodada manualmente, lê planilhas OneDrive sincronizadas localmente | **Continua manual**, rodada da máquina do dev (ver seção 4 — é uma fronteira real, não um débito técnico) |
| Power BI | Conecta direto no Postgres local (`localhost:5433`) | **On-premises Data Gateway** instalado na própria VPS → Power BI Service |
| Credenciais | `.env` local (gitignored) | `.env` local (dev) + **GitHub Actions Secrets** (CI) + variáveis de ambiente na VPS |

## 3. Provisionamento e hardening da VPS (runbook)

Preparado para quando a VPS for solicitada (`ROADMAP.md`, decisão em aberto #1).

**Specs recomendadas para o pedido:**
- DigitalOcean Droplet, Ubuntu 22.04/24.04 LTS.
- 2 vCPU / 4GB RAM (carga atual ~777 mil linhas — não é big data; redimensionar se
  necessário depois de medir).
- Região próxima ao Brasil (nyc1/tor1 costumam ter latência menor que fra1 para o
  tráfego CVCRM/Power BI a partir do Brasil).
- Disco 50-80GB.
- Nome/tag no padrão da empresa; **separada** da VPS pessoal usada para outros
  workflows (n8n etc.) — decisão fechada (`SKILL.md` seção 2), por LGPD/PII.

**Hardening (checklist ao configurar):**
1. Usuário não-root dedicado; SSH **só por chave** (desabilitar login por senha em
   `sshd_config`: `PasswordAuthentication no`).
2. `ufw`: negar tudo por padrão, liberar só SSH (idealmente com allowlist de IP fixo,
   se o dev tiver IP estável) e a porta do gateway do Power BI. **A porta do Postgres
   (5432) nunca é liberada para a internet** — acesso só via túnel SSH ou, futuramente,
   o On-premises Data Gateway rodando na própria máquina.
3. `unattended-upgrades` habilitado (patches de segurança automáticos).
4. Instalar **PostgreSQL 16** (mesma versão major do ambiente local — evita
   divergência de dialeto/funções entre dev e produção).
5. Backup: `pg_dump` agendado (cron) para um bucket/volume separado — a definir
   frequência conforme criticidade (o dado é reconstruível a partir da API CVDW via
   `--full`, mas os **seeds de-para não são** — eles vêm de planilha manual).

**Aplicar o schema e migrar (reaproveita scripts já prontos, só reaponta o `.env`):**
```bash
python criar_database.py                       # cria o banco, se necessário
python ingestao.py --full --criar-tabelas       # bronze.sql + carga completa real
python aplicar_tudo.py                          # silver -> gold -> seeds
python conferir_carga.py                        # valida origem (API) vs bronze
```

## 4. Fronteira arquitetural: de-paras continuam manuais

Os loaders de de-para (`popular_seeds.py --gerentes / --headcount-corretores /
--leads-apoio / --etapa-precadastro / --credito-manual / --xlsm`) leem **planilhas do
SharePoint/OneDrive da empresa** via caminho de arquivo local (variáveis
`DEPARA_*_XLSX`/`XLSM` no `.env`). Isso só funciona numa máquina com o OneDrive
sincronizado — uma VPS Ubuntu não tem esse contexto.

**Decisão adotada:** a ingestão diária da **bronze** roda 100% automatizada (GitHub
Actions/cron, sem depender de nenhuma máquina específica). A atualização dos
**de-paras** (silver/seeds) continua um passo **manual, periódico**, rodado da máquina
do analista responsável, apontando o `PG_*` do `.env` para o Postgres da VPS (via
túnel SSH ou IP allowlisted — nunca abrindo a porta do banco publicamente).

Isso não é um débito técnico a "resolver" — é uma fronteira real enquanto as
planilhas fonte (Vendas Consolidadas, headcount, de-para de gerentes, etc.) forem
mantidas manualmente pelo backoffice. Se essas planilhas migrarem para um sistema com
API/export automatizável no futuro, essa fronteira pode ser eliminada.

## 5. Onde cada segredo mora

Ver `SKILL.md` seção 7 (Segurança & LGPD) para a política completa. Resumo:

| Segredo | Onde mora | Nunca vai para |
|---|---|---|
| `CVCRM_TOKEN`/`CVCRM_EMAIL` | `.env` local + GitHub Actions Secrets | Repositório, logs, mensagens |
| `PG_PASSWORD` (VPS) | `.env` local (dev) + GitHub Actions Secrets | Repositório |
| `PG_PASSWORD` (local dev) | `.env` local — senha de instância descartável, sem exposição de rede | — (risco aceito, ver nota abaixo) |
| Caminhos de planilha (`DEPARA_*`) | `.env` local — não são segredo, mas são específicos de máquina | `.env.example` (usa placeholder) |

> **Nota:** a senha do Postgres local de dev (`PafilLocalDev2026`) aparece documentada
> em `CONSULTAR.md` e `powerbi/README.md` de propósito — é uma instância descartável,
> sem admin, sem exposição fora de `localhost`, recriável do zero a qualquer momento
> (ver `local-postgres-userspace` na memória do projeto). Ainda assim, isso só é
> aceitável porque o repositório é **privado**; se a visibilidade mudar, essa senha
> precisa ser trocada e os docs, redigidos.
