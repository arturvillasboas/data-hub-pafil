# Contexto e decisões fechadas: Pafil Data Platform

**Como usar este arquivo:** cole seu conteúdo no início de cada sessão do Claude
Code, já que ele não guarda memória entre sessões. Este documento descreve o estado
atual do projeto e as decisões que já foram fechadas. Ele complementa o arquivo
`Pafil Data Platform.txt`, que define o papel e os princípios gerais (mais
genérico, sem decisões concretas). Em caso de conflito entre os dois, este arquivo
prevalece sobre suposições, e o `Pafil Data Platform.txt` prevalece sobre questões
de comportamento e postura.

---

## 1. Onde o projeto está hoje

O projeto migra uma arquitetura frágil e manual (exports diários em CSV, passando
por Power Query e DAX, até chegar ao Power BI, com três PBIX de modelos duplicados
que já divergem entre si) para um data warehouse centralizado, em arquitetura
medalhão.

A arquitetura já está definida, e existe um piloto v1 bastante completo (veja a
seção 4). A descoberta de schema, o DDL da bronze e os scripts de ingestão já estão
prontos. O único bloqueio real hoje é provisionar o Postgres de produção. Assim que
isso acontecer, basta aplicar o `bronze.sql`, rodar a carga `--full` e começar a
ingestão diária, junto com o run em paralelo com o sistema antigo.

---

## 2. Decisões fechadas (não reabrir sem um motivo concreto)

| Tema | Decisão | Justificativa |
|---|---|---|
| Engine de banco | PostgreSQL, open source | Requisito fixo do projeto: uma engine portável, sem lock-in de dados |
| Hospedagem (demo e produção) | Postgres self-hosted numa instância AWS EC2 da própria empresa. Decisão fechada em 7 de agosto de 2026, substituindo a ideia anterior de VPS na DigitalOcean | A TI confirmou um licenciamento AWS corporativo já existente, que cobre a EC2 sem custo adicional de infraestrutura, aproveitando uma conta que a empresa já contratou. O Postgres em si continua 100% open source; só o sistema operacional e o servidor passam a ser da AWS |
| Hospedagem (produção definitiva, ainda em aberto) | Manter o modelo self-hosted na EC2, ou migrar para um Postgres gerenciado (RDS ou Azure Database) | O gatilho para migrar seria quando operar o banco por conta própria (backup, patch, alta disponibilidade) pesar mais do que o custo de um serviço gerenciado, ou quando a governança exigir um único provedor. A decisão é reversível: bastaria reapontar a string de conexão, reaplicar `bronze.sql` e rodar `--full` de novo |
| Arquitetura de dados | Medalhão, com camadas bronze, silver e gold | A bronze fica o mais próxima possível da origem, sem regra de negócio; a silver aplica limpeza, padronização, deduplicação e conformação; a gold entrega os indicadores oficiais, fatos e dimensões |
| Transformação | dbt Core, adiado até o schema estabilizar | Não faz sentido modelar com dbt sobre um schema que ainda está em descoberta |
| Orquestração | GitHub Actions ou cron | O Airflow foi descartado por ser over-engineering para a escala atual do projeto |
| Estratégia de migração | Strangler-fig: as extrações dos PBIX antigos continuam rodando em paralelo até a reconciliação número a número confirmar a pipeline nova | Permite trocar o sistema sem um big-bang, com o antigo e o novo coexistindo até a virada ser segura |
| Reporting | Power BI Pro (hoje em trial; a compra de 1 seat está pendente da validação do projeto). O Power BI Service conecta ao Postgres na EC2 através de um On-premises Data Gateway, para nunca expor o banco publicamente | Sem observações adicionais |

**Duas opções ficam explicitamente descartadas: Neon, Supabase, e a VPS pessoal do
chefe.** A primeira é uma nuvem de terceiros que passaria a guardar dados pessoais
(PII); a segunda misturaria dado de cliente da empresa com um workflow pessoal
(automações de n8n, apelidadas de "Paty"), o que seria um problema de LGPD e de
governança.

