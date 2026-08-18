# Onboarding: do zero até uma consulta na gold

Este guia é para quem está pegando o projeto pela primeira vez, seja uma pessoa nova
no time ou você mesmo configurando uma máquina nova. Ele assume Windows com
PowerShell, que é o ambiente atual do projeto. Os passos de Python e Postgres valem
também para Linux ou macOS, com pequenos ajustes de caminho.

## 1. Clonar o repositório e montar o ambiente

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

Depois, edite o `.env` com os valores reais. Aqui está de onde vem cada um:

| Variável | De onde vem |
|---|---|
| `CVCRM_SUBDOMINIO`, `CVCRM_EMAIL`, `CVCRM_TOKEN` | Peça um token de API ao administrador do CVCRM da Pafil (o subdomínio é `pafil`). Nunca reaproveite um token que já circulou fora de um `.env`: gere sempre um novo. |
| `PG_*` | Depende de onde você vai rodar o banco. Veja a seção 3 abaixo, que cobre tanto a instância local quanto a de produção. |
| `DEPARA_*_XLSX`, `DEPARA_*_XLSM`, `VENDAS_CONSOLIDADAS_XLSM` | São caminhos para planilhas do SharePoint do time Comercial, sincronizadas via OneDrive na sua máquina. Peça acesso à pasta "BI - Comercial / Relatórios Comercial" ao time comercial ou ao backoffice. Depois de sincronizada, aponte a variável para o caminho local do OneDrive. O inventário completo dessas planilhas está em `DEPARAS.md`. |

Sem essas planilhas configuradas, o pipeline inteiro (bronze, silver e gold)
continua funcionando normalmente. Só as tabelas de-para ficam vazias ou
desatualizadas. Ou seja, isso não é um bloqueio para começar a explorar o projeto.

## 3. Subir um Postgres

### Opção A: instância local de desenvolvimento (recomendada para começar)

Se sua máquina não tem direitos de administrador, o que é o caso mais comum aqui,
você pode criar uma instância em modo "user space" usando `initdb`. Isso não exige
instalar nada como serviço, e não usa a porta 5432 que já pertence ao serviço do
sistema:

```powershell
$bin = "C:\Program Files\PostgreSQL\16\bin"   # ajuste se a versão instalada for outra
$data = "$env:LOCALAPPDATA\pafil_pg\data"
& "$bin\initdb.exe" -D $data -U postgres -A scram-sha-256 --pwfile=<arquivo-ascii-sem-BOM-com-a-senha> -E UTF8
Add-Content "$data\postgresql.conf" "`nport = 5433"
```

Suba a instância com `pg_ctl start -D $data`, ou monte um script wrapper chamado
`pg.ps1` (veja a memória do projeto sobre o Postgres local em user space para o
modelo pronto). Depois, aponte o `.env` assim: `PG_HOST=localhost`, `PG_PORT=5433`,
`PG_SSLMODE=disable`.

> É normal essa instância cair a cada logoff ou reinício: ela serve só para
> validação local, não é um serviço permanente. Para subi-la de novo, e para os
> casos em que o `start` falha, veja o passo a passo em
> [`RUNBOOK.md`](RUNBOOK.md). O guia completo de como consultar o banco está em
> `CONSULTAR.md`.

### Opção B: conectar direto na instância de produção (EC2)

Se a instância EC2 já estiver provisionada (veja a seção 3 de `ARCHITECTURE.md`) e
você já tiver acesso liberado, seja por túnel SSM ou SSH (a porta do Postgres nunca
fica aberta diretamente para a internet), aponte `PG_HOST`, `PG_PORT` e
`PG_SSLMODE=require` para lá.

**Cuidado:** esse é o banco real, com dados pessoais de clientes de verdade. Evite
rodar ali qualquer experimento que possa ser destrutivo.

## 4. Construir o warehouse

```powershell
python criar_database.py                 # cria o banco, se ainda não existir
python ingestao.py --full --criar-tabelas # aplica bronze.sql + faz a carga completa da API
python aplicar_tudo.py                    # roda silver, gold e seeds (sem as planilhas)
# ou, já com as planilhas configuradas no .env:
python aplicar_tudo.py --xlsm "$env:VENDAS_CONSOLIDADAS_XLSM"
```

Nas próximas vezes, não é preciso recriar tudo do zero: basta rodar
`python ingestao.py --incremental` para trazer o dado novo do CRM. Como silver e
gold são views, elas refletem essa atualização na hora, sem nenhum passo extra.

## 5. Validar que deu tudo certo

```powershell
python conferir_carga.py       # compara o total da API com o total na bronze, objeto a objeto
.\consultar.ps1 -c "SELECT count(*) FROM gold.fato_reservas"
```

Veja `CONSULTAR.md` para o passo a passo completo de exploração do banco, incluindo
uso de `psql`, DBeaver, pgAdmin e uma coleção de consultas de exemplo por camada.

## 6. Mapa de leitura recomendado

Depois de rodar o ambiente com sucesso, esta é a ordem sugerida para entender o
projeto em profundidade:

1. `CONTEXTO.md`: o porquê de negócio por trás do projeto, o que já existe e os
   achados mais importantes até agora.
2. `ARCHITECTURE.md`: a visão técnica de ponta a ponta, incluindo a infraestrutura.
3. `MODELO_SEMANTICO.md`: o desenho do star schema usado na camada gold.
4. `REGRAS_NEGOCIO.md`: o catálogo de regras de negócio herdadas dos relatórios
   PBIX legados.
5. `DEPARAS.md`: o inventário dos de-paras e como recarregar cada um.
6. `SKILL.md`: as decisões já fechadas do projeto, que não devem ser reabertas sem
   um motivo forte.
7. `ROADMAP.md`: as fases do projeto e o que está pendente agora.
