# Contexto do projeto: Pafil Data Platform

Este é um texto de contexto, pensado para que qualquer pessoa (ou agente de IA) que
chegue ao projeto sem conhecimento prévio consiga entender rapidamente o objetivo, o
que já foi construído e o estado atual das coisas. O diretório de trabalho ativo é
`v2/`.

## Objetivo

O projeto migra a área de BI (business intelligence) da Pafil, uma construtora e
incorporadora imobiliária, de uma arquitetura manual e frágil para um data warehouse
moderno.

A arquitetura manual atual funciona assim: todo dia alguém exporta um CSV do CRM para
o SharePoint, que alimenta consultas no Power Query e medidas em DAX dentro de três
relatórios (PBIX) diferentes, que já divergem entre si. O destino é uma arquitetura
medalhão: os dados saem do CVCRM pela API CVDW, passam por Python, chegam a um banco
PostgreSQL organizado em camadas bronze, silver e gold, e desembocam no Power BI.

O princípio de governança que guia esse trabalho é simples de enunciar e trabalhoso
de cumprir: toda medida DAX, todo de-para e toda transformação do sistema legado é
tratada como uma regra de negócio em potencial. Cada uma precisa ser mapeada,
documentada e migrada com cuidado, sempre em busca de "um número autoritativo" único,
em vez dos vários números divergentes que existem hoje.

## Contexto de negócio e o processo manual atual (o porquê do projeto)

A Pafil é uma construtora e incorporadora: o que move a empresa é venda. O dono deste
projeto é o analista de dados full-stack alocado no time Comercial, que responde ao
Igor, o gestor comercial (que também faz a gestão direta de um SDR, além do
analista). O entregável final de todo esse trabalho é a apresentação mensal de
fechamento, a "Reunião de Fechamento", um PPTX apresentado a gestores, corretores,
SDRs, diretores, CEO e marketing, montado pelo próprio analista.

As análises comerciais que compõem essa apresentação são: Vendas Acumuladas (YTD),
Vendas por Mês, Vendas por Empreendimento, segmentação por House e participação de
mercado (como no caso de "HOUSE RPO"), Vendas por Mídia, Ranking de Corretores e
Ranking de Gerentes (por VGV e por unidades vendidas). Hoje, todas essas análises são
montadas às pressas, diretamente no PBIX legado.

**A cadeia manual atual de fechamento**, que é exatamente o que esta pipeline vem
substituir, funciona em quatro passos:

1. Todo dia, alguém extrai manualmente dados do CVCRM e cola numa planilha base
   (apelidada de "a que contém 2024"). Colunas adicionais, "pintadas de cinza" na
   planilha, são preenchidas à mão seguindo regras de negócio. O resultado alimenta a
   planilha "Vendas Consolidadas".
2. O time financeiro envia por e-mail a planilha com os distratos reais do mês, já
   validada, extraída do MEGA.
3. Os distratos recebidos do financeiro são confrontados manualmente com a Vendas
   Consolidadas, e os ajustes necessários são feitos à mão.
4. A Vendas Consolidadas, já manual e validada, alimenta o PBIX, que por sua vez
   alimenta a apresentação mensal.

O MEGA é o banco e sistema central da empresa, usado pelo financeiro, pela
contabilidade e pela maior parte dos processos internos, mas ninguém do time tem
acesso direto aos dados dele: só existe acesso pela interface do sistema e por
relatórios prontos. É por isso que o caminho histórico do BI comercial sempre
dependeu do CVCRM combinado com planilhas manuais.

A pipeline nova, que vai da API do CVCRM até a camada gold, automatiza a perna
CVCRM para Vendas Consolidadas. Isso já está comprovado: a pipeline reproduz a
Vendas Consolidadas em 98,8% dos casos e os distratos batem ao centavo. A validação
dos distratos vindos do financeiro e do MEGA, além de algumas regras manuais,
continuam por enquanto como um passo humano. O objetivo de médio prazo é alimentar
essas análises comerciais diretamente a partir da camada gold (veja
`gold.fato_reservas` e as dimensões relacionadas; o ranking por gerente, por House e
as Vendas por Mídia são montados no Power BI em cima dessa tabela fato, usando a
classificação oficial que vem da Vendas Consolidadas, proposta por proposta).

## Fonte de dados

A fonte é o CRM imobiliário CVCRM (subdomínio `pafil.cvcrm.com.br`), através da API
CVDW, que expõe 20 objetos diferentes (o 20º, `pessoas/profissional`, foi
descoberto só em 24/ago/2026 — ver DP-15 em `REGRAS_NEGOCIO.md`; os outros 19
vieram da descoberta original de schema). A paginação é de 500 registros por página, e o
limite de taxa é de aproximadamente 20 requisições por minuto (passar disso gera erro
429 e um bloqueio de 60 segundos). A autenticação é por e-mail e token, guardados
sempre no `.env` e nunca no repositório. A carga incremental usa o campo
`a_partir_data_referencia`, complementada por snapshots diários.