---

## 3. Fonte de dados: CVCRM e CVDW

- É um CRM imobiliário brasileiro. O subdomínio do cliente é `pafil.cvcrm.com.br`.
- Hoje o acesso ainda acontece por exports manuais em CSV, todos os dias, um
  processo que está sendo substituído pela ingestão automática em Python via API.
- Já foram mapeados 19 objetos e endpoints: `reservas`, `contratos`, `comissoes`,
  `historico/situacoes`, `condicoes`, `leads`, `infos`, `conversoes`,
  `comissoes/pagamentos`, `precadastros`, além das dimensões `unidades`,
  `corretores`, `imobiliarias`, `pessoas`, `campos_adicionais`, `vendas` e
  `distratos`.

### As restrições da API, que moldam o desenho da ingestão

- **Paginação:** 500 registros por página.
- **Limite de taxa:** 20 requisições por minuto. Passar disso gera uma resposta 429
  e um bloqueio de 60 segundos.
- **Autenticação:** headers estáticos de e-mail e token.
- **Carga incremental:** usa o parâmetro `a_partir_data_referencia`.

---

## 4. O que já existe: o piloto v1, pronto

O piloto v1 já entrega o seguinte, validado contra a API viva:

- `cvdw_descoberta_schema.py`: faz a descoberta de schema, infere os tipos (datas e
  decimais no formato brasileiro) e a nullability de cada campo, e gera
  `cvdw_schema_report.md` junto com `cvdw_schema.json` (cerca de 199 KB, cobrindo
  os 19 objetos já descobertos). Aceita variáveis de ambiente `CVDW_*` e
  `CVCRM_*`.
- `gerar_ddl_bronze.py`, que gerou `sql/bronze/bronze.sql` (cerca de 64 KB), o DDL
  da bronze já revisado.
- `ingestao.py`, com os modos full, incremental e snapshots diários.
- As camadas silver e gold (`sql/silver`, `sql/gold`, mais os scripts
  `aplicar_*.py`), formando um star schema pronto para o Power BI.
- O modelo semântico, em formato de star schema, já documentado, e o workflow do
  GitHub Actions já pronto.

> Esse piloto roda na máquina do analista ou na instância EC2, nunca no sandbox do
> Claude, já que ele precisa bater contra a API viva. Atenção: o zip do v1 incluía
> a pasta `.venv`; vale verificar se ele também vazou um `.env` com um token ativo
> (veja a seção 7).

---

## 5. Princípios operacionais da migração

- Os três PBIX legados já discordam entre si. A migração é a oportunidade de
  estabelecer um número autoritativo único, não um risco de introduzir mais uma
  discrepância.
- Uma divergência encontrada durante o run em paralelo é um achado, não uma falha.
  O sistema antigo não é uma baseline limpa contra a qual comparar.
- Toda medida DAX, toda transformação de Power Query, todo relacionamento e toda
  tabela calculada existente é uma potencial regra de negócio corporativa, que
  precisa ser mapeada, documentada e migrada com cuidado (veja a seção de
  Governança do charter do projeto).

---

## 6. Próximos passos

1. Provisionar a instância AWS EC2 em nome da empresa (o licenciamento já foi
   confirmado pela TI) e instalar o PostgreSQL.
2. Blindar o Postgres: porta fechada para a internet, SSL/TLS, security group com
   lista de IPs liberados, backup criptografado.
3. Aplicar `sql/bronze/bronze.sql` na instância EC2.
4. Rodar `ingestao.py --full` para a carga inicial.
5. Fazer a reconciliação número a número entre a pipeline nova e os três PBIX
   antigos: este é o demo que convence qualquer pessoa de que o projeto funciona.
6. Agendar a ingestão incremental diária, por GitHub Actions ou cron.
7. Instalar o On-premises Data Gateway, para que o Power BI Service consiga
   alcançar o banco na instância EC2.
