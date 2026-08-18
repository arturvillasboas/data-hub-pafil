# Pipeline de dados Pafil: CVDW → PostgreSQL

Este repositório reúne o pipeline completo de dados comerciais da Pafil, construído
sobre um banco PostgreSQL com arquitetura medalhão (bronze, silver e gold). A camada
bronze é alimentada por um pipeline enxuto em Python (usando `requests` e `psycopg`)
que ingere os dados da API CVDW, o CV Data Warehouse do nosso CRM, o CVCRM. Este
documento é o guia técnico dessa ingestão bronze. As camadas silver e gold já estão
implementadas e têm documentação própria em [`sql/silver/README.md`](sql/silver/README.md)
e [`sql/gold/README.md`](sql/gold/README.md).

```
CVDW API ──► bronze (cópia fiel + snapshot diário) ──► silver ──► gold ──► Power BI
```

Não usamos Spark, Databricks, Airflow nem qualquer orquestrador pesado. É uma carga
em lote (batch) diária de cerca de 19 tabelas do CRM, pequena o suficiente para rodar
com ferramentas simples: cron, GitHub Actions ou, em produção, um systemd timer.

---

## Documentação

Se esta é a primeira vez que você chega ao projeto, comece por `ONBOARDING.md`. Os
demais documentos abaixo cobrem cada parte específica.

| Documento | Conteúdo |
|---|---|
| [`ONBOARDING.md`](ONBOARDING.md) | Comece aqui se for sua primeira vez no projeto: do zero até rodar uma consulta na `gold` |
| [`CONTEXTO.md`](CONTEXTO.md) | O porquê de negócio, o que já existe e os achados mais importantes (um briefing pensado para orientar quem for dar continuidade, humano ou agente de IA) |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Visão técnica de ponta a ponta: topologia de infraestrutura e onde moram os segredos |
| [`MODELO_SEMANTICO.md`](MODELO_SEMANTICO.md) | Desenho do star schema da camada gold |
| [`REGRAS_NEGOCIO.md`](REGRAS_NEGOCIO.md) | Catálogo das regras de negócio herdadas dos três relatórios (PBIX) legados |
| [`DEPARAS.md`](DEPARAS.md) | Inventário dos de-paras (mapeamentos manuais mantidos em planilha) e como recarregar cada um |
| [`SKILL.md`](SKILL.md) | Decisões já fechadas do projeto (não reabrir sem um motivo concreto), segurança e LGPD |
| [`ROADMAP.md`](ROADMAP.md) | Fases do projeto e o que está pendente agora |
| [`CONSULTAR.md`](CONSULTAR.md) | Como consultar o warehouse localmente, por `psql`, DBeaver ou pgAdmin |
| [`RUNBOOK.md`](RUNBOOK.md) | O que fazer quando o ambiente de dev local dá problema, principalmente quando o Postgres da porta 5433 não sobe |
| [`infra/README.md`](infra/README.md) | Runbook de provisionamento do Postgres de produção na instância EC2 |
| [`infra/PEDIDO_TI.md`](infra/PEDIDO_TI.md) | Documento de apoio para levar à reunião com a TI, pedindo o servidor |
| [`powerbi/README.md`](powerbi/README.md) | Kit de consumo do Power BI sobre a camada `gold` |
| [`powerbi/PAGINA_PRECO.md`](powerbi/PAGINA_PRECO.md) | Especificação da página de Preço do BI e como ela foi reconciliada com o relatório legado |
| [`reconciliacao/`](reconciliacao/) | Relatórios que comparam, número a número, os resultados da nova pipeline com os relatórios PBIX antigos |

---

## Estrutura

