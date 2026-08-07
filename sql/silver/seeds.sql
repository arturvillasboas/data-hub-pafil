-- Seeds SILVER: de-paras / tabelas de conformação (DP-* do REGRAS_NEGOCIO.md).
-- Estrutura + dados fixos aqui; os populados por planilha/JSON vão via popular_seeds.py.
-- Idempotente (CREATE IF NOT EXISTS / ON CONFLICT). O `_origem` documenta a fonte.

CREATE SCHEMA IF NOT EXISTS silver;

-- Migração 21/jul/2026: dpara_gerentes (pessoa+contexto misturados na mesma linha,
-- PK = texto cru da reserva) virou dpara_gerente_contexto (abaixo).
DROP TABLE IF EXISTS silver.dpara_gerentes;
-- Migração 21/jul/2026 (passo atrás, mesmo dia): dim_gerente (pessoa via
-- bronze.leads.idgestor) foi DESCARTADA — o dev apontou que "o que vem do CVDW como
-- equipes é falho" (idgestor mistura SDR/robô com gerente de venda; ver
-- [[depara-gerentes-reestruturacao-v2]]). A fonte autoritativa de equipe/gerente/
-- supervisor por CORRETOR é a planilha manual do backoffice (headcount), abaixo.
DROP TABLE IF EXISTS silver.dim_gerente;

-- DP-01 — contexto (PESSOA x imobiliária/regional). Chave = valor CRU do campo
-- customizado "Gerente Responsavel" no CVCRM (campos_adicionais de bronze.reservas) —
-- é a única chave que existe em reservas p/ isso (não há ID lá). 1 pessoa pode ter
-- várias linhas (atua em mais de uma imobiliária/regional): Share/House-Parcerias/
-- Regional variam por CONTEXTO, não só por pessoa. Usada SÓ para reservas (fato_reservas/
-- dim_corretor, via texto) — NÃO usar como fonte de "equipe" do corretor (ver DP-12).
CREATE TABLE IF NOT EXISTS silver.dpara_gerente_contexto (
    gerente_responsavel text PRIMARY KEY,
    gerente_apelido     text,
    share               text,
    house_parcerias     text,
    regional            text,
    _origem             text DEFAULT 'SharePoint: Gerentes/depara_gerentes.xlsx (aba contexto)'
);

-- DP-12 — corretor → gerente/supervisor (headcount). Fonte autoritativa da equipe
-- do corretor: planilha manual do backoffice (Nome, Imobiliaria, House, Gerente,
-- Supervisor, Ativo/Inativo), MAIS confiável que a derivação via reserva mais
-- recente do CVDW (que mistura texto solto e ambiguidade de contexto — ver DP-01).
-- Só carrega corretores ATIVOS (a planilha também tem histórico de desligados, que
-- não interessa p/ ranking/equipe corrente). Chave = nome do corretor (mesmo padrão
-- de DP-09/dpara_corretor_gerente — não há ID comum entre a planilha e o CVDW).
CREATE TABLE IF NOT EXISTS silver.dpara_corretor_headcount (
    corretor    text PRIMARY KEY,
    apelido     text,
    imobiliaria text,
    house       text,
    gerente     text,
    supervisor  text,
    _origem     text DEFAULT 'SharePoint: HeadCount/Base Corretores Pafil 22-23.xlsx (aba Base Pafil, só Ativos)'
);

-- DP-02 — canal/mídia (unifica as 3 versões do legado, com vigência — R3)
-- Chave: "Primeira Origem_Primeira Mídia" (nomes por extenso). Fonte viva:
-- Base de Leads.xlsm, aba Apoio, colunas Canal_Mídia/Canal/Mídia.
CREATE TABLE IF NOT EXISTS silver.dpara_canal_midia (
    concat       text NOT NULL,
    canal        text,
    midia        text,
    vigencia_de  date,
    vigencia_ate date,
    _origem      text DEFAULT 'SharePoint: Leads/depara_bi_matriz.xlsx',
    PRIMARY KEY (concat, vigencia_de)
);

-- DP-02b — canal/mídia "D.C" (chave UTM). É o de-para que decide o canal 2.0 dos
-- leads pós-out/24 no legado. Chave (fiel ao M do f_leads):
--   utm_source & '__' & utm_medium & form_url & '_' & última mídia & '!' & última origem (nome)
-- Fonte viva: Base de Leads.xlsm, aba Apoio, colunas CONCAT/CANAL/MÍDIA/ORIGEM DA MÍDIA.
CREATE TABLE IF NOT EXISTS silver.dpara_canal_midia_dc (
    concat  text PRIMARY KEY,
    canal   text,
    midia   text,
    trafego text,       -- "ORIGEM DA MÍDIA" no xlsm (coluna Tráfego do f_leads)
    _origem text DEFAULT 'SharePoint: Leads/Base de Leads.xlsm (aba Apoio)'
);

-- DP-03 — canal → ativo/receptivo
CREATE TABLE IF NOT EXISTS silver.dpara_ativo_receptivo (
    canal            text PRIMARY KEY,
    lead_ou_prospect text,
    _origem          text DEFAULT 'JSON embutido (dpara_ativo_receptivo)'
);