## Infraestrutura

O banco é PostgreSQL, open source, uma decisão fixa do projeto. Para validação local,
usamos uma instância PostgreSQL em modo "user space" na porta 5433 (não exige
permissão de administrador, já que o serviço da empresa na porta 5432 tem senha
desconhecida para o time). O banco local se chama `pafil_dw`, a senha local é
`PafilLocalDev2026`, e a conexão não usa SSL. Para subir essa instância, o comando é
`%LOCALAPPDATA%\pafil_pg\pg.ps1 start` (ela cai automaticamente a cada logoff, por
não ser um serviço do Windows).

Em produção, o banco já está de pé desde 20 de agosto de 2026, numa máquina Windows
10 Pro física/local da empresa. A ideia original era uma instância AWS EC2 (veja
`infra/PEDIDO_TI.md` para o pedido formal que foi feito), mas a TI acabou passando
credenciais de RDP para essa máquina em vez disso, e confirmou que é o destino
definitivo (não é uma instância AWS: o teste do endereço de metadados da AWS deu
timeout nela). O runbook que reflete essa realidade é `infra/RUNBOOK_WINDOWS.md`.
Duas opções ficam explicitamente descartadas: Neon, Supabase ou qualquer VPS
pessoal, por causa da LGPD e da presença de dados pessoais (PII) no banco.

O dbt Core, ferramenta de transformação de dados citada neste documento em versões
anteriores como adiada até o schema estabilizar, passou a ser adotada em setembro de
2026, junto com o Apache Airflow como orquestrador (também citado antes como
descartado). Essas duas decisões foram revisitadas porque o cenário mudou: a VM
Windows de produção já acumula tarefas manuais via PowerShell que deveriam ser
automatizadas, e um segundo projeto (integração entre o CVCRM e o GoHighLevel)
também depende dessa fundação. Veja `SKILL.md`, seção "Atualizações de setembro de
2026", para o detalhe das duas decisões revisitadas e da ordem de execução.

## O que já está pronto (tudo aplicado e validado no banco local)

- **Bronze** (`sql/bronze/bronze.sql`, `ingestao.py`): 21 tabelas cruas, uma cópia
  fiel de cada objeto da API, mais uma tabela `_snapshot` para cada uma delas.
  Atenção: a carga local hoje é parcial, com 4.756 reservas carregadas contra cerca
  de 1.302 propostas do legado que ainda faltam. A carga completa só vai acontecer
  quando o banco estiver na instância EC2 de produção.
- **Silver** (`sql/silver/silver.sql`, `aplicar_silver.py`): seis views conformadas
  (`reservas`, `vendas`, `distratos`, `unidades`, `corretores`, `imobiliarias`), com
  tipagem forte (datas convertidas de texto para `timestamptz` por funções
  tolerantes a formatos variados, CNPJ e CRECI convertidos para texto padronizado) e
  flags que sinalizam a aplicação de cada regra. A limpeza específica dos CSVs do
  legado (regras `ING-01` a `ING-03`) não foi portada para cá, porque ela existia
  para consertar problemas de exportação manual, e a API já entrega os dados
  estruturados corretamente.
- **Seeds de-para** (`sql/silver/seeds.sql`, `popular_seeds.py`): onze tabelas
  `dpara_*`. Seis delas já estão populadas, decodificando o JSON (comprimido em
  base64 e DEFLATE) que estava embutido no Power Query legado, além da aba
  `DE_PARA_PRODUTOS` de uma planilha xlsm. Ainda faltam popular, a partir de
  planilhas do SharePoint: feriados, profissões, etapa do pré-cadastro e equipe do
  corretor.
