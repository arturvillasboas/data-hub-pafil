# Catálogo de regras de negócio da Pafil Data Platform

Este catálogo reúne o inventário das regras de negócio corporativas extraídas dos
três relatórios PBIX legados (a engenharia reversa completa está em
[`../_bi_ref/`](../_bi_ref)). Cada regra registra a origem, a lógica aplicada, as
dependências, a camada de destino na arquitetura medalhão e notas sobre como ela foi
ou será reimplementada.

Este catálogo existe porque o charter do projeto define um princípio simples: toda
medida DAX, toda transformação de Power Query e todo relacionamento é uma regra de
negócio em potencial, que precisa ser mapeada, documentada e migrada com cuidado. Os
três PBIX legados já divergem entre si, e este catálogo é o primeiro passo para
estabelecer um número autoritativo único.

Ele serve de ponte para duas frentes de trabalho: as camadas silver e gold
reimplementam cada regra marcada como "a implementar", e o processo de reconciliação
confere os KPIs marcados como autoritativos contra os números dos PBIX antigos.

As fontes usadas para montar este catálogo foram `_bi_ref/RESUMO_Empreendimentos.md`
(o modelo "Matriz", do BI Comercial), `_bi_ref/RESUMO_BIPreco.md` (o modelo "Preço")
e `_bi_ref/M_Empreendimentos.md` (Power Query e de-paras).

## Legenda

Ao longo deste catálogo, cada regra recebe uma ou mais marcações entre parênteses,
com o seguinte significado:

| Marcação | Significado |
|---|---|
| (KPI) | Indicador autoritativo: candidato a reconciliação número a número contra o PBIX legado |
| (a implementar) | Regra ainda pendente de reimplementação em Silver ou Gold |
| (descartar) | Não é regra de negócio, é formatação ou interface (ícones, cores, HTML). Não migra para a nova pipeline |
| (atenção) | Risco, armadilha ou divergência conhecida, que exige cuidado |
| (concluído) | Regra já reimplementada e validada |
| (crítico) | Problema sério, ainda sem solução |

## Mapa de origem para destino (visão de uma página)

```
LEGADO (PBIX)                          NOVA PIPELINE (medalhão)
─────────────────────────────         ──────────────────────────────────
CSV SharePoint relatorios_*.csv  ──►   BRONZE  (cvdw.* via API, já pronto)
Power Query (limpeza, filtros)   ──►   SILVER  (tipagem, dedup, conformação)
de-paras embutidas (.xlsx/JSON)  ──►   SILVER  (tabelas lookup / seed)
Modelo + relacionamentos         ──►   GOLD    (star schema: fatos + dimensões)
Medidas DAX (VGV, distrato...)   ──►   GOLD    (views/medidas oficiais)
Ícones/cores/HTML em DAX         ──►   (descartado: é apresentação)
```

**Um achado estrutural importante:** no sistema legado, tudo nasce de CSVs e
planilhas Excel mantidos manualmente no SharePoint
(`pafilconstrutora.sharepoint.com/.../BI - Comercial`), não da API. A pipeline nova
substitui essa origem pela camada bronze, alimentada pela API CVDW. Isso significa
que boa parte das regras de limpeza do Power Query existia só para consertar
defeitos do export manual, e várias delas podem simplesmente deixar de ser
necessárias agora que a origem é uma API estruturada (veja a seção 1). Esse ganho,
sozinho, já é parte do valor da migração.

---

## 1. Regras de ingestão e limpeza (Power Query para Silver)

Estas regras vêm das partições M (Power Query) de `f_reservas`, `f_vendas`,
`f_distratos` e `d_estrutura`, e existem para consertar problemas do CSV exportado
manualmente. Vale avaliar, uma a uma, quais delas ainda fazem sentido agora que a
origem passou a ser a API.

| ID | Regra | Origem (legado) | Lógica | Destino | Notas |
|---|---|---|---|---|---|
| ING-01 | Descartar linhas-lixo do CSV (atenção) | `f_reservas` M | Remove linhas onde `Reserva` contém `"JÁ ANEXEI"`, `"Financiamento: R$ ..."`, `"Sistema Antigo/Atual"`, `"Subsídio: R$ ..."`, ou `Aprovada = "Localização"` | Silver, ou pode deixar de existir (a implementar) | Artefatos de quebra de linha do export manual. Com a API, provavelmente não existem mais: vale validar antes de decidir se o filtro defensivo continua sendo necessário |
| ING-02 | Reserva válida começa com dígito | `f_reservas` M | Mantém só linhas onde `Reserva` começa com `1` a `9` | Silver (a implementar) | Igual ao anterior: filtro defensivo contra CSV malformado |
| ING-03 | Extrair `Reserva` entre aspas | `f_reservas` M | `Text.BetweenDelimiters(_, '"','"', FromEnd)` | Silver (a implementar) | Específico do CSV. Na API, `idreserva` já vem limpo |
| ING-04 | "Ajuste Castro" (regra de negócio real, não limpeza de CSV) | `f_reservas` M | Se `Corretor = "JOSÉ ROBERTO DE CASTRO JUNIOR"` então `Responsável imobiliária` recebe o próprio nome dele (senão mantém o valor original) | Silver (a implementar) | Regra de negócio real, não um defeito de CSV: esse corretor responde pela própria imobiliária. Deve ser reimplementada como um CASE dentro da silver |
| ING-05 | `f_vendas` é a deduplicação de reservas vendidas (regra de negócio importante) | `f_vendas` M | `f_reservas` filtrado por `Situação = "Vendida"`, removendo nulos de `Código interno da unidade`, com deduplicação por unidade (1 venda por unidade) | Silver/Gold (a implementar) | Define o grão de "venda". Atenção: a deduplicação por unidade pode esconder casos de revenda |
| ING-06 | Normalizar nomes de empreendimento | `d_estrutura` M | Cerca de 7 substituições de valor: `Tríade` vira `Triade Fiúsa Home Resort`, `Primaveras` vira `Parc Das Primaveras`, `Arboretto` vira `Arboretto Residenciale`, entre outras | Silver, como de-para (a implementar) | Conformação de nome de produto. Deve virar a tabela de-para `silver.dpara_empreendimento` |
| ING-07 | `Permuta?` derivada | `d_estrutura` M | `if Permuta = "Permuta" then "Sim" else "Não"` | Silver (a implementar) | Flag booleana de permuta |
| ING-08 | Deduplicar a matriz por Código Interno | `d_estrutura` M | `Table.Distinct(..., {"Código Interno"})` | Silver (a implementar) | Garante uma linha por unidade na dimensão de estrutura e preço |
| ING-09 | Normalizar nome de pessoa: corretor, gerente ou supervisor (regra de negócio importante) | novo, criado em 21 de julho de 2026 | `silver.nome_proprio()` aplica Title Case em português, com os conectivos (de, da, do, das, dos, e) em minúsculo, além de remover espaços nas pontas e colapsar espaços duplos; `silver.chave_nome()` deixa o nome em minúsculas e sem acento, usando `translate` em vez de depender da extensão `unaccent` | Silver, como funções (concluído) | O nome é digitado à mão nos dois lados, tanto no headcount do backoffice quanto no CVCRM, e é a única chave em comum entre eles. O par funciona assim: `nome_proprio` é a forma de exibição, e `chave_nome` é a chave usada no cruzamento. Aplicado em `gold.dim_corretor_headcount`, em `gold.fato_leads` (colunas "Corretor Trat" e `corretor_chave`) e em `gold.fato_precadastros` (`corretor_tratado` e `corretor_chave`). Antes dessa normalização, apenas 14 dos 17 corretores ativos casavam corretamente, por sorte de digitação; agora são 17 de 17. A função `initcap` pura do Postgres não serve para isso: ela devolve "De Paula E Silva", capitalizando conectivos que deveriam ficar minúsculos, e no locale C quebra a acentuação sem a extensão COLLATE ICU |

---

## 2. De-paras e tabelas de conformação (Power Query para seeds da Silver)