```
.
├── config/
│   ├── objetos.yml          # lista de objetos (nome_logico -> path -> id): edite aqui
│   └── settings.py          # carrega o .env e monta a configuração
├── cvdw/
│   ├── api.py               # cliente HTTP: autenticação, throttle, tratamento de erro 429, paginação, extração
│   ├── tipos.py              # inferência de tipos no formato brasileiro, nomes de coluna, normalização, hash
│   ├── db.py                 # conexão, introspecção do banco, bulk upsert, snapshot, controle de execução
│   └── log.py                # logging estruturado
├── ingestao.py               # ingere para bronze.<objeto> e bronze.<objeto>_snapshot (dirigido por sql/bronze/bronze.sql)
├── sql/{bronze,silver,gold}  # scripts SQL de cada camada
└── .github/workflows/ingestao-diaria.yml
```

> `descoberta_schema.py` e `gerar_ddl_bronze.py`, os scripts que originalmente
> mapearam a API e geraram o `bronze.sql`, não fazem mais parte do repositório: a API
> já está mapeada e o `bronze.sql` resultante é a fonte da verdade versionada. Veja a
> seção "Adicionando ou alterando objetos" mais abaixo, caso a API mude no futuro.

## Como funciona, em linhas gerais

- **Descoberta.** Bate uma vez em cada objeto da API (buscando uma página pequena),
  infere o tipo de cada campo (incluindo números e datas em formato brasileiro que
  chegam como texto), guarda um exemplo de valor e se o campo aceita nulo, desce um
  nível em campos aninhados e detecta qual é a chave de negócio de cada objeto
  (validando que ela é realmente única na amostra coletada).
- **Geração do DDL.** Transforma o schema descoberto em comandos `CREATE TABLE`, um
  por objeto, dentro do schema `bronze`. Usa tipos seguros (`text`, `timestamptz`,
  `numeric`, `boolean`, `jsonb`), cria uma chave técnica própria (`_id_tecnico`) e um
  índice único (`ux_<objeto>_chave`) que é o alvo do upsert.
- **Ingestão.** É dirigida pelo catálogo do próprio banco: o script lê os tipos de
  coluna e a chave de upsert direto do PostgreSQL, em vez de depender de um arquivo
  externo. Por isso o `sql/bronze/bronze.sql` é a única fonte da verdade do schema, e
  o JSON gerado pela descoberta (que fica fora do controle de versão) não é necessário
  para rodar a ingestão no dia a dia.

### Estado atual e snapshot diário

A API do CVDW só devolve o estado atual dos dados, nunca o histórico. Por isso o
pipeline mantém duas versões de cada objeto:

- `bronze.<objeto>`: o estado atual, mantido por upsert usando a chave de negócio (ou
  o `_hash_linha`, quando o objeto não tem um identificador único).
- `bronze.<objeto>_snapshot`: um histórico que só cresce (append only). A cada
  execução, o snapshot do dia é regravado como uma cópia do estado atual, carimbado
  com a coluna `_data_snapshot`. Rodar a ingestão duas vezes no mesmo dia não duplica
  nada, apenas substitui o snapshot daquele dia. É esse histórico que viabiliza
  análises de série temporal (SCD) lá na silver.

### Idempotência

Rodar a ingestão mais de uma vez não causa duplicação, por três motivos:

- O upsert pela chave (id do objeto ou `_hash_linha`) garante que reexecuções
  atualizam a mesma linha em vez de inserir uma nova.
- O snapshot do dia é sempre apagado e regravado por completo, então continua
  existindo só um snapshot por dia.
- A tabela `bronze._ingestao_controle` guarda a última data de referência processada
  em cada objeto, usada para calcular o recorte incremental do dia seguinte.

---

## Instalação

Requer Python 3.10 ou mais recente (testado em 3.12).

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

Todos os segredos vêm exclusivamente do ambiente: do `.env` local, em desenvolvimento,
ou dos secrets do CI, em produção. Eles nunca são versionados no repositório.

A tabela abaixo cobre as variáveis usadas pela ingestão bronze em si. Há outras
variáveis, usadas pelos carregadores de de-para (seeds da silver), documentadas em
`DEPARAS.md` e comentadas diretamente no `.env.example`.