- **Gold** (`sql/gold/gold.sql`, `aplicar_gold.py`): o star schema propriamente dito,
  com `fato_reservas` (o cruzamento de reservas com distratos), `fato_leads` e
  `fato_precadastros`, além das dimensões `calendario`, `empreendimento`, `unidade` e
  `corretor`. Agregados, rankings e a esteira comercial ficam por conta do próprio
  Power BI. A conformação do nome de empreendimento usa a função
  `silver.conformar_empreendimento()`, que ignora diferenças de maiúsculas e
  minúsculas.

  Na task 6.4 (agosto de 2026), três tabelas novas entraram na gold:
  `dim_estrutura` (preço e estoque por unidade), `dim_metas_empreendimentos` (metas e
  forecast) e `dim_viabilidade` (parâmetros de margem). Nenhuma dessas três vem da
  API: são input manual da gestão, carregadas pelo `popular_seeds.py` a partir de
  planilhas do SharePoint (`base_precos.xlsm`, `Meta.xlsx` e
  `d_para empreendimentos.xlsx`). As medidas DAX de referência ficam em
  `powerbi/MEDIDAS_ESTOQUE_PRECO.dax`. No mesmo dia, entrou também
  `dim_distratos_2025`, o detalhe financeiro de cada distrato (multa, valor pago,
  devolução, parcelas), extraído de `relatorio_distratos.xlsx`, informação que a API
  também não oferece. Essa dimensão ainda não tem uma chave para se relacionar
  diretamente com `fato_reservas` (veja a regra R2 e a nota correspondente na view).

  Na task 6.5 (12 de agosto de 2026), o BI de Preço foi replicado por completo.
  Foram criadas `gold.dpara_reserva_estrutura` (a ponte entre reserva e unidade da
  matriz de preço, com 3.140 ligações) e uma versão enriquecida de `dim_estrutura`,
  que passou a trazer o realizado no grão da unidade, além dos campos
  `fato_reservas.codigo_estrutura` e `fato_reservas.m2_praticado`. O campo
  `status_unidade` também mudou de comportamento: agora, quando uma unidade sofre
  distrato, ela volta a aparecer como disponível no estoque, seguindo a mesma regra
  do sistema legado (o status antigo, que não fazia essa devolução, ficou preservado
  em `status_unidade_c_distrato`). A especificação completa das páginas está em
  `powerbi/PAGINA_PRECO.md`, e a reconciliação contra o PBIX legado está em
  `reconciliacao/preco_legado_vs_gold.md` (os achados R20, R21 e R22 tratam,
  respectivamente, de viabilidade vazia na origem, de um fator de 1000x errado no
  produto Villa Manacás, e da existência de duas matrizes de preço concorrentes).

  Em setembro de 2026 entrou a série mensal de headcount (DP-16):
  `silver.dpara_corretor_headcount_mensal` e `gold.fato_headcount_mensal`, com uma
  linha por corretor e mês. Ela vem da mesma planilha do backoffice que já
  alimentava o DP-12, carregada na mesma passada do `popular_seeds.py`, e é o que
  destrava a página "Performance" do BI legado: o farol de vendas por corretor e
  todas as medidas de produtividade por mês dependem de saber quantos meses cada
  corretor esteve ativo. Ver `powerbi/PAGINA_PERFORMANCE.md` e
  `powerbi/MEDIDAS_PERFORMANCE.dax`.

  No dia 10 de setembro o headcount do DP-12 ganhou as datas de entrada e saída
  (`dt_contratacao` e `dt_desligamento`, mais o `meses_de_casa` calculado em
  `gold.dim_corretor_headcount`). Com elas, o farol branco de "entrada recente"
  passou a ser tempo de casa de verdade, em vez de ser deduzido da soma de meses
  ativos, e corretor com desligamento já lançado deixou de ser cobrado por venda.

  Na mesma passada, o DP-12 deixou de carregar só os ativos e passou a trazer o
  quadro inteiro do backoffice, 258 nomes, com a coluna `eh_ativo`. O motivo é que as
  linhas da matriz de Performance vêm dessa dimensão: com só os ativos, corretor
  desligado no meio do ano sumia da tela enquanto as vendas dele continuavam no
  Total, pela linha em branco do relacionamento (eram três corretores e 12 das 77
  vendas do ano). O join de `gold.dim_corretor` com o headcount passou a exigir
  `eh_ativo`, de propósito, para que nada mude nas páginas que já estão no ar.

- **Orquestrador**: `aplicar_tudo.py` roda silver, gold e seeds em um único comando.
- **Power BI**: a pasta `powerbi/` reúne o arquivo de conexão (`.pbids`), o
  `MEDIDAS_GOLD.dax` e um guia de uso. O `.pbix` propriamente dito ainda não foi
  montado, já que essa é uma etapa manual, feita no Power BI Desktop.

## A regra mais importante do projeto (R1)

A palavra "venda" tem duas definições diferentes no sistema legado: uma considera só
o status `Vendida`, e outra considera `Vendida` e `Distrato` juntos. A pipeline expõe
as duas (`eh_venda` e `eh_venda_ou_distrato`), mas decidir qual delas é a definição
autoritativa não é uma questão técnica: é uma decisão que cabe à gestão.

## Reconciliações: a prova de que a pipeline nova reproduz a antiga

Essas reconciliações são, na prática, o argumento que convence qualquer pessoa de que
o projeto funciona.

- **Distratos de maio de 2026** (comparando `reconciliar_distratos.py` com o CSV
  legado `rel_distratos`): bate ao centavo. São 54 distratos dos dois lados, com o
  mesmo VGV de R$ 12.888.599,11.