Cada de-para é uma regra de classificação. No sistema legado, vivem como arquivo
`.xlsx` no SharePoint ou como JSON embutido no modelo. Na silver, viram tabelas de
consulta (seeds) versionadas, e tirar essa lógica do SharePoint já é, por si só, um
ganho de governança.

| ID | De-para | Mapeia | Origem | Destino | Notas |
|---|---|---|---|---|---|
| DP-01 | `dpara_gerente_contexto` | `Gerente Responsável` (texto cru do CVCRM, dentro de campos_adicionais) para `Gerente Apelido`, `Share`, `House/Parcerias` e `Regional` | xlsx no SharePoint (aba "contexto") | Silver, como seed (concluído) | Usado apenas para resolver a classificação da reserva, já que não existe um ID para isso no CRM. Há uma lacuna conhecida de aproximadamente 388 reservas (associadas a "Marcio Lima" e "Jose Castro*") sem linha correspondente, pendente de confirmação com a gestão. O histórico dessa investigação, incluindo por que o campo `bronze.leads.idgestor` foi descartado como fonte de equipe (ele mistura SDR e robô de atendimento), está registrado na memória do projeto sob `depara-gerentes-reestruturacao-v2` |
| DP-13 | `dpara_imobiliaria_house` | `Imobiliária` (o escritório) para `Share`, `House/Parcerias` e `Regional` | mesma planilha do SharePoint acima, aba "imobiliaria" | Silver, como seed (concluído) | É por aqui que leads e pré-cadastros ganham a mesma classificação que a reserva já tem via DP-01: esses fatos não têm um campo "Gerente Responsável", mas o headcount (DP-12) informa o escritório do corretor, e é o escritório que determina Share, House/Parcerias e Regional. Essa informação fica exposta em `gold.dim_corretor_headcount`, e as tabelas fato herdam o dado pelo relacionamento com `corretor_chave`. A junção usa a coluna `Imobiliaria` do headcount, não a coluna `House` de lá (há duas linhas com "EP - RP" arrastado por engano: Carlos Roberto pertence a SCA e João Victor pertence a URA, correção decidida pelo desenvolvedor em 21 de julho de 2026). Antes, essa lógica era um valor fixo dentro de `seeds.sql`; virou uma aba de planilha porque uma classificação comercial não pode morar escondida dentro do SQL. Quando surge uma grafia nova de imobiliária, o procedimento é adicionar uma linha nova na aba (o headcount escreve "NEGOCIO" no singular, enquanto o CVDW usa "NEGOCIOS") |
| DP-12 | `dpara_corretor_headcount` | `Nome` do corretor para `Gerente`, `Supervisor`, `Imobiliaria` e `House` | xlsx do backoffice (HeadCount/Base Corretores Pafil, aba "Base Pafil", só ativos) | Silver, como seed (concluído) | Fonte autoritativa da equipe do corretor, decisão tomada em 21 de julho de 2026: segundo o desenvolvedor, "o que vem do CVDW como equipes é falho". Nem o campo `bronze.leads.idgestor` (que mistura SDR e robô) nem a derivação pela reserva mais recente são confiáveis; a planilha manual do backoffice é. Hoje, `gold.dim_corretor.equipe` prioriza o campo `Supervisor` vindo daqui, e a derivação antiga pela reserva mais recente vira um recurso de reserva, usado só para corretores que ficam de fora do headcount (o caso das Parcerias). Essa fonte cobre apenas o quadro próprio da Pafil (House RP, SC e UB), cerca de 17 corretores ativos hoje |
| DP-02 | `dpara_canal_midia` (versões out24, nov24, dc) | concatenação de canal e mídia para `Canal` e `Mídia` | xlsx e JSON | Silver, como seed (a implementar) | Atenção: três versões coexistem (out/24, nov/24 e D.C). É preciso convergir numa só e registrar a data de vigência de cada uma |
| DP-03 | `dpara_ativo_receptivo` | `Canal` para `Lead`/`Prospect` (ativo ou receptivo) | JSON embutido | Silver, como seed (a implementar) | Classifica origem ativa contra receptiva |
| DP-04 | `dpara_qualificacao_lead` | `Situação` para `Qualificado?` | JSON embutido | Silver, como seed (a implementar) | Base do MQL |
| DP-05 | `dpara_etapa_precadastro` | `Etapa WKF` para `Etapa precadastro BI` e `BI Detalhada` | xlsx no SharePoint | Silver, como seed (a implementar) | Base do funil de crédito (de Montagem até Crédito Aprovado) |
| DP-06 | `dpara_equipe_corretor` | `Corretor` para `Categoria` | xlsx no SharePoint | Silver, como seed (a implementar) | Sem observações adicionais |
| DP-07 | `dpara_profissoes` | `Profissão (Selecionado)` para `Micro` e `Macro` | xlsx no SharePoint (`de_para profissões.xlsx`, aba Planilha1) | Silver, como seed (concluído) | Usado no perfil de cliente (DP-15), join case-insensitive em `gold.dim_perfil_cliente` contra `profissao_selecionado` e, como fallback, `profissao_preenchido`. Carregado por `popular_seeds.py --profissoes` |
| DP-08 | `dpara_ordem_etapa` | `Etapa` (situação) para `Ordem` | JSON embutido | Silver, como seed (a implementar) | Ordenação do funil por situação da reserva |
| DP-09 | `dpara_diretoria` e `d_equipes` | `Corretor` para `Gerente` e `Imobiliária` (mais linhas adicionadas) | JSON e xlsx | `dpara_corretor_gerente` como override, complementado por uma derivação automática (o gerente da reserva mais recente), implementada em `gold.dim_corretor` (concluído) | Atenção: o sistema legado tinha ajustes manuais fixos no código. Replicar via seed, se for necessário |
| DP-10 | `d_imobiliarias` | `Imobiliária` para `Gestor` | xlsx no SharePoint | Silver, como seed (a implementar) | Atenção: filtra São Carlos e Uberaba, e renomeia gestores adicionando o sufixo "(Imob)" |
| DP-11 | `dpara_feriados_2025` | `Data` para `Feriado` | xlsx no SharePoint | Silver, como seed (a implementar) | Calendário útil, usado no tempo de resposta de SDR e corretor |
| DP-14 | `fluxo_investidor` e `retira_reservas` | listas fixas de números de `Reserva` | JSON embutido | Silver, como seed (a implementar) | Atenção: são listas manuais de exceção. É preciso confirmar se ainda valem |
| DP-15 | Perfil de cliente (`gold.dim_perfil_cliente`) | Profissão, renda, PPE e demografia do cliente, por `Documento` (CPF) | **API CVDW** — `bronze.pessoas` + `bronze.pessoas/profissional` (endpoint novo, ver abaixo). CSV manual (`perfil_cliente_precadastro`/`_reserva.csv`) mantido como fallback | Bronze (novo objeto) + Gold (`gold.dim_perfil_cliente`) (concluído) | **Histórico da investigação (24/ago/2026), em 3 etapas — vale registrar porque cada etapa corrigiu um erro de amostragem da anterior:**<br>**1)** Descoberta original: profissão/renda pareciam ausentes da API, checado contra `bronze.campos_adicionais` e contra `bronze.pessoas` (schema descoberto de só 10 registros). Único jeito encontrado foi um CSV manual do CVCRM (`BI V.2/BI Matriz/perfil_cliente_precadastro.csv`/`_reserva.csv`, 148 colunas, export do backoffice) — `Profissão (Selecionado)` 47% preenchida. Virou seed (`silver.perfil_cliente_precadastro`/`_reserva`, ~28 colunas curadas, resto excluído por LGPD — banco, PJ, documentos, terceiros PPE). Achados técnicos da carga desse CSV (ainda válidos, o CSV continua no repo como fallback): PK técnica gerada (nem `Documento` nem `N.` são únicos — 874 repetições de `N.` em 7.805 linhas), encoding misto cp1252/UTF-8 célula a célula (corrigido por round-trip em `popular_seeds.py`), `Data de Cadastro` com sufixo de hora em português.<br>**2)** Usuário perguntou especificamente sobre `/pessoas` (a mesma API, endpoint certo). Reconferido com uma amostra AO VIVO de 200 registros (não 10): confirma o schema já conhecido, sem profissão/banco/empresa — a documentação oficial da CVCRM (`desenvolvedor.cvcrm.com.br/reference/pessoas-2.md`) também confirma: "No dedicated banking data fields".<br>**3) A virada:** usuário apontou o endpoint **`pessoas/profissional`** (sub-recurso, fora dos 19 objetos originalmente descobertos). Uma amostra de 200 registros (página 1) parecia ruim (profissão 2,5%) — mas isso era viés de amostra: os `idpessoa` mais antigos (primeira página) têm captura de dado muito pior que os recentes. A carga COMPLETA (8.465 registros) mostrou `profissao` 65,7% preenchida — **melhor que o CSV manual**, e um endpoint vivo (atualiza a cada ingestão), sem o problema de snapshot parado que o CSV tinha. Virou objeto bronze de verdade: `config/objetos.yml` (`pessoas_profissional`, path `pessoas/profissional`), DDL escrito à mão em `sql/bronze/bronze.sql` (os geradores automáticos `gerar_ddl_bronze.py`/`descoberta_schema.py` não existem mais no repo — foram ferramentas de uso único). 1 linha por `idpessoa`, 1:1 com `bronze.pessoas` (8.465 contra 8.464).<br>**Resultado final, `gold.dim_perfil_cliente` reescrita para usar a API como fonte primária** (`bronze.pessoas` ⨝ `bronze.pessoas_profissional` por `idpessoa`; CSV só preenche `documento_chave` sem nenhuma linha em `bronze.pessoas` — 1.198 de 9.653 linhas na carga de 24/ago/2026, rótulo `fonte_perfil='precadastro'`). Taxa de match de `documento_chave` contra `gold.fato_reservas` subiu de 85,9% (só CSV) para **96,9%**; o caso mais crítico do CSV (Residencial Quinta dos Ventos, vendas de 2026, que batia só 9,5%) foi para **95,2%**. Renda mediana de Quinta dos Ventos bate com o relatório ad-hoc original: R$ 2.682,77 (novo) contra R$ 2.616,39 (`bronze.reservas.renda`, cálculo independente) — confere.<br>**Um bug real de parsing encontrado e corrigido nessa reescrita:** `bronze.pessoas.renda_familiar` (texto) vem da API em notação decimal simples ("4181.82"), diferente do CSV exportado em pt-BR ("4.181,82"). Aplicar `silver.tentar_numeric()` (que assume sempre BR) em "4181.82" dava 418182 — 100x errado (o ponto era tratado como separador de milhar). Corrigido com uma função nova, `silver.tentar_numeric_flexivel()`, que decide o formato pela presença de vírgula (mesma lógica já usada em Python na ingestão, `cvdw/tipos.py:parse_numero`) em vez de assumir BR sempre. **Lição para o projeto**: texto numérico vindo direto da API (JSON) usa notação US; texto numérico vindo de planilha/CSV exportado usa notação BR — `tentar_numeric()` só serve pro segundo caso.<br>`profissao_micro`/`profissao_macro` continuam vindos de join vivo com DP-07 (`silver.dpara_profissoes`), agora casando com `pessoas_profissional.profissao_select`/`.profissao` em vez das colunas do CSV. `Documento`/CPF nunca é exposto em claro — `documento_chave` é hash (`silver.chave_documento()`), mesmo padrão de sempre |