| Variável | Obrigatória | Padrão | Descrição |
|---|---|---|---|
| `CVCRM_SUBDOMINIO` | sim | (nenhum) | subdomínio do CVCRM (`https://<sub>.cvcrm.com.br`) |
| `CVCRM_EMAIL` | sim | (nenhum) | e-mail de autenticação, enviado no header da requisição |
| `CVCRM_TOKEN` | sim | (nenhum) | token de autenticação, enviado no header da requisição |
| `CVCRM_HEADER_EMAIL` | não | `email` | nome do header do e-mail (ajuste se a API responder 401 ou 403) |
| `CVCRM_HEADER_TOKEN` | não | `token` | nome do header do token (ajuste se a API responder 401 ou 403) |
| `CVDW_MAX_REQ_POR_MINUTO` | não | `18` | limite de requisições por minuto (o limite real da API é 20) |
| `CVDW_REGISTROS_POR_PAGINA` | não | `500` | registros por página (o máximo aceito pela API é 500) |
| `CVDW_TIMEOUT` | não | `60` | timeout de cada requisição HTTP, em segundos |
| `CVDW_BUFFER_INCREMENTAL_HORAS` | não | `24` | margem de segurança subtraída da última marca de tempo, na carga incremental |
| `PG_HOST` | sim | (nenhum) | host do Postgres. Em desenvolvimento é `localhost` (instância local, ver `ONBOARDING.md`); em produção também é `localhost`, porque o acesso passa por um túnel até a instância EC2 (ver `infra/README.md`) |
| `PG_PORT` | não | `5432` | porta do Postgres (em dev local costuma ser `5433`, para não colidir com um Postgres já instalado na máquina) |
| `PG_DB` | sim | (nenhum) | nome do banco |
| `PG_USER` | sim | (nenhum) | usuário de conexão |
| `PG_PASSWORD` | sim | (nenhum) | senha de conexão |
| `PG_SSLMODE` | não | `require` | modo de SSL da conexão. Em `localhost` (dev, ou produção via túnel) use `disable`, já que o tráfego não sai da máquina |
| `BRONZE_SCHEMA` | não | `bronze` | schema de destino no banco |

---

## Uso, na ordem

### 1. Aplicar o DDL da bronze

O schema da API já foi descoberto e o DDL correspondente já está gerado e versionado
em `sql/bronze/bronze.sql`. Não é preciso regerá-lo para rodar o projeto, basta
aplicá-lo no banco:

```bash
psql "host=$PG_HOST port=$PG_PORT dbname=$PG_DB user=$PG_USER sslmode=$PG_SSLMODE" \
  -f sql/bronze/bronze.sql
```

> Alternativa: rodar a ingestão com a flag `--criar-tabelas`, que aplica o
> `bronze.sql` automaticamente antes de carregar os dados.

### 2. Ingerir

```bash
# Carga inicial completa (primeira vez):
python ingestao.py --full --criar-tabelas

# Cargas seguintes (delta diário):
python ingestao.py --incremental

# Limitando a alguns objetos:
python ingestao.py --incremental --objetos reservas,vendas,comissoes
```

Um erro em um objeto não derruba os demais: o processo continua, e ao final aparece
um resumo com o status de cada objeto (OK ou ERRO). Se qualquer objeto tiver falhado,
o processo termina com código de saída diferente de zero, para que um agendador
(cron, GitHub Actions) saiba que algo deu errado.

---

## Agendamento

Hoje, em produção, a ingestão diária roda por um systemd timer instalado na própria
instância EC2 (veja `infra/systemd/` e `infra/README.md`), porque o banco nunca fica
exposto à internet e um runner externo não conseguiria alcançá-lo de forma segura.
As opções abaixo continuam válidas para desenvolvimento local ou para outros cenários
de hospedagem.

### Cron (Linux/servidor)

Editar com `crontab -e`. Exemplo: incremental às 03:10 todo dia.

