# De-paras — inventário e como atualizar

> Um "de-para" é uma tabela de mapeamento que o CVDW/CRM não fornece (ex.: qual
> escritório é "House", qual gerente responde por qual corretor, qual canal de
> mídia agrupa qual UTM). Vêm de planilhas mantidas manualmente pelo backoffice
> comercial, não da API. Este doc explica **onde cada um vive, como é carregado e
> com que frequência precisa ser atualizado**. Para a regra de negócio por trás de
> cada de-para (a lógica que ele resolve), ver `REGRAS_NEGOCIO.md` (seções `DP-*`).
> Para a fronteira arquitetural (por que isso continua manual mesmo depois da
> migração para a VPS), ver `ARCHITECTURE.md` seção 4.

## Fonte única da verdade

`config/deparas.yml` é o **registro vivo** de todos os de-paras: nome, tabela
silver correspondente, tipo, caminho da planilha fonte (relativo a
`base_sharepoint`) e descrição. É consumido por `montar_estrutura_depara.py`, que
materializa a estrutura versionada em `<DEPARA_DIR>/depara_<nome>/` (pasta lida
pelo Power BI "BI V3 CVDW"). **Ao criar ou mudar um de-para, edite o `.yml`
primeiro** — este documento é um resumo de leitura, não a fonte.

## Tipos de de-para (campo `tipo` no yml)

| Tipo | O que é | Exemplo |
|---|---|---|
| `arquivo` | Copia um `.xlsx`/`.xlsm` já pronto do SharePoint | `dpara_gerente_contexto` |
| `silver` | Materializa uma tabela `silver.*` para Excel (de-para já embutido no pipeline, sem planilha fonte externa) | `dpara_ordem_etapa` |
| `gerado` | Produzido por um script do próprio projeto | `de_para_classificacao.xlsx` (via `gerar_depara_classificacao.py`) |
| `pendente` | Documenta um buraco — ainda sem fonte local carregada | `dpara_profissoes`, `dpara_feriados` |

## Como recarregar

Todos os loaders vivem em `popular_seeds.py`, cada um como uma flag independente
(rode só o que mudou; sem flag, o de-para correspondente **não** é tocado):

| Flag | Carrega |
|---|---|
| `--gerentes <xlsx>` | `dpara_gerente_contexto` + `dpara_imobiliaria_house` (mesma planilha, abas diferentes) |
| `--headcount-corretores <xlsx>` | `dpara_corretor_headcount` (fonte autoritativa de equipe/gerente do corretor) |
| `--leads-apoio <xlsm>` | `dpara_canal_midia`, `dpara_canal_midia_dc`, `dpara_ativo_receptivo`, `dpara_qualificacao_lead` (4 abas da mesma planilha "Base de Leads") |
| `--etapa-precadastro <xlsm>` | `dpara_etapa_precadastro` |
| `--credito-manual <xlsx>` | extra manual de crédito (fora da API) |
| `--xlsm <Vendas Consolidadas.xlsm>` | `dpara_empreendimento` (aba DE_PARA_PRODUTOS) |

Os caminhos default de cada flag vêm do `.env` (`DEPARA_GERENTES_XLSX`,
`HEADCOUNT_CORRETORES_XLSX`, `DEPARA_LEADS_XLSM`, etc. — ver `.env.example`).
Rodar `python aplicar_tudo.py` aplica silver→gold→seeds numa tacada só, mas os
loaders de planilha só disparam se as flags forem passadas explicitamente.

## Inventário completo

| De-para | Tabela `silver.*` | Tipo | Fonte | Recarga |
|---|---|---|---|---|
| Gerentes (contexto da reserva) | `dpara_gerente_contexto` | arquivo | `Gerentes/depara_gerentes.xlsx` | `--gerentes` |
| Imobiliária → House/Regional | `dpara_imobiliaria_house` | arquivo | mesma planilha acima, aba "imobiliaria" | `--gerentes` |
| Equipe do corretor (headcount) | `dpara_corretor_headcount` | arquivo | `HeadCount/Base Corretores Pafil.xlsx` | `--headcount-corretores` |
| Empreendimento → regional/viabilidade/IVV | `dpara_empreendimento_regional` | arquivo | `Empreendimentos/d_para empreendimentos.xlsx` | manual (sem loader ainda) |
| Metas mensais | — | arquivo | `Meta.xlsx` | integrado direto no Power BI (não no Postgres) |
| Estrutura de preços | — | arquivo | `base_precos.xlsm` | — |
| Headcount por equipe/mês | — | arquivo | `depara headcount.xlsx` | — |
| Equipe do corretor (legado, pré-cadastro) | `dpara_equipe_corretor` | arquivo | `Crédito/depara equipe corretor.xlsx` | **sem loader de propósito** — superado por `corretor_headcount` como fonte autoritativa (21/jul/2026) |
| Canal/mídia (até out/24) | `dpara_canal_midia` | arquivo | `Base de Leads.xlsm`, aba Apoio | `--leads-apoio` |
| Canal/mídia D.C (chave UTM, pós out/24) | `dpara_canal_midia_dc` | arquivo | mesma planilha, outra aba | `--leads-apoio` |
| Classificação oficial por proposta | — | gerado | `de_para_classificacao.xlsx` (via `gerar_depara_classificacao.py`) | rodar o gerador |
| Produto → nome conformado + EP | `dpara_empreendimento` | silver | aba DE_PARA_PRODUTOS da Vendas Consolidadas | `--xlsm` |
| Ativo/Receptivo/Diretoria | `dpara_ativo_receptivo` | arquivo | `Base de Leads.xlsm`, aba Apoio | `--leads-apoio` |
| Qualificação do lead (MQL) | `dpara_qualificacao_lead` | arquivo | `Base de Leads.xlsm`, aba Apoio | `--leads-apoio` |
| Etapa/situação → ordem do funil | `dpara_ordem_etapa` | silver | — (regra embutida) | — |
| Situação da reserva → esteira | `dpara_situacao_esteira` | silver | — (regra embutida) | — |
| Corretores fora do ranking (coordenação) | `dpara_corretor_fora_ranking` | silver | — (regra embutida) | — |
| Responsável → imobiliária | `dpara_responsavel_imobiliaria` | silver | — (regra embutida) | — |
| Etapa do pré-cadastro (funil de crédito) | `dpara_etapa_precadastro` | arquivo | `Crédito/Base - Crédito.xlsm`, aba Apoio | `--etapa-precadastro` |
| Profissões (perfil de cliente) | `dpara_profissoes` | **pendente** | ainda sem fonte local | — |
| Feriados (SLA em dias úteis) | `dpara_feriados` | **pendente** | ainda sem fonte local | — |

## "Dono" de cada planilha fonte

Todas as planilhas fonte vivem no SharePoint **COMERCIAL** (`BI - Comercial` /
`Relatórios Comercial`), mantidas pelo backoffice comercial. Quem precisar de
acesso deve pedir ao time comercial/backoffice — o `.env` local aponta para a
cópia sincronizada via OneDrive na máquina de quem roda os loaders (ver
`ONBOARDING.md`).
