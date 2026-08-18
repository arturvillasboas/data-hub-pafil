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
| Postgres | Instância **user-space** na porta 5433, `%LOCALAPPDATA%\pafil_pg` — sem admin, volátil, cai no logoff | **Instância AWS EC2 da empresa** (`sa-east-1`), always-on, porta do Postgres **nunca exposta** à internet |
| Ingestão bronze (`ingestao.py`) | Rodada manualmente da máquina do dev | **systemd timer na própria EC2** (`infra/systemd/`), diário às 03:00 BRT — conexão `localhost`, sem segredo `PG_*` fora da instância |
| Seeds de-para (`popular_seeds.py`) | Rodada manualmente, lê planilhas OneDrive sincronizadas localmente | **Continua manual**, rodada da máquina do dev (ver seção 4 — é uma fronteira real, não um débito técnico) |
| Power BI | Conecta direto no Postgres local (`localhost:5433`) | Desktop via **túnel** (SSM/SSH) → e, para atualização agendada no Service, **On-premises Data Gateway num host Windows** (ver nota abaixo) |
| Credenciais | `.env` local (gitignored) | `.env` local (dev) + `/etc/pafil/pafil.env` (0640) na EC2 |

> **Duas armadilhas que o desenho anterior escondia** (identificadas em 12/ago/2026,
> ao preparar a Fase 7):
>
> 1. **GitHub Actions não alcança um banco não exposto.** O workflow
>    `ingestao-diaria.yml` pressupunha `PG_HOST` público com `sslmode=require` — o que
>    contradiz "a porta 5432 nunca é liberada". Runner hospedado tem IP dinâmico numa
>    faixa pública enorme; "liberar só o runner" é liberar meio mundo. Por isso a
>    ingestão diária passou para um **systemd timer na própria EC2**. O workflow
>    permanece apenas como disparo manual de emergência.
> 2. **O On-premises Data Gateway só roda em Windows.** Ele não pode morar numa EC2
>    Linux. Ou se instala num host Windows always-on que alcance a instância pela rede
>    privada, ou a atualização agendada no Power BI Service fica adiada (o Desktop
>    continua funcionando por túnel). Decisão pendente com a TI — `infra/PEDIDO_TI.md`
>    seção 4c.

## 3. Provisionamento e hardening da EC2