---

## 3. Dimensões e fatos (do modelo legado para o star schema da Gold)

Já existe um esboço do desenho em [`MODELO_SEMANTICO.md`](MODELO_SEMANTICO.md). O
sistema legado confirma o grão de cada entidade:

| Entidade | Grão | Origem legado até a Bronze nova | Notas |
|---|---|---|---|
| `fato_reservas` | 1 reserva (`idreserva`) | `f_reservas`, que vinha de CSV, virou `cvdw.reservas` | É o estado da reserva; `f_vendas` e `f_distratos` eram views filtradas a partir dela (veja ING-05) |
| `fato_series` | 1 parcela | `f_series`, que vinha de CSV, provavelmente vira `cvdw.reservas_condicoes` | Atenção: mapeamento ainda por confirmar (pergunta em aberto registrada em `SKILL.md`) |
| `dim_empreendimento` | `codigo_cv` | `d_empreendimentos` (xlsx), agora derivada de `unidades` | Usa o de-para de nome descrito em ING-06 |
| `dim_estrutura`/unidade | `Código Interno` | `d_estrutura` (base_precos.xlsm), agora `cvdw.unidades` | Concluído: `gold.dim_estrutura` (task 6.4, agosto de 2026) traz preço, área, permuta e status da unidade (Estoque, Realizado ou Permuta), uma linha por unidade. A fonte é `silver.d_estrutura`, carregada por seed através de `popular_seeds.py --estrutura-precos`, cobrindo 3.543 unidades vindas das 13 abas `Matriz_*`. O status é calculado por um join usando `(codigo_cv, bloco, unidade)` contra `fato_reservas`. Atenção a um achado da carga: em produto de torre única, `reservas.bloco` vem preenchido com o nome do empreendimento, em vez de vazio como em `d_estrutura`; isso foi normalizado dentro do próprio join (veja o comentário na view) |
| `dim_corretor` | corretor | `f_equipes`, agora `cvdw.corretores` | Traz categoria e nível |
| `dim_imobiliaria` | imobiliária | vira `cvdw.imobiliarias` | Não é materializada como dimensão própria na gold; o nome fica embutido em `fato_reservas` e em `dim_corretor` |
| `d_metas_empreendimentos` | mês por empreendimento | xlsx `Meta.xlsx` | Concluído: `gold.dim_metas_empreendimentos` (task 6.4) tem 1.704 linhas, vindas da tabela `meta_2` na aba base_meta, carregadas por seed através de `--metas-empreendimentos`. Continua sem origem na API: é input manual da gestão |
| `d_viabilidade` | empreendimento | xlsx | Concluído: `gold.dim_viabilidade` (task 6.4) transforma um pivot no formato EAV em uma linha por `codigo_cv`, trazendo receita bruta, terreno, construção, deduções e despesas. Carregada por seed através de `--viabilidade`. Parametriza a medida de Margem, veja o KPI-17 |
| `d_ivv` | empreendimento por mês, de 1 a 36 | xlsx (o mesmo `d_para empreendimentos.xlsx`, aba IVV_padrão) | Concluído: `gold.dim_ivv_padrao` (agosto de 2026) traz a curva padrão de IVV acumulado desde o lançamento, despivotada a partir de `base_cv4` (que originalmente vinha em formato largo, com uma coluna para cada mês de "1" a "36"). Essa dimensão foi identificada durante uma auditoria do visual "IVV x Empreendimento" do BI legado: não estava catalogada aqui, apesar de já ser referenciada nas medidas de `RESUMO_Empreendimentos.md` (a medida `m_ivv_padrao`); a lacuna foi corrigida. Ela depende de `d_empreendimento_legado` (a Data de Lançamento) para calcular qual é o "mês atual" dentro da curva |
| `d_empreendimento_legado` | empreendimento | xlsx (o mesmo arquivo, aba d_para empreendimentos, tabela base_cv) | Concluído: `silver.d_empreendimento_legado` traz a Data de Lançamento e o Tipo de Produto (Lançamento, Lançado ou Remanescente) por `codigo_cv`. Hoje, seu único uso é alimentar a coluna `gold.dim_ivv_padrao[meses_desde_lancamento]` |
| `d_calendario` | dia | gerada dentro do próprio Power BI (DAX ou Power Query) | Deve ser gerada diretamente na gold |
| `dim_perfil_cliente` | 1 por `documento_chave` (CPF hasheado) | `bronze.pessoas` ⨝ `bronze.pessoas_profissional` (endpoint `pessoas/profissional`, API CVDW) — CSV manual (`silver.perfil_cliente_precadastro`/`_reserva`) só como fallback | Concluído (24/ago/2026, DP-15; reescrita no mesmo dia pra trocar a fonte primária do CSV pra API — ver a entrada DP-15 acima para a investigação completa): `gold.dim_perfil_cliente` traz profissão, renda, PPE e demografia, com `profissao_micro`/`profissao_macro` recalculados via DP-07 e `faixa_etaria`/`faixa_renda_mcmv` calculados na view. Relaciona com `fato_reservas` e `fato_precadastros` por `documento_chave`. Não é a `dim_cliente` cheia que MODELO_SEMANTICO.md registra como adiada — ali seriam as ~98 colunas de `pessoas` sem curadoria; aqui é um recorte deliberadamente menor e sem os campos mais sensíveis (banco, PJ, documentos, terceiros PPE) |