-- DP-04 — situação do lead → qualificado? (MQL)
CREATE TABLE IF NOT EXISTS silver.dpara_qualificacao_lead (
    situacao    text PRIMARY KEY,
    qualificado text,
    _origem     text DEFAULT 'JSON embutido (dpara_qualificacao_lead)'
);

-- DP-05 — etapa WKF do pré-cadastro → etapa BI (funil de crédito)
CREATE TABLE IF NOT EXISTS silver.dpara_etapa_precadastro (
    etapa_wkf          text PRIMARY KEY,
    etapa_bi           text,
    etapa_bi_detalhada text,
    _origem            text DEFAULT 'SharePoint: Crédito/Base - Crédito.xlsm'
);

-- DP-06 — corretor → categoria
CREATE TABLE IF NOT EXISTS silver.dpara_equipe_corretor (
    corretor           text PRIMARY KEY,
    categoria_corretor text,
    _origem            text DEFAULT 'SharePoint: Crédito/depara equipe corretor.xlsx'
);

-- Extra manual de crédito (NÃO é de-para — 1 linha por pré-cadastro, não uma
-- tabela de lookup). "Aprovação de crédito" e "Encaminhado ao CCA" são colunas
-- nativas do export "Relatório Web" do CVCRM (Crédito/Relatório Web/
-- relatorios_precadastro.xlsx) que NÃO existem na API CVDW — cobrem só os
-- pré-cadastros tocados recentemente pelo time de crédito (~9% do total;
-- maioria fica NULL, e é esperado — não é "sem match", é "ainda não chegou
-- nessa etapa do fluxo"). Alimenta os 2 donuts "Aprovação de Crédito" e
-- "Encaminhado ao CCA" da página Pré Cadastro do BI Legado.
CREATE TABLE IF NOT EXISTS silver.precadastros_credito_manual (
    id_precadastro    bigint PRIMARY KEY,
    aprovacao_credito text,
    encaminhado_cca   text,
    _origem           text DEFAULT 'SharePoint: Crédito/Relatório Web/relatorios_precadastro.xlsx'
);

-- DP-09 — corretor → gerente/equipe (override manual; papel do d_equipes legado).
-- A equipe do corretor é derivada da sua reserva mais recente com gerente
-- preenchido (ver gold.dim_corretor); esta seed força/completa a atribuição
-- (corretor sem reserva, ou com equipe errada). Chave = nome do corretor.
CREATE TABLE IF NOT EXISTS silver.dpara_corretor_gerente (
    corretor            text PRIMARY KEY,
    gerente_responsavel text,
    _origem             text DEFAULT 'Manual (DP-09; complementa derivação via reservas)'
);

-- DP-07 — profissão → micro / macro
CREATE TABLE IF NOT EXISTS silver.dpara_profissoes (
    original text PRIMARY KEY,
    micro    text,
    macro    text,
    _origem  text DEFAULT 'SharePoint: BI Matriz/de_para profissões.xlsx'
);

-- DP-08 — etapa (situação) → ordem
CREATE TABLE IF NOT EXISTS silver.dpara_ordem_etapa (
    etapa   text PRIMARY KEY,
    ordem   int,
    _origem text DEFAULT 'JSON embutido (dpara_ordem_etapa)'
);

-- DP-11 — feriados (calendário útil)
CREATE TABLE IF NOT EXISTS silver.dpara_feriados (
    data    date PRIMARY KEY,
    feriado text,
    _origem text DEFAULT 'SharePoint: BI Matriz/depara feriados brasil 2025.xlsx'
);

-- ING-06 — normalização de nome de empreendimento (+ EP da aba DE_PARA_PRODUTOS)
CREATE TABLE IF NOT EXISTS silver.dpara_empreendimento (
    nome_origem     text PRIMARY KEY,
    nome_conformado text,
    codigo_cv       int,
    ep              text,
    _origem         text DEFAULT 'DE_PARA_PRODUTOS + d_para empreendimentos.xlsx'
);
ALTER TABLE silver.dpara_empreendimento ADD COLUMN IF NOT EXISTS ep text;
CREATE INDEX IF NOT EXISTS ix_dpara_empreend_norm
    ON silver.dpara_empreendimento (upper(btrim(nome_origem)));

-- Conforma o nome do empreendimento case-insensitive (fallback = nome com trim).
CREATE OR REPLACE FUNCTION silver.conformar_empreendimento(nome text)
RETURNS text AS $$
    SELECT coalesce(
        (SELECT nome_conformado FROM silver.dpara_empreendimento
          WHERE upper(btrim(nome_origem)) = upper(btrim(nome)) AND nome_conformado IS NOT NULL
          LIMIT 1),
        btrim(nome)
    );
$$ LANGUAGE sql STABLE;

-- ING-04 — corretor que responde pela própria imobiliária ("Ajuste Castro")
CREATE TABLE IF NOT EXISTS silver.dpara_responsavel_imobiliaria (
    corretor            text PRIMARY KEY,
    responsavel_forcado text,
    _origem             text DEFAULT 'ING-04 (Ajuste Castro no Power Query de f_reservas)'
);
INSERT INTO silver.dpara_responsavel_imobiliaria (corretor, responsavel_forcado)
VALUES ('JOSÉ ROBERTO DE CASTRO JUNIOR', 'José Roberto de Castro Junior')
ON CONFLICT (corretor) DO NOTHING;

-- DP-13 — imobiliária (escritório) → Share / House-Parcerias / Regional.
-- É por AQUI que leads e pré-cadastros ganham a classificação que a reserva já tinha
-- via dpara_gerente_contexto (21/jul/2026): o corretor não tem "Gerente Responsavel"
-- nessas fatos, mas o headcount diz em qual ESCRITÓRIO ele está, e o escritório
-- determina Share/House/Regional. Decisão do dev: a regional sai da coluna
-- `Imobiliaria` do headcount (a coluna `House` de lá tem 2 linhas erradas com
-- "EP - RP" arrastado — Joao Victor e Carlos Roberto são Uberaba e São Carlos).
--
-- Dados agora vêm da aba "imobiliaria" do depara_gerentes.xlsx (antes eram hard-code
-- aqui): a classificação é decisão COMERCIAL e tem que ficar no arquivo que o Artur
-- mantém, não escondida no SQL. Variante de grafia é linha nova na aba (o headcount
-- escreve "ESPACO DE NEGOCIO PAFIL UBERABA", no singular).
CREATE TABLE IF NOT EXISTS silver.dpara_imobiliaria_house (
    imobiliaria     text PRIMARY KEY,
    house_parcerias text,   -- 'House' | 'Parcerias'
    regional        text,   -- RPO | URA | SCA | MTO
    _origem         text DEFAULT 'SharePoint: Gerentes/depara_gerentes.xlsx (aba imobiliaria)'
);
ALTER TABLE silver.dpara_imobiliaria_house ADD COLUMN IF NOT EXISTS share text;  -- ex.: 'House RPO'

-- Corretores fora do ranking (gerentes/coordenação — o DAX legado excluía por nome).
CREATE TABLE IF NOT EXISTS silver.dpara_corretor_fora_ranking (
    corretor text PRIMARY KEY,
    motivo   text,
    _origem  text DEFAULT 'Exclusão do ranking no DAX legado'
);
INSERT INTO silver.dpara_corretor_fora_ranking (corretor, motivo) VALUES
    ('Regiane Aparecida da Silva Padilha', 'gerente/coordenação')
ON CONFLICT (corretor) DO NOTHING;

-- Regional "casa" do empreendimento (1 por empreendimento). Chave = código interno (= codigo_cv da meta).
CREATE TABLE IF NOT EXISTS silver.dpara_empreendimento_regional (
    codigo_interno_empreendimento bigint PRIMARY KEY,
    regional                      text,
    _origem                       text DEFAULT 'dim_metas_empreendimentos (regional por empreendimento)'
);
INSERT INTO silver.dpara_empreendimento_regional (codigo_interno_empreendimento, regional) VALUES
    (175,'RPO'),(2413,'RPO'),(5778,'RPO'),(5958,'URA'),(7915,'RPO'),(8883,'URA'),
    (9743,'RPO'),(10093,'RPO'),(12565,'RPO'),(13146,'MTO'),(13331,'URA'),(13998,'RPO'),
    (14993,'SCA'),(15840,'RPO'),(20587,'RPO')
ON CONFLICT (codigo_interno_empreendimento) DO NOTHING;

-- Situação da reserva → ordem do funil da esteira (1..13 pipeline aberto; 14..16 desfecho).
CREATE TABLE IF NOT EXISTS silver.dpara_situacao_esteira (
    situacao         text PRIMARY KEY,
    ordem            int,
    situacao_tratada text,
    _origem          text DEFAULT 'Coluna "Situação Tratada" do Power Query legado'
);
INSERT INTO silver.dpara_situacao_esteira (situacao, ordem, situacao_tratada) VALUES
    ('Nova Reserva',               1,  '01. Nova Reserva'),
    ('Análise Proposta',           2,  '02. Análise Proposta'),
    ('Geração de Contrato',        3,  '03. Geração de Contrato'),
    ('Ajustes Contrato',           4,  '04. Ajustes Contrato'),
    ('Contrato Gerado',            5,  '05. Contrato Gerado'),
    ('Contrato Enviado',           6,  '06. Contrato Enviado'),
    ('Contrato Assinado Cliente',  7,  '07. Contrato Assinado Cliente'),
    ('Aguardando Comprovante',     8,  '08. Aguardando Comprovante'),
    ('Pagamento Efetivado',        9,  '09. Pagamento Efetivado'),
    ('Validado Comercial',         10, '10. Validado Comercial'),
    ('Envio Mega',                 11, '11. Envio Mega'),
    ('Vencida',                    12, '12. Vencida'),
    ('Ajuste Integracao',          13, '13. Ajuste Integracao'),
    ('Vendida',                    14, '14. Vendida'),
    ('Cancelada',                  15, '15. Cancelada'),
    ('Distrato',                   16, '16. Distrato')
ON CONFLICT (situacao) DO NOTHING;