8. Fechar a camada dbt Core, quando o schema estiver estável.
9. Levar um caso de negócio para o seat do Power BI Pro, e decidir a produção
   definitiva (manter o modelo self-hosted na EC2 ou migrar para RDS/Azure
   gerenciado), já com a pipeline provada.

### Perguntas em aberto

- Confirmar se o "relatório de séries" do sistema legado mapeia para
  `reservas/condicoes` na API (hipótese ainda não confirmada).
- Os campos customizados `cf_*` dentro de `leads`: como o piloto v1 já rodou a
  descoberta contra a API viva, é provável que eles já estejam em
  `cvdw_schema.json`. Vale verificar antes de tratar isso como uma pendência,
  rodando: `grep -o '"cf_[a-zA-Z0-9_]*"' cvdw_schema.json | sort -u`

---

## 7. Segurança e LGPD

- O token de API que já foi compartilhado anteriormente precisa ser rotacionado.
  Vale também verificar se o zip do piloto v1 trouxe um `.env` com um token ativo,
  e se esse zip foi commitado em algum lugar.
- Token e e-mail nunca vão para o repositório. O caminho correto é usar `.env`
  (com um `.env.example` versionado como modelo) e os secrets do GitHub Actions.
- Os dados incluem PII real de clientes (nas entidades `leads` e `pessoas`). Por
  isso, o banco só pode existir em infraestrutura da própria empresa (a EC2 em
  nome da empresa, ou um serviço gerenciado equivalente), nunca em uma conta
  pessoal ou num tier gratuito de terceiros, e nunca dividindo ambiente com um
  workflow pessoal de alguém.
- Um Postgres self-hosted significa que você é o DBA: backup, aplicação de patches
  de segurança, firewall e monitoramento passam a ser responsabilidade nossa.

### 7.1 Onde cada segredo mora (desde que o projeto passou a ser versionado no GitHub, em agosto de 2026)

| Segredo | Onde mora | Nunca vai para |
|---|---|---|
| `CVCRM_TOKEN` e `CVCRM_EMAIL` | `.env` local, mais os Secrets do GitHub Actions | O repositório, os logs, mensagens ou pull requests |
| `PG_PASSWORD` (EC2, produção) | `.env` local em desenvolvimento, mais os Secrets do GitHub Actions | O repositório |
| `PG_PASSWORD` (instância local de desenvolvimento) | Só no `.env` local: é a senha de uma instância descartável, sem exposição de rede além de `localhost` | Mesmo assim, essa senha só é documentada em `CONSULTAR.md` e em `powerbi/README.md` porque o repositório é privado. Se a visibilidade mudar, é preciso trocar a senha e reescrever esses documentos |
| Caminhos de planilha (as variáveis `DEPARA_*_XLSX` e `*_XLSM`) | `.env` local: são específicos de cada máquina, não são segredo em si | O `.env.example`, que usa um placeholder no lugar do caminho real |

### 7.2 Política de rotação de token

- O `CVCRM_TOKEN` deve ser rotacionado sempre que: (a) ele tiver circulado fora do
  `.env`, seja em chat, e-mail ou print de tela; (b) alguém que tinha acesso ao
  `.env` sair do time; ou (c) por rotina, pelo menos uma vez por ano.
- O processo de rotação é: gerar um token novo no painel do CVCRM, atualizar o
  `.env` local, atualizar o secret `CVCRM_TOKEN` em Settings → Secrets do
  repositório no GitHub, e por fim confirmar que a próxima execução do workflow
  `ingestao-diaria.yml` passou sem erro.

### 7.3 Regra geral sobre clones e dado local

Dado pessoal real só deve existir em dois lugares: na infraestrutura da empresa (a
instância EC2, ou um serviço gerenciado equivalente), ou na instância local de
desenvolvimento, e mesmo assim só enquanto ela for necessária para o trabalho do
dia a dia. Não deixe clones "esquecidos" com a carga completa em notebooks
pessoais além do que o trabalho realmente exige. Veja a seção 5 de
`ARCHITECTURE.md` para o detalhamento de onde cada credencial mora, componente por
componente.