O runbook executável mora em **[`infra/`](infra/README.md)** — esta seção é só o resumo
das decisões. A instância ainda **não** foi provisionada (`ROADMAP.md`, decisão em
aberto #1); o pedido formal à TI é [`infra/PEDIDO_TI.md`](infra/PEDIDO_TI.md).

**Specs do pedido:** EC2 em `sa-east-1` (São Paulo), 2 vCPU / 4 GB RAM, 50 GB EBS `gp3`,
always-on, Ubuntu 22.04/24.04 LTS **ou** Amazon Linux 2023 (a definir com a TI —
`infra/provisionar_postgres.sh` cobre os dois). Instância **dedicada**, no padrão de
tag da empresa; nunca a VPS pessoal usada para outros workflows (n8n etc.) — decisão
fechada em `SKILL.md` seção 2, por LGPD/PII.

**Decisões de segurança:**
1. **A porta 5432 nunca entra no Security Group.** Acesso do analista por túnel (port
   forwarding do SSM ou SSH); acesso do Power BI, quando houver gateway, liberado por
   **referência ao SG de origem** — nunca por IP público.
2. Acesso administrativo por **SSM Session Manager** (sem porta 22, autenticado por IAM,
   auditado no CloudTrail). Alternativa aceitável: SSH por chave + allowlist de IP fixo,
   com `PasswordAuthentication no`.
3. Patches de segurança automáticos (`unattended-upgrades` / `dnf-automatic`).
4. **PostgreSQL 16**, mesma major do ambiente local — divergência de major entre dev e
   produção é divergência de dialeto, o tipo de bug que só aparece em produção.
5. Senhas **geradas na própria instância** (`openssl rand`) e gravadas em arquivo 0600
   do root — nunca em argumento de comando, histórico de shell ou repositório.
6. Duas roles: `pafil_app` (dona do banco, ingestão e DDL) e `pafil_bi` (somente leitura
   sobre gold/silver — a **bronze fica fora**, é onde a PII está em estado bruto).
7. Backup: `pg_dump -Fc` diário às 02:30 com retenção de 7 dias (+ S3 opcional), além do
   snapshot EBS. O dump é o que protege contra erro **lógico** — e é indispensável
   porque, embora a bronze seja reconstruível pela API com `--full`, os **seeds de-para
   não são**: vêm de planilha mantida à mão.

**Aplicar o schema e migrar (reaproveita os scripts já prontos, só reaponta o `.env`):**
```bash
python criar_database.py                       # cria o banco, se necessário
python ingestao.py --full --criar-tabelas      # bronze.sql + carga completa real
python aplicar_tudo.py                         # silver -> gold -> seeds
python conferir_carga.py                       # valida origem (API) vs bronze
```

> Rodar a carga **full na própria instância**, dentro de `tmux`: são ~777 mil registros
> contra uma API limitada a ~18 req/min, ou seja, horas — não faz sentido depender do
> notebook do analista ficar acordado.

## 4. Fronteira arquitetural: de-paras continuam manuais

Os loaders de de-para (`popular_seeds.py --gerentes / --headcount-corretores /
--leads-apoio / --etapa-precadastro / --credito-manual / --xlsm`) leem **planilhas do
SharePoint/OneDrive da empresa** via caminho de arquivo local (variáveis
`DEPARA_*_XLSX`/`XLSM` no `.env`). Isso só funciona numa máquina com o OneDrive
sincronizado — uma EC2 Linux não tem esse contexto.

**Decisão adotada:** a ingestão diária da **bronze** roda 100% automatizada (systemd
timer na EC2, sem depender de nenhuma máquina de pessoa). A atualização dos
**de-paras** (silver/seeds) continua um passo **manual, periódico**, rodado da máquina
do analista responsável, apontando o `PG_*` do `.env` para o Postgres da EC2 via
**túnel** (SSM/SSH) — nunca abrindo a porta do banco publicamente.

Isso não é um débito técnico a "resolver" — é uma fronteira real enquanto as
planilhas fonte (Vendas Consolidadas, headcount, de-para de gerentes, etc.) forem
mantidas manualmente pelo backoffice. Se essas planilhas migrarem para um sistema com
API/export automatizável no futuro, essa fronteira pode ser eliminada.

## 5. Onde cada segredo mora

Ver `SKILL.md` seção 7 (Segurança & LGPD) para a política completa. Resumo:

| Segredo | Onde mora | Nunca vai para |
|---|---|---|
| `CVCRM_TOKEN`/`CVCRM_EMAIL` | `.env` local (dev) + `/etc/pafil/pafil.env` (0640) na EC2 | Repositório, logs, mensagens |
| `PG_PASSWORD` (produção) | Gerada na EC2 → `/root/pafil_credenciais.txt` (0600) → `/etc/pafil/pafil.env` + `.env` local do analista | Repositório, GitHub Secrets |
| `PG_PASSWORD` (local dev) | `.env` local — senha de instância descartável, sem exposição de rede | — (risco aceito, ver nota abaixo) |
| Caminhos de planilha (`DEPARA_*`) | `.env` local — não são segredo, mas são específicos de máquina | `.env.example` (usa placeholder) |

> **Nota:** a senha do Postgres local de dev (`PafilLocalDev2026`) aparece documentada
> em `CONSULTAR.md` e `powerbi/README.md` de propósito — é uma instância descartável,
> sem admin, sem exposição fora de `localhost`, recriável do zero a qualquer momento
> (ver `local-postgres-userspace` na memória do projeto). Ainda assim, isso só é
> aceitável porque o repositório é **privado**; se a visibilidade mudar, essa senha
> precisa ser trocada e os docs, redigidos.