**Atenção:** metas, viabilidade e verba de marketing não existem na API do CVDW,
porque são planejamento da gestão. Continuam como tabelas de input, carregadas por
seed a partir de planilhas Excel controladas, alimentando diretamente a camada gold.

---

## 4. KPIs autoritativos (das medidas DAX para a Gold)

Estas são as medidas-núcleo do projeto, listadas em ordem de prioridade para
reconciliação. O DAX aqui está condensado; para a versão original completa, veja os
arquivos `RESUMO_*.md`.

### 4.1 Vendas e VGV (KPI)

| ID | Medida | Lógica (condensada) | Dependências | Notas |
|---|---|---|---|---|
| KPI-01 | VGV Bruto (KPI) | `SUM(f_reservas[Valor do contrato])` | fato_reservas | Base de quase tudo |
| KPI-02 | VGV Distrato (KPI) | `SUM(distratos[Valor do Contrato])` | f_distratos | Atenção: usa a tabela `'distratos 2025'`, um xlsx separado, em vez da fato. Precisa convergir |
| KPI-03 | VGV Líquido (KPI) | `[VGV Bruto] - [VGV Distrato]` | KPI-01, KPI-02 | Número de vendas líquidas |
| KPI-04 | QTD Bruto (KPI) | `DISTINCTCOUNT(f_reservas[Reserva])` | fato_reservas | Sem observações adicionais |
| KPI-05 | QTD Distratos (KPI) | `DISTINCTCOUNT(distratos[Contrato])` | distratos | Sem observações adicionais |
| KPI-06 | QTD Líquido (KPI) | `[QTD Bruto] - [QTD Distratos]` | KPI-04, KPI-05 | Sem observações adicionais |
| KPI-07 | Somente Vendas | `COUNTROWS(f_reservas)` com `Situação = "Vendida"` | nenhuma | Atenção: comparado com "Qtd Vendas 2" (KPI-08), que inclui tanto Vendida quanto Distrato. Duas definições de "venda" coexistem no legado |
| KPI-08 | Qtd Vendas 2 | `COUNTROWS` com `Situação` em `{"Vendida","Distrato"}` | nenhuma | "Venda" aqui significa vendida ou já distratada, ou seja, foi venda algum dia |
| KPI-09 | Ticket Médio / preco_medio | `DIVIDE(SUM[Valor contrato], SUM[M² da unidade])` | nenhuma | Preço médio por m² praticado |
| KPI-10 | Média Vendas 6M | média de `[Qtd Vendas 2]` nos últimos 6 meses fechados | d_calendario | Usa a função EOMONTH |

**Atenção, esta é a divergência-chave a resolver na reconciliação:** o que conta
como "venda"? Apenas `Vendida` (KPI-07) ou `Vendida` e `Distrato` juntos (KPI-08)?
Os PBIX legados usam as duas definições, dependendo do contexto. Definir qual delas
é a regra autoritativa é um entregável desta migração, não uma decisão técnica.

### 4.2 Estoque, preço e VSO (modelo "Preço" e "Matriz") (KPI)

É um padrão repetido por empreendimento: PA, TR, PSU, PCJ, ARB, PO, PR, F16, QBV,
VM, PPN e VLPQ.

| ID | Medida (padrão `XX_`) | Lógica | Notas |
|---|---|---|---|
| KPI-11 | EstoqueVGV (KPI, concluído) | `SUM(Matriz[Preço])` para unidades que não estão em `VALUES(Vendas[Cód. unidade])` | Unidade não vendida conta como estoque. Reimplementado em `powerbi/MEDIDAS_ESTOQUE_PRECO.dax`, sobre `gold.dim_estrutura[status_unidade]` |
| KPI-12 | Estoque_Qtd (concluído) | `COUNT(Matriz[Cód.])`, fora da lista de vendas e com `Permuta <> "Permuta"` | Exclui permuta |
| KPI-13 | ProjetadoVGV (KPI, concluído) | `[EstoqueVGV] + SUM(Vendas[Valor do contrato])` | VGV potencial total |
| KPI-14 | MetragemAVender (concluído) | `SUM(Matriz[Área Privativa])` do estoque, sem permuta | Sem observações adicionais |
| KPI-15 | M²Médio / M²ARealizar (concluído) | `AVERAGE(Vendas[M² Praticado])`; `EstoqueVGV / MetragemAVender` | Sem observações adicionais |
| KPI-16 | VSO (concluído) | `DIVIDE(unidades realizadas, unidades totais)` | Velocidade de vendas, usando `d_estrutura[status_unidade="Realizado"]` |
| KPI-17 | Margem e MargemViab (KPI, concluído) | `(Projetado - custo - %ded - %desp) / (Projetado × fator)` | Já parametrizado (veja a nota logo abaixo) |
| KPI-17b | IVV Padrão, medida `m_ivv_padrao` (concluído) | `SUM(d_ivv[%IVV])`, filtrado no mês da curva (1 a 36) correspondente à idade do produto hoje | Curva de meta e benchmark de velocidade de vendas por empreendimento, usada no visual "IVV x Empreendimento". É a barra maior (a segunda) desse visual. Compare com o VSO (KPI-16, o realizado); veja `gold.dim_ivv_padrao` e a medida `Diferença IVV x Padrão` |
| KPI-17c | % Vendido no ano, medida `m_percentual_vendido` (concluído) | `DIVIDE(COUNT(fato_reservas[id_reserva])` onde `situacao="Vendida"` e `ano_venda` é o ano corrente, `COUNT(dim_estrutura[codigo_interno]))` | É a barra menor (a primeira) do visual "IVV x Empreendimento". Atenção: essa métrica é diferente do VSO. Ela usa a situação "Vendida" de forma estrita, excluindo Distrato, filtrada pelo ano corrente, contra o total histórico da matriz de preço. Ou seja, é a "taxa de venda do ano sobre todo o estoque já ofertado", e não o "percentual já vendido alguma vez" (que é o que o VSO mede). A métrica relaciona `dim_estrutura` a `fato_reservas` pelo par `codigo_cv` e `codigo_interno_empreendimento` (via `dim_empreendimento`), não pelo nome conformado: um achado do processo foi que `silver.conformar_empreendimento()` não cobre todas as grafias curtas usadas na planilha de preço (Tríade, Primaveras e Parc das Artes davam 0% se o agrupamento fosse por nome). Essa métrica foi validada: 12 dos 13 empreendimentos batem exatamente com o relatório "Vendas Geral", e o único que diverge fica a 1 unidade de diferença, um drift normal de atualização entre os sistemas |

**Concluído: a task 6.4 (agosto de 2026) resolveu a duplicação registrada na regra
R4.** O modelo "Preço" repetia as mesmas 8 medidas para cerca de 12 empreendimentos,
cada uma com constantes coladas diretamente no código DAX. Na gold, isso virou uma
única medida, parametrizada por `gold.dim_viabilidade` (o custo de obra é o valor
absoluto de terreno mais construção, e os percentuais de dedução e despesa variam
por `codigo_cv`), implementada em `powerbi/MEDIDAS_ESTOQUE_PRECO.dax`. A fórmula foi
validada manualmente contra os números de Parc das Artes (`codigo_cv` 10093),
registrados em `_bi_ref/RESUMO_BIPreco.md`.

### 4.3 Distratos (KPI)