- **Vendas** (comparando `reconciliar_vendas.py` com a planilha
  `Vendas Consolidadas.xlsm`): o campo `valor_contrato`, vindo da API, é idêntico ao
  campo "VGV (Praticado)" da planilha em 1.869 das 1.892 propostas, ou seja, 98,8%
  dos casos. Entre os achados dessa comparação: 420 propostas que o fechamento
  manual ainda trata como venda viva já aparecem como Distrato no CRM (sinal de que o
  fechamento manual está sempre um pouco atrasado em relação à realidade); e alguns
  status usados manualmente na planilha (`Validada`, `Venda distratada`, `Repassada`,
  `Envio Mega`) simplesmente não existem na API, porque pertencem a uma camada de
  reclassificação feita à mão.

## Documentação no repositório

- `REGRAS_NEGOCIO.md`: o catálogo de regras de negócio, identificadas por códigos
  (`ING-*` para ingestão, `DP-*` para de-paras, `KPI-*` para indicadores e `R1` a
  `R12` para riscos conhecidos), cada uma descrevendo a origem no legado, a camada de
  destino na pipeline nova, e como foi reimplementada. A pasta `_bi_ref/` guarda a
  engenharia reversa dos três PBIX antigos.
- `MODELO_SEMANTICO.md` descreve o desenho do star schema. `ROADMAP.md` traz as
  fases do projeto. `SKILL.md` reúne as decisões já fechadas.
- `CONSULTAR.md`, junto com o script `consultar.ps1`, explica como consultar o banco
  local usando `psql`, pgAdmin ou DBeaver.
- `reconciliacao/` guarda os relatórios completos de cada reconciliação.

## Como rodar e consultar o projeto

1. Suba o banco local com `pg.ps1 start`.
2. Depois que a bronze já existir, reconstrua o warehouse inteiro com
   `python aplicar_tudo.py`.
3. Para consultar, use `.\consultar.ps1` (que abre um `psql`) ou conecte pelo pgAdmin
   ou DBeaver em `localhost:5433`, banco `pafil_dw`, usuário `postgres`. Os schemas
   disponíveis são `bronze` (dado cru), `silver` (conformado, com os de-paras já
   aplicados) e `gold` (o star schema com os indicadores).

## Em aberto: próximos passos

- Confirmar o status da carga completa em produção (feita na máquina Windows real,
  não na EC2 que este texto previa — ver `infra/RUNBOOK_WINDOWS.md`) e, a partir
  daí, se a reconciliação de totais já fecha de verdade (antes, ela só era válida
  por chave, comparando proposta a proposta ou reserva a reserva, por causa da carga
  parcial local).
- Montar o `.pbix` sobre a camada gold (etapa manual).
- Validar com a gestão as regras ainda em aberto: R1 (a definição oficial de venda),
  R3 (qual versão de canal e mídia usar), R6 (as listas de exceção) e R9/R10 (os
  status manuais e o atraso do fechamento em relação à realidade).
- Popular os de-paras que ainda dependem de planilha. Investigar as 23 divergências
  de VGV identificadas na reconciliação, que seguem um padrão de aproximadamente
  R$ 9,5 mil cada.

## Armadilhas conhecidas (útil para quem for continuar o trabalho)

- A bronze local é parcial. Por isso, nunca reconcilie totais agregados, apenas
  comparações por chave individual, como proposta ou `idreserva`.
- No PostgreSQL, um `CREATE OR REPLACE VIEW` não permite inserir ou renomear uma
  coluna no meio da definição existente: só é possível adicionar colunas no final.
  Isso já causou retrabalho duas vezes durante a construção do projeto.
- O console do Windows usa a codificação cp1252 por padrão. Por isso, scripts que
  imprimem acentos, setas ou qualquer caractere fora do padrão ASCII precisam
  reconfigurar a saída padrão para UTF-8. O `consultar.ps1`, por exemplo, usa a
  variável `PGCLIENTENCODING=WIN1252` para lidar com isso.
- O pacote `openpyxl` lê os arquivos `.xlsx`/`.xlsm` dos seeds manuais
  (`popular_seeds.py`). Ficou de fora do `requirements.txt` por um tempo, por não
  ser dependência da ingestão em si (`ingestao.py`) — decisão que voltou atrás em
  25/ago/2026, quando `popular_seeds.py` rodou pela primeira vez direto na máquina
  de produção (`RUNBOOK_WINDOWS.md`) e quebrou com `ModuleNotFoundError`: o `pip
  install -r requirements.txt` de lá nunca tinha o pacote, só o ambiente local do
  dev (instalado à mão, fora do arquivo). Agora está no `requirements.txt`.
- As credenciais do CVCRM e os dados pessoais reais (leads e pessoas) exigem cuidado
  redobrado: o banco só pode existir em infraestrutura da própria empresa, e o token
  de API que já foi compartilhado em algum momento deve ser rotacionado.