```cron
# m  h  dom mon dow   comando
10 3  *   *   *   cd /opt/cvdw-ingestao && /opt/cvdw-ingestao/.venv/bin/python ingestao.py --incremental >> /var/log/cvdw_ingestao.log 2>&1
```

> O `.env` na raiz do projeto é carregado automaticamente. Garanta que o usuário do
> cron tenha permissão de leitura nele.

### Windows (Agendador de Tarefas)

```powershell
schtasks /Create /TN "CVDW Ingestao Diaria" /SC DAILY /ST 03:10 ^
  /TR "cmd /c cd /d C:\caminho\projeto && .venv\Scripts\python.exe ingestao.py --incremental >> cvdw_ingestao.log 2>&1"
```

### GitHub Actions

O workflow [`.github/workflows/ingestao-diaria.yml`](.github/workflows/ingestao-diaria.yml)
existe pronto para rodar o incremental diariamente (06:00 UTC, por volta de 03:00 no
horário de Brasília) e também aceita disparo manual (aba *Run workflow*, escolhendo
`full` ou `incremental`). Ele só funciona, porém, se os secrets `PG_*` apontarem para
um host alcançável pela internet, o que hoje não é o caso do banco de produção. Por
isso, na prática, este workflow serve apenas como um disparo manual de emergência; o
caminho real da ingestão diária é o systemd timer da EC2, descrito acima.

Caso precise reativá-lo de fato (por exemplo, apontando para um banco de teste
alcançável), configure em **Settings → Secrets and variables → Actions**:

- **Secrets**: `CVCRM_SUBDOMINIO`, `CVCRM_EMAIL`, `CVCRM_TOKEN`, `PG_HOST`,
  `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASSWORD`.
- **Variables** (opcionais): `CVCRM_HEADER_EMAIL`, `CVCRM_HEADER_TOKEN`,
  `PG_SSLMODE`, `BRONZE_SCHEMA`.

---

## Decisões de design

- **Tipagem leve na bronze.** A cópia é o mais fiel possível ao dado de origem; a
  tipagem forte e a limpeza ficam para a silver. Na dúvida, o tipo escolhido é
  `text`. Campos aninhados viram `jsonb`.
- **Hash da linha (`_hash_linha`).** Serve de chave de upsert para objetos que não
  têm um id único (por exemplo, históricos, condições e campos adicionais),
  garantindo idempotência mesmo sem uma chave natural.
- **Snapshot a partir da tabela atual.** O snapshot diário é montado via SQL, como um
  retrato completo do estado do dia, sem precisar de chamadas extras à API.
- **Ingestão dirigida pelo catálogo do banco.** Os tipos de coluna e a chave de
  upsert vêm do próprio PostgreSQL, não de um arquivo à parte. Isso faz do
  `bronze.sql` a única fonte da verdade do schema.
- **Resiliência.** Throttle por janela deslizante, uma tentativa extra automática
  quando a API responde 429 (limite excedido), isolamento de falhas por objeto e um
  resumo ao final da execução.

## Adicionando ou alterando objetos

Um drift pequeno (a API passou a devolver colunas novas em um objeto que já existia)
não exige nenhuma ação especial: a ingestão avisa nos logs e ignora as colunas
desconhecidas. Para incorporá-las de fato, edite `sql/bronze/bronze.sql` à mão,
adicionando a coluna nova.

Já para mapear um objeto totalmente novo (a API do CVDW passou a expor um endpoint
que não existia antes), os scripts que faziam essa descoberta automaticamente,
`descoberta_schema.py` e `gerar_ddl_bronze.py`, não fazem mais parte deste
repositório: eram ferramentas de uso único, criadas para o momento em que a
estrutura da API ainda era desconhecida. Eles continuam disponíveis localmente na
máquina do analista, fora do controle de versão. Se for preciso remapear algo,
basta rodá-los de novo apontando para o objeto novo em `config/objetos.yml` e colar
o DDL gerado dentro de `sql/bronze/bronze.sql`.