| ID | Medida | Lógica | Notas |
|---|---|---|---|
| KPI-18 | Taxa de Distrato (KPI) | `DIVIDE([Distratos], [Reservas Vendidas])` | Este é o KPI oficial |
| KPI-19 | `eh_distrato` | `Situação = "Distrato"` (ou motivo preenchido) | Flag calculada na fato |
| KPI-20 | Múltiplas fontes de distrato (concluído) | `f_distratos` (xlsx), `'distratos 2025'` (xlsx), `rel_distratos` (CSV) | São três fontes ao todo. `cvdw.distratos` e `silver.distratos`, vindas da API, já são a fonte viva e cobrem motivo, data e valor, batendo ao centavo (veja R11 na reconciliação). A planilha `'distratos 2025'` foi importada como um detalhe financeiro complementar (multa, valor pago, devolução, parcelas), informação que a API não oferece, dentro de `gold.dim_distratos_2025` (agosto de 2026), e está relacionada à fato através de `silver.chave_bloco` e `chave_unidade`, com 86% de taxa de match (veja R17). As fontes `f_distratos` e `rel_distratos` continuam não importadas, por serem redundantes com o que a API já cobre |

### 4.4 Funil de leads e performance digital

| ID | Medida | Lógica | Dependências |
|---|---|---|---|
| KPI-21 | Qtd Prospect | `DISTINCTCOUNT(f_leads[Id])` | f_leads |
| KPI-22 | Qtd Leads | contagem distinta de Id com `canal 2.0 = "Lead"` | DP-02 |
| KPI-23 | Qtd Lead Quali (MQL) | `canal 2.0="Lead"` e `MQL 2="SIM"` | DP-04 |
| KPI-24 | Tx_Qualif_Leads | MQL dividido por Lead | DP-04 |
| KPI-25 | Qtd Pastas | `COUNTROWS(f_precadastros)`, exceto `{"Montagem","Cancelada"}` | DP-05 |
| KPI-26 | Qtd Crédito Aprovado | etapa em `{"Crédito Aprovado","Com Reserva","Ajustes"}` | DP-05 |
| KPI-27 | Conversões (lead para pasta para venda) | série de `DIVIDE` entre os KPIs acima | KPI-21 a KPI-26 |
| KPI-28 | Tempos médios (SDR, corretor, qualificação) | `AVERAGEX(... × 60)`, formatado como HH:MM:SS | DP-11 (feriados) |
| KPI-29 | CAC, ROI, CPL | `verba / vendas`, `(VGV Lead - verba) / verba` | verba (xlsx) |
| KPI-30 | % Vendas Digitais (House) | vendas com `canal vendas consolidadas="Lead"` dividido pelo total | DP-01, DP-02 |

### 4.5 Metas e forecast

| ID | Medida | Lógica | Notas |
|---|---|---|---|
| KPI-31 | meta_start / meta_replan (concluído) | `SUM(d_metas[meta_vgv])` por `status_meta` | Input da gestão. Implementado em `gold.dim_metas_empreendimentos` (task 6.4) |
| KPI-32 | Diferenca_meta_* / % Atingimento (concluído) | `VGV ÷ meta` | Acumula no ano (YTD); veja `powerbi/MEDIDAS_GOLD.dax` |
| KPI-33 | Forecast (% Forecast, Dif Forecast) (concluído) | `Realizado ÷ Meta VGV` | Usa o xlsx `VGV Vendas`; veja `powerbi/MEDIDAS_GOLD.dax` |

### 4.6 Comissões, repasses e receita

| ID | Medida | Lógica | Notas |
|---|---|---|---|
| KPI-34 | Valor Custas | `SUMX(f_reservas, [Valor contrato] × 0.029)` | Atenção: percentual de 2,9% fixo no código |
| KPI-35 | Total comissão e prêmio | vem de colunas já prontas na fato (Comissão corretor, Comissão imobiliária, entre outras) | Já vêm assim no CSV e na API |
| KPI-36 | Valor Líq. Finan. / Recebimento Obra / A Receber | tabela `repasses`: financiado menos terreno, multiplicado pela obra acumulada | Vem da tabela `repasses` (possivelmente `contratos/repasses` na API) |
| KPI-37 | Valor Aprovado Sem Duplicados | `SUMX(DISTINCT(Id), MAX(Valor Aprovado))` | f_precadastros |

---

## 5. Simulador de preço e Pró-Soluto (modelo "Matriz", aba simulador)

São regras de política comercial (limites de parcelamento). Têm valor, mas ficam
fora do núcleo de reporting:

| ID | Regra | Lógica | Notas |
|---|---|---|---|
| SIM-01 | Limite de Pró-Soluto por produto (regra importante) | `SWITCH(Produto, "Fiusa 016",15, "Villa Manacás",10, ...)`, em percentual | Hoje é uma política comercial fixa no código; deveria virar uma seed, `dpara_limite_prosoluto` |
| SIM-02 | Alerta Pró-Soluto | sinal verde (dentro do limite) quando `%ProSoluto` é menor ou igual ao limite | Depende de SIM-01 |
| SIM-03 | Parcela, Valor Entrada, Valor Ato | aritmética de financiamento | Usa `f_precadastros[Valor Aprovado]` |
| SIM-04 | VGV/QTD Possível | conta unidades "dentro do limite" multiplicadas pelo preço | Sem observações adicionais |

---

## 6. Itens a descartar na migração (não são regra de negócio)

Para não poluir a silver e a gold com pura apresentação, os itens abaixo ficam de
fora:

- **Ícones:** campos `*_Icone` (as setas ▲ e ▼, geradas por `UNICHAR(9650/9660)`),
  usados em Meta Lead, Venda Digital, Qualificação, Vendas House, entre outros.
- **Cores:** campos `*_Cor` e `*_Variacao_Cor`, que retornam "Green", "Yellow" ou
  "Red" conforme a faixa de valor, funcionando como semáforos.
- **Cards e HTML:** medidas como `Cards Fiusa 016`, `Tabela Fiusa 016 ...`,
  `KPI Sparkline`, `Tabs Período` e `Métrica Card ...`, que embutem HTML ou SVG
  dentro do próprio DAX para montar visuais customizados.
- **LocalDateTable_*:** cerca de 50 tabelas de data geradas automaticamente pelo
  Power BI, substituídas por uma única `dim_calendario`.

**A regra geral é esta: lógica de cor, ícone ou HTML fica sempre no Power BI, na
camada de visual, nunca na gold.** A gold entrega o número; quem decide a cor é o
relatório.

---

## 7. Riscos e divergências conhecidas (consolidado)

| # | Risco | Onde aparece | Ação |
|---|---|---|---|
| R1 | Atenção: "venda" tem duas definições diferentes ({Vendida} e {Vendida, Distrato}) | KPI-07/08 | Definir qual é a autoritativa durante a reconciliação |
| R2 | Atenção: distratos vêm de três fontes distintas | KPI-20 | Unificar em `cvdw.distratos` |
| R3 | Atenção: Canal e Mídia têm três versões de de-para | DP-02 | Convergir numa só e registrar a data de vigência |
| R4 | Atenção: Margem e Viabilidade tinham constantes fixas no código, por empreendimento | KPI-17 | Já parametrizado através de `gold.dim_viabilidade` (task 6.4, agosto de 2026), mas a origem está vazia para 11 dos 13 produtos: veja R20 |
| R5 | Concluído: metas, viabilidade e verba não existem na API | seção 3 | Metas e viabilidade já importadas como seed (task 6.4); a verba de marketing segue pendente |
| R6 | Atenção: listas de exceção manuais (fluxo investidor, retira reservas) | DP-14 | Confirmar vigência com a gestão |
| R7 | Atenção: a deduplicação de venda por unidade pode ocultar uma revenda | ING-05 | Validar o grão na silver |
| R8 | Atenção: ajustes pessoais fixos no código (Castro, Marcio) | ING-04, DP-09/10 | Mover para uma de-para versionada |
| R9 | Atenção: "Vendas Consolidadas" tem status manuais sem correspondência na API (`Validada`, `Venda distratada`, `Repassada`, `Envio Mega`, `Validação Comercial`) | planilha legada | Deveria virar um de-para `dpara_status_venda` (de situação do CRM para status operacional) ou permanecer como input operacional; de qualquer forma, esses status não vêm do CRM |
| R10 | Crítico: o fechamento manual atrasa. 420 das 1.892 propostas que a planilha conta como venda viva já são Distrato no CRM | reconciliação de vendas | Esse é justamente o ganho da pipeline nova: um número sempre atual. Documentar isso para a gestão |
| R11 | Concluído: `valor_contrato` (API) é igual a "VGV (Praticado)" (planilha) ao centavo em 1.869 das 1.892 propostas (98,8%) | reconciliação de vendas | Valida o KPI-01. As 23 divergências foram investigadas: uma é um buraco de dado no CRM (a proposta 337 tem `valor_contrato=0`, mas a soma de financiamento, subsídio e FGTS chega a aproximadamente R$ 207 mil); sete casos usaram `vgv_tabela` (o preço de tabela) no legado; e quinze são ajustes ou arredondamentos manuais (vários com cerca de R$ 9,5 mil de desconto) que não batem com nenhuma coluna disponível no CRM. Conclusão: `valor_contrato` é o número autoritativo |
| R12 | Concluído: DE_PARA_PRODUTOS extraída para `dpara_empreendimento` (25 linhas), com `silver.conformar_empreendimento()` ignorando maiúsculas e minúsculas na gold | DP-06/ING-06 | Resolve casos como "FIUSA 016" contra "Fiusa 016". A aba também traz o campo `EP` (espaço de negócios) |
| R13 | Concluído: House é o escritório próprio da Pafil (a imobiliária `ESPACO DE NEGOCIOS PAFIL <regional>`); House RP corresponde a Ribeirão Preto/RPO. O ranking considera só House, e exclui o corretor de coordenação ("Regiane...") | apresentação (ranking) | Confirmado: reproduz o pódio de maio de 2026 ao centavo (Alessandra, Rafael, Wallace). Usa as seeds `dpara_imobiliaria_house` e `dpara_corretor_fora_ranking`. House e regional vêm da classificação oficial no Power BI, onde o ranking por corretor é montado em cima de `fato_reservas` (a exclusão da coordenação é um filtro aplicado pela seed). O `dpara_gerentes` foi recarregado a partir de `depara_gerentes.xlsx` (43 linhas, cruzando House/Parcerias com Regional) |
| R14 | Concluído: o ranking por gerente, que estava travado (referência aos slides 17 a 19 da apresentação), foi destravado. O campo "Gerente Responsável" existe na API, mas como um campo customizado dentro de `campos_adicionais`, não como uma coluna própria | apresentação (ranking) | Está preenchido em 68% das vendas, cobre 39 gerentes, e casa com `dpara_gerente_contexto`. A função `silver.campo_adicional()` extrai esse valor para `silver.reservas.gerente_responsavel`, e o ranking por gerente é montado no Power BI em cima de `fato_reservas` (com House vindo da classificação oficial). Validado: Matheus Santamaria aparece com 6 unidades e R$ 1,75 milhão, batendo com o slide 18 ("Liga das vendas", 6 unidades e R$ 1,7 milhão). Não foi necessário nenhum de-para manual para isso |
| R15 | Concluído: outros campos do BI legado, guardados dentro de `campos_adicionais`, também foram extraídos para a silver e a gold | reservas | `cf_tipo_venda` (98% preenchido, com valores como Financiamento na Planta ou Venda Direta), `cf_modalidade_financiamento` (97% preenchido, com valores como MCMV, PAFIL ou SBPE), `cf_motivo_distrato` e `cf_classificacao_vendas_internas`. Outros campos continuam disponíveis sob demanda, como "Data de Distrato", "Premiação Tá Fácil", "Reciprocidade" e "IRPF Futuro", através da função `silver.campo_adicional()` |
| R16 | Atenção, um problema de qualidade de dado: alguns valores de "Gerente Responsável" trazem o nome de uma equipe ("Equipe Pitangueiras") ou "N/D", em vez do nome de uma pessoa; 32% dos casos ficam nulos | ranking de gerentes | Às vezes o nome diverge do que está em `dpara_gerente_contexto` (por exemplo, "Marcio Lima" aparece em 328 reservas e "Jose Castro*" em 60, juntos cerca de 8% do total; veja DP-01). Confirmar com a gestão e adicionar a linha correspondente na aba "contexto" de `depara_gerentes.xlsx` |
| R18 | Atenção: `gold.dim_metas_empreendimentos` tem entradas "placeholder", de projetos futuros ou apenas planejados que ainda não existem no CVCRM. Elas se identificam por um `codigo_cv` pequeno e sequencial (1, 2, 7, 8, 9, 10, 11, 99, correspondendo a Parc Gramado, Dualle, Trivion Home Resort, Condomínio Comercial Parc Sul, entre outros), bem diferente dos códigos reais, que têm 4 ou 5 dígitos, como 8883, 15840 ou 20587 | `gold.dim_metas_empreendimentos` | Somar `meta_vgv` sem relacionar ou filtrar por `dim_empreendimento` infla o total: foi validado que a Meta Start de 2026 dá R$ 493 milhões incluindo os placeholders, contra R$ 199 milhões considerando só empreendimentos reais, o que bate com o card "Meta Start" do relatório "Vendas Geral" (o mesmo vale para o Forecast: R$ 470 milhões contra R$ 190 milhões). Sempre relacionar ou filtrar por `dim_empreendimento` (join por `codigo_cv = codigo_interno_empreendimento`) antes de somar meta ou forecast, para refletir só os empreendimentos ativos no CVCRM |
| R19 | Concluído: `base_precos.xlsm` tinha qualidade de dado inconsistente entre as abas, porque cada produto foi montado por cópia manual da matriz-modelo, e cada cópia divergiu um pouco da original | `silver.d_estrutura`, `popular_seeds.py` | Dois problemas foram identificados e corrigidos. Primeiro, a aba QBV2 (Quinta da Boa Vista) tinha cabeçalhos com erro de digitação ("Unidde", "ID_Prço", "Áre Privtiv", "Permut"), o que zerava a coluna Unidade para o produto inteiro; a correção foi feita com um alias de coluna no loader, além de passar a preferir a tabela duplicada correta da própria aba QBV, chamada "Matriz_F162427" (um nome bagunçado por causa de um copiar e colar do Excel, mas com o cabeçalho certo). Segundo, a aba VPQ (Villas do Parque, Casas e Lotes Mistos) tinha as colunas `Bloco` e `Unidade` preenchidas literalmente com o texto "#N/A"; a causa raiz era um PROCV apontando para uma tabela auxiliar (`Estrutura___Villas_do_Parque`) alimentada por Power Query a partir de um CSV local desatualizado (`Estrutura/Villas do Pq. - Casas.csv`), que trazia um "Código Interno" de uma geração antiga do CVCRM, sem nenhuma sobreposição com os códigos atuais da matriz (zero em comum entre 812 linhas). Isso foi corrigido pelo desenvolvedor diretamente na planilha, em 10 de agosto de 2026: o PROCV foi trocado por um ÍNDICE/CORRESP apontando para outro intervalo válido dentro da própria aba, sem precisar reexportar o CSV. O resultado foi validado: o VSO de "Villas do Pq. Casa" saltou de 0% para 72,8%; o de "Villas do Pq. Lote" ficou baixo, em 3,66%, mas isso é dado real, não bug, já que existem apenas 6 reservas no CVCRM para 164 lotes, um produto ainda pouco vendido. Resolvido, nenhuma ação pendente |
| R20 | Concluído, resolvido em 12 de agosto de 2026 (preenchido via automação do Excel, com backup guardado em `_backups_fechamento/`): foram preenchidos 8 produtos que tinham linhas vazias, mais 10 linhas novas para Villa Manacás, que antes não tinha nenhuma | `silver.d_viabilidade`, KPI-17 | Hoje, `MargemViab` na gold bate com o legado até a 8ª casa decimal em 7 produtos (Tríade, Primaveras, Quinta da Boa Vista, Parc Sul, Villas do Pq. Casas, Arboretto e Parc Cidade Jardim), e até a 6ª casa em Parc das Artes. Três ressalvas sobre esse preenchimento: primeiro, o DAX legado só guardava o custo de obra total, então a linha "Terreno" ficou em branco de propósito, com o valor inteiro concentrado em "Construção" (a soma dos dois, que é o que a margem realmente usa, fica correta; `gold.dim_viabilidade.custo_obra` já resolve esse NULL). Segundo, Villas do Pq. Casas recebeu a viabilidade do produto inteiro, porque o legado tratava Casas e Lotes como um produto só. Terceiro, as constantes recuperadas são de uma versão desconhecida no tempo, e precisam ser validadas contra o estudo de viabilidade vigente. Dois produtos continuam sem viabilidade: Parc Paineira e Residencial Quinta dos Ventos. Também foi corrigido, no pivot `gold.dim_viabilidade`, um problema em que o rótulo do parâmetro varia entre produtos ("Receitas Brutas"/"Receitas Líquidas" em Parc das Orquídeas, contra "Receita Bruta"/"Receita Liquida" nos demais), e o match por string exata zerava o produto inteiro: parecia que a planilha estava em branco, mas o dado estava lá, só que sob um rótulo diferente. Falta validar as constantes com quem tem o estudo de viabilidade |
| R20-hist | Crítico, este é o contexto original do problema (já resolvido, veja R20 acima) | `silver.d_viabilidade`, KPI-17 | A tabela `tab_viabil_padrão`, na aba `viabil_padrão` de `d_para empreendimentos.xlsx`, tinha as 10 linhas de parâmetro para os 13 empreendimentos, mas as células de Valor e % estavam vazias em 11 deles. Só Parc das Artes (código 10093) e Parc das Orquídeas (código 13998) vinham preenchidos (isso foi conferido lendo o arquivo com e sem a opção `data_only`, confirmando que eram células realmente em branco, não uma fórmula sem cache). O efeito prático era que a medida `Margem` retornava 100% e `MargemViab` retornava vazio para os outros 11 produtos, justamente o número mais visível do BI de Preço. Mas os valores existiam: estavam fixos nas 12 medidas DAX do sistema legado, e foram recuperados e decompostos no arquivo `relatorios/viabilidade_constantes_legado.csv` (usando a identidade: o denominador é 1 menos as deduções, e o restante do valor subtraído são as despesas; a recuperação foi conferida reproduzindo cada `XX_MargemViab` até a 8ª casa decimal). Essa investigação revelou outros problemas de qualidade: Parc Paineira usa constantes idênticas às de Parc das Orquídeas, sinal de um copiar e colar nunca corrigido; Primaveras usava 0,079 na medida `Margem` mas 0,0788814711655896 na `MargemViab`, ou seja, o próprio DAX legado divergia de si mesmo; e em Parc das Orquídeas o custo de obra da planilha (R$ -30.669.428) difere do valor usado no DAX (R$ -31.200.727) em cerca de R$ 531 mil, sinal de dois estudos diferentes sendo usados ao mesmo tempo. A gestão ou o backoffice precisam preencher `tab_viabil_padrão` a partir do CSV recuperado, sempre validando contra o estudo de viabilidade vigente, já que as constantes recuperadas do DAX são de uma época desconhecida |
| R21 | Concluído: contornado em 12 de agosto de 2026, pela troca da matriz de preço descrita em R22 | `silver.d_estrutura` | O erro existe só no `base_precos.xlsm`; a matriz do legado tem a área correta, e o indicador `M²ARealizar` do produto saiu de 5,11 para 5.247,61. O erro continua existindo na planilha, e volta a aparecer se alguém rodar `--estrutura-fonte bi_matriz`. O contexto: em Villa Manacás, a área privativa vinha 1000 vezes maior do que deveria. Na `base_precos.xlsm`, a coluna `Área Privativa` do produto trazia 48.790 onde deveria ser 48,79 m², e o `Preço M²` calculado saía 5,25 em vez de aproximadamente 5.247. A área total ficava em 9.156.800 m² na gold, contra 9.156,80 no legado. Como o `Preço` unitário em si estava correto, o VGV, o estoque e a margem não eram afetados, mas todo KPI calculado por metro quadrado do produto saía 1000 vezes errado (`M²ARealizar` chegava a 5,11). É o mesmo tipo de problema descrito em R19. Corrigir na planilha de origem, não tratar dentro do pipeline, porque isso mascararia o erro para quem ainda usa a planilha diretamente |
| R22 | Atenção: duas matrizes de preço coexistem na empresa | `silver.d_estrutura` | O BI de Preço legado lê os arquivos `Preço/Apoio/Apoio - BI de Preço.xlsm` e `Preço/Vendas/<Produto> - Resumo.xlsm`, enquanto a pipeline lia `BI V.2/BI Matriz/base_precos.xlsm`. As duas descrevem as mesmas unidades (a área privativa total bate ao centavo em 9 dos 11 produtos), mas com preços de tabela diferentes: em Arboretto, considerando as mesmas 90 unidades fora de venda, o legado soma R$ 70,05 milhões contra R$ 67,13 milhões na gold. Enquanto as duas planilhas existirem, os dois relatórios vão discordar por construção, não por erro. Foi decidido em 12 de agosto de 2026, pelo desenvolvedor, usar a matriz do legado como padrão, para que o relatório novo bata com os números que a gestão já conhece. O comando `popular_seeds.py --estrutura-fonte legado` ou `bi_matriz` alterna entre as duas, com o padrão definido na variável `ESTRUTURA_PRECOS_FONTE` do `.env`. O loader absorve as diferenças de layout entre as duas fontes: as colunas `Prumada`, `Frente Fundo` e `Final` viram `config_1`, `config_2` e `config_3`; a coluna `Torre` vira `bloco`; e o `codigo_cv`, que o legado não tem, é resolvido pelo nome conformado do produto, o que exigiu adicionar três apelidos novos em `dpara_empreendimento` ("Primaveras" para Parc das Primaveras, e "Tríade"/"Triade" para Tríade Fiúsa). Essa troca de fonte melhorou três coisas: corrigiu a área de Villa Manacás (veja R21), fez Quinta da Boa Vista bater exatamente com o legado, e trouxe Parc Paineira de volta à existência, com 144 unidades. Por outro lado, piorou uma coisa: os 164 lotes de Villas do Pq. Lotes Mistos ficaram sem preço, porque o arquivo do legado nunca os precificou (o `base_precos` antigo tinha ali R$ 23,9 milhões de estoque). Resolver o preço desses lotes diretamente na planilha do legado, ou fazer o loader complementar com o `base_precos.xlsm` apenas onde o preço estiver faltando |
| R23 | Concluído: erros de digitação no valor das colunas de posição (`CONFIG_1`, `CONFIG_2`, `CONFIG_3`) da matriz de preço, da mesma família do problema descrito em R19 | `popular_seeds.py`, `silver.d_estrutura` | Exemplos encontrados: "LOTE MISTO (GURIT E COMERCIL)" com letras faltando, "OTE MISTO" sem o L inicial, "Muro lateral" contra "Muro Lateral" (diferença de caixa) e "154  e 155 (PCD)" com espaço duplo. Isso não é só cosmético: na matriz do BI de Preço, cada grafia diferente vira uma coluna separada, com apenas 1 ou 2 unidades cada, empurrando as colunas corretas para fora da tela visível (Quinta da Boa Vista chegou a ter 4 rótulos para apenas 3 tipologias reais). Foi corrigido diretamente no loader, através de um dicionário `ALIAS_VALOR_CONFIG` combinado com o colapso de espaços duplicados no campo `_txt`, em 13 de agosto de 2026, reduzindo de 33 para 31 valores distintos de `config_1`. Um caso foi deixado de fora de propósito: `config_3 = "Lateral"` (1 unidade em Villas do Pq. Lotes Mistos), que provavelmente é uma abreviação de "Muro Lateral", mas como "Lateral" também é um valor legítimo de `config_2` (indicando a face do lote, em Parc das Artes), juntar os dois sem confirmação seria inventar um dado que não temos certeza. Confirmar esse "Lateral" solto com o backoffice; o ideal é corrigir na planilha de origem, já que o de-para no código deve funcionar como uma rede de proteção, não como o conserto definitivo |
| R24 | Atenção: `popular_seeds.py --xlsm` apaga os apelidos fixos de `dpara_empreendimento` se rodar antes de `--estrutura-precos` no mesmo comando | `popular_seeds.py`, `silver.dpara_empreendimento`, `silver.d_estrutura` | Achado em 25/ago/2026, na primeira carga completa de seeds direto na máquina de produção (`RUNBOOK_WINDOWS.md`). `carregar_depara_produtos` (acionado por `--xlsm`) faz `TRUNCATE silver.dpara_empreendimento` antes de inserir as 25 linhas da aba `DE_PARA_PRODUTOS` — isso apaga também os três apelidos fixos ("Primaveras", "Tríade", "Triade", ver R22), que não vêm da planilha: são um `INSERT` estático dentro do próprio `seeds.sql`, aplicado só quando `aplicar_silver.py`/`aplicar_tudo.py` roda. Rodar `popular_seeds.py --xlsm --estrutura-precos ...` no mesmo comando (nessa ordem, que é a ordem interna de `main()`) faz `--estrutura-precos` resolver `codigo_cv` contra uma `dpara_empreendimento` sem esses apelidos — na carga de produção, isso deixou 672 unidades de Primaveras e Tríade sem `codigo_cv` em `silver.d_estrutura`, além das 168 já esperadas por R18 (empreendimentos placeholder). **Correção**: rodar `aplicar_tudo.py` de novo depois (reaplica `seeds.sql`, que reinsere os apelidos via `ON CONFLICT DO NOTHING`, sem duplicar nem afetar os outros seeds). **Prevenção**: ao rodar `--xlsm` e `--estrutura-precos` juntos, sempre fechar com um `aplicar_tudo.py` (ou `aplicar_silver.py`) antes de considerar a carga de seeds concluída — ou, mais robusto, mover os três apelidos fixos para dentro do próprio `carregar_depara_produtos()` em vez de deixá-los só no DDL, para não dependerem da ordem de execução. Ainda não corrigido no código, só contornado operacionalmente |
| R17 | Concluído: `gold.dim_estrutura` e `gold.dim_distratos_2025` não têm um código de unidade que bata 1 para 1 com a API | `gold.dim_estrutura`, `gold.dim_distratos_2025` | A CVDW não expõe o "Código interno da unidade" que existia no CSV legado, nem o "Contrato" de `distratos_2025`, que na verdade é um ID do MEGA, o sistema financeiro, e não do CVCRM. Por isso, o cruzamento é feito pelo conjunto (empreendimento conformado, bloco, unidade), normalizado pelas funções `silver.chave_bloco()` e `silver.chave_unidade()`, compartilhadas em `seeds.sql`. Ao longo da task 6.4 e do trabalho com distratos de 2025 (agosto de 2026), cinco achados moldaram essa normalização: em produtos de torre única, o campo `bloco` vem preenchido com o nome do próprio empreendimento em vez de vazio em uma fonte, e como NULL na outra, tratado como NULL nos dois lados; os números de bloco e unidade têm padding diferente entre as fontes ("QUADRA 06" contra "Quadra 6", "027" contra "27"), resolvido extraindo o número e removendo os zeros à esquerda; empreendimentos vendidos em lote (Villas do Parque, Quinta dos Ventos, Quinta da Boa Vista) usam uma convenção de "LOTE/CASA" divergente entre as fontes, resolvida comparando por token numérico com um fallback bidirecional; o campo bloco às vezes tem as mesmas palavras do nome do empreendimento fora de ordem, resolvido comparando por conjunto de palavras; e o campo bloco pode vir com um sufixo extra, resolvido extraindo só o prefixo mais o primeiro número. Uma validação manual, feita contra o relatório "Vendas Geral", confirmou que as 13 unidades da Tríade que pareciam "sumir" do estoque eram legítimas: o campo `unidade` trazia "133 - TERRENISTA", um repasse por permuta ao terrenista, e a extração numérica corrigiu esse caso, que não era um bug. Em `dim_distratos_2025`, quando bloco e unidade batem em mais de uma reserva, o desempate usa a reserva cujo `data_situacao` fica mais próximo da "Data do Distrato". As taxas de match alcançadas: em `dim_estrutura`, Arboretto foi de 0% para 42%, Quinta da Boa Vista foi de 0% para 80,8% (depois da correção do R19), e Tríade manteve 99,75% (confirmado que já estava correto); só "Villas do Pq." (Casas e Lotes) continuam em 0%, bloqueados pelo R19, porque o dado já vem quebrado na origem. Em `dim_distratos_2025`, a taxa é de 748 em 866, ou 86%; o restante são casos de empreendimento fora do CVCRM ou de grafia ainda não coberta. Se outro produto aparecer com taxa de match baixa, investigar a variação de grafia específica antes de assumir falha de join |

---

## 8. Próximos passos a partir deste catálogo

1. Concluído, Silver (`sql/silver/`): a regra ING-04 virou a seed
   `dpara_responsavel_imobiliaria`; as regras ING-01 a ING-03 não foram portadas,
   por serem lixo de CSV; existem 6 views de conformação. As regras DP-* viraram
   seeds, em `seeds.sql`.
2. Concluído, Gold (`sql/gold/`): o star schema (fatos e dimensões) foi montado
   sobre a silver; os indicadores KPI-01 a KPI-06, KPI-09 e KPI-18 viraram medidas
   DAX no Power BI, em `powerbi/MEDIDAS_GOLD.dax`.
3. Concluído, Reconciliação (`reconciliar_distratos.py`): os distratos de maio de
   2026 batem ao centavo (54 contra 54, VGV de R$ 12.888.599,11 idêntico nos dois
   lados). O relatório completo está em `reconciliacao/`.
4. Concluído, Seeds populados (`popular_seeds.py`): as regras DP-02, DP-03, DP-04 e
   DP-08, além de DP-01 (gerentes), foram decodificadas a partir do JSON embutido
   no sistema legado, totalizando 343 linhas. DP-07 (profissões) e DP-15 (perfil de
   cliente) ganharam loader em 24/ago/2026. Ainda pendentes, dependendo de planilha
   do SharePoint: feriados e etapa do pré-cadastro.
5. Concluído, Reconciliação de vendas (`reconciliar_vendas.py`): comparada com a
   planilha `Vendas Consolidadas.xlsm`, o VGV bate ao centavo em 98,8% das
   propostas em comum (veja R11). Esse trabalho revelou tanto o atraso do
   fechamento manual (R10) quanto a camada de status manuais sem correspondência
   na API (R9). O relatório completo está em
   `reconciliacao/RECONCILIACAO_VENDAS.md`.

### O que ainda está em aberto

- Rodar a ingestão contra o bronze completo, na instância EC2 de produção: o bronze
  local hoje é parcial, com 1.302 propostas do legado ainda faltando, e a
  reconciliação de totais só fecha de verdade depois da carga cheia.
- Investigar as 23 divergências de VGV apontadas em R11: o padrão de aproximadamente
  R$ 9,5 mil sugere um desconto ou ajuste sistemático, ainda não identificado.
- Validar com a gestão as regras R1 (a definição de "venda"), R3 (canal e mídia), R6
  (as listas de exceção) e R9/R10 (os status manuais e o atraso do fechamento).
- Fazer o Power BI consumir a camada gold, substituindo a conexão direta com a API
  usada na Fase 0.

A cobertura desta versão do catálogo inclui o modelo "Matriz" (cerca de 150
medidas, mais de 40 tabelas) e o modelo "Preço" (12 empreendimentos). As medidas de
interface, marcadas para descarte, já foram catalogadas. A próxima revisão deve
detalhar o DAX completo dos KPIs escolhidos para reconciliação.
