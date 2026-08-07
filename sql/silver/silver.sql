-- Camada SILVER: views de conformação sobre a bronze (tipagem forte, nomes de
-- negócio, flags de regra). Aplicar com aplicar_silver.py. Ver REGRAS_NEGOCIO.md.

CREATE SCHEMA IF NOT EXISTS silver;

-- Casts tolerantes: devolvem NULL em vez de estourar a view em valor mal-formado.
CREATE OR REPLACE FUNCTION silver.tentar_timestamptz(t text)
RETURNS timestamptz AS $$
BEGIN
    IF t IS NULL OR btrim(t) = '' THEN RETURN NULL; END IF;
    RETURN t::timestamptz;
EXCEPTION WHEN others THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION silver.tentar_numeric(t text)
RETURNS numeric AS $$
BEGIN
    IF t IS NULL OR btrim(t) = '' THEN RETURN NULL; END IF;
    RETURN replace(replace(btrim(t), '.', ''), ',', '.')::numeric;  -- tolera 1.234,56 (BR)
EXCEPTION WHEN others THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- numeric → texto sem ".0" (CNPJ/RG vieram numeric na bronze mas são identificadores).
CREATE OR REPLACE FUNCTION silver.id_texto(v numeric)
RETURNS text AS $$
    SELECT CASE WHEN v IS NULL THEN NULL ELSE trim(to_char(v, 'FM999999999999999990')) END;
$$ LANGUAGE sql IMMUTABLE;

-- Lê um campo do array campos_adicionais do CVDW ([{"nome":..,"valor":..}, ...]).
CREATE OR REPLACE FUNCTION silver.campo_adicional(campos jsonb, nome text)
RETURNS text AS $$
    SELECT nullif(btrim(e->>'valor'), '')
    FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(campos) = 'array' THEN campos ELSE '[]'::jsonb END
    ) e
    WHERE e->>'nome' = nome
    LIMIT 1;
$$ LANGUAGE sql IMMUTABLE;


-- ===========================================================================
-- NOMES DE PESSOA (corretor/gerente/supervisor). O nome é digitado à mão nos DOIS
-- lados — headcount do backoffice e CVCRM — e diverge em caixa e acento, o que
-- quebra qualquer junção por nome (é a única chave comum: não há id_corretor no
-- headcount). Daí o par de funções: uma para EXIBIR, outra para JUNTAR.
-- ===========================================================================

-- Nome próprio no padrão pt-BR: "Maisa Cristina de Paula e Silva".
-- Title Case por palavra, com os conectivos (de/da/do/das/dos/e) em minúscula
-- quando não são a primeira palavra — é o padrão brasileiro e o que o CVDW já usa
-- na maioria dos registros. O initcap nativo não serve sozinho: maiusculiza o
-- conectivo ("De Paula E Silva") e, em cluster com locale C, não trata acentuado
-- sem COLLATE ICU ('TONHÃO' -> 'tonhÃo'). Também apara e colapsa espaço interno.
-- NB: "Di"/"Del"/"Van" ficam capitalizados de propósito (costumam integrar o
-- sobrenome, não são conectivo português).
CREATE OR REPLACE FUNCTION silver.nome_proprio(t text)
RETURNS text AS $$
    SELECT nullif(string_agg(
               CASE WHEN u.i > 1
                     AND lower(u.tok COLLATE "und-x-icu") IN ('de','da','do','das','dos','e')
                    THEN lower(u.tok COLLATE "und-x-icu")
                    ELSE initcap(u.tok COLLATE "und-x-icu")
               END, ' ' ORDER BY u.i), '')
    FROM unnest(
        string_to_array(btrim(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g')), ' ')
    ) WITH ORDINALITY AS u(tok, i)
    WHERE u.tok <> '';
$$ LANGUAGE sql STABLE;

-- Chave de junção por nome: minúscula, SEM acento, espaço colapsado. Sustenta o
-- relacionamento (Power BI) enquanto nome_proprio() cuida da exibição — assim
-- "ESTEFANE VITORIA ALVES DE SOUZA" (headcount, sem acento) casa com
-- "Estéfane Vitória Alves de Souza" (CVDW) sem estragar o nome mostrado ao usuário,
-- e erro futuro de digitação em caixa/acento não quebra o vínculo.
-- translate() em vez da extensão unaccent: evita dependência de contrib no deploy
-- (a unaccent está disponível mas NÃO instalada neste cluster).
CREATE OR REPLACE FUNCTION silver.chave_nome(t text)
RETURNS text AS $$
    SELECT nullif(
        lower(
            translate(
                btrim(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g')),
                'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
                'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn'
            ) COLLATE "und-x-icu"
        ), '');
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE VIEW silver.reservas AS
SELECT
    r.idreserva::bigint                                   AS id_reserva,
    r.idcliente::bigint                                   AS id_cliente,
    r.idcorretor::bigint                                  AS id_corretor,
    r.idimobiliaria::bigint                               AS id_imobiliaria,
    r.idempreendimento::bigint                            AS id_empreendimento,
    r.idunidade::bigint                                   AS id_unidade,
    nullif(btrim(r.idlead), '')                           AS id_lead,
    r.idprecadastro::bigint                               AS id_precadastro,
    r.codigointerno                                       AS codigo_interno,
    r.codigointerno_empreendimento::bigint                AS codigo_interno_empreendimento,
    r.numero_venda,

    btrim(r.empreendimento)                               AS empreendimento,
    btrim(r.etapa)                                        AS etapa,
    btrim(r.bloco)                                        AS bloco,
    btrim(r.unidade)                                      AS unidade,
    btrim(r.regiao)                                       AS regiao,
    btrim(r.corretor)                                     AS corretor,
    btrim(r.imobiliaria)                                  AS imobiliaria,
    btrim(r.campanha)                                     AS campanha,
    btrim(r.midia)                                        AS midia,
    btrim(r.tipovenda)                                    AS tipo_venda,
    btrim(r.grupo)                                        AS grupo,
    btrim(r.nome_time)                                    AS time_venda,
    btrim(r.nometabela)                                   AS tabela_preco,

    btrim(r.situacao)                                     AS situacao,
    btrim(r.situacao_comercial)                           AS situacao_comercial,
    btrim(r.situacao_anterior)                            AS situacao_anterior,
    btrim(r.aprovada)                                     AS aprovada,
    btrim(r.ativo)                                        AS ativo,

    r.data_cad,
    r.data_venda,
    r.data_aprovacao,
    r.data_modificacao,
    silver.tentar_timestamptz(r.data_contrato)            AS data_contrato,
    silver.tentar_timestamptz(r.data_cancelamento)        AS data_cancelamento,
    silver.tentar_timestamptz(r.data_ultima_alteracao_situacao) AS data_ultima_alteracao_situacao,

    r.valor_contrato,
    r.valor_contrato_com_juros,
    r.valor_proposta,
    r.valor_liquido_com_juros,
    r.valor_liquido_sem_juros,
    r.valor_fgts,
    r.valor_financiamento,
    r.valor_subsidio,
    r.vgv_tabela,
    r.vpl_tabela,

    btrim(r.cliente)                                      AS cliente,
    r.documento_cliente,
    r.cep_cliente,
    btrim(r.cidade)                                       AS cidade,
    r.sexo,
    r.idade,
    btrim(r.estado_civil)                                 AS estado_civil,
    r.renda,

    btrim(r.motivo_cancelamento)                          AS motivo_cancelamento,
    btrim(r.descricao_motivo_cancelamento)                AS descricao_motivo_cancelamento,

    -- R1: "venda" tem 2 definições no legado; expõe as duas.
    (btrim(r.situacao) = 'Vendida')                       AS eh_venda,
    (btrim(r.situacao) IN ('Vendida','Distrato'))         AS eh_venda_ou_distrato,
    (btrim(r.situacao) = 'Distrato')                      AS eh_distrato,
    (lower(btrim(r.aprovada)) IN ('sim','aprovada','aprovado','true','1')) AS eh_aprovada,
    -- 's': o CVDW manda S/N nestes campos (sem o 's' a flag saía sempre false)
    (lower(btrim(coalesce(r.ativo,''))) IN ('s','sim','true','1','ativo')) AS eh_ativo,

    EXTRACT(YEAR  FROM r.data_venda)::int                 AS ano_venda,
    EXTRACT(MONTH FROM r.data_venda)::int                 AS mes_venda,
    to_char(r.data_venda, 'YYYY-MM')                      AS ano_mes_venda,

    r._data_extracao,
    -- campos customizados do CRM (vivem no array campos_adicionais)
    silver.campo_adicional(r.campos_adicionais, 'Gerente Responsavel')           AS gerente_responsavel,
    silver.campo_adicional(r.campos_adicionais, 'Tipo de Venda')                 AS cf_tipo_venda,
    silver.campo_adicional(r.campos_adicionais, 'Modalidade Financiamento')      AS cf_modalidade_financiamento,
    silver.campo_adicional(r.campos_adicionais, 'Motivo do Distrato')            AS cf_motivo_distrato,
    silver.campo_adicional(r.campos_adicionais, 'Classificação Vendas Internas') AS cf_classificacao_vendas_internas
FROM bronze.reservas r;


-- Endpoint /vendas do CRM (não é derivado de reservas — a reconciliação confere os dois).
CREATE OR REPLACE VIEW silver.vendas AS
SELECT
    v.idreserva::bigint                                   AS id_reserva,
    v.idcliente::bigint                                   AS id_cliente,
    v.idcorretor::bigint                                  AS id_corretor,
    v.idimobiliaria::bigint                               AS id_imobiliaria,
    v.idempreendimento::bigint                            AS id_empreendimento,
    v.idunidade::bigint                                   AS id_unidade,
    v.idlead::bigint                                      AS id_lead,
    v.codigointerno_empreendimento::bigint                AS codigo_interno_empreendimento,
    v.contrato_interno,

    btrim(v.empreendimento)                               AS empreendimento,
    btrim(v.etapa)                                        AS etapa,
    btrim(v.bloco)                                        AS bloco,
    btrim(v.unidade)                                      AS unidade,
    btrim(v.regiao)                                       AS regiao,
    btrim(v.corretor)                                     AS corretor,
    btrim(v.imobiliaria)                                  AS imobiliaria,
    btrim(v.midia)                                        AS midia,
    btrim(v.campanha)                                     AS campanha,
    btrim(v.tipovenda)                                    AS tipo_venda,
    btrim(v.planta)                                       AS planta,
    btrim(v.aprovada)                                     AS aprovada,

    v.data_reserva,
    v.data_venda,
    v.data_historico,
    v.valor_contrato,
    v.area_privativa,
    CASE WHEN v.area_privativa > 0
         THEN round(v.valor_contrato / v.area_privativa, 2) END AS preco_m2,

    btrim(v.cliente)                                      AS cliente,
    v.documento_cliente,
    v.cep_cliente,

    EXTRACT(YEAR  FROM v.data_venda)::int                 AS ano_venda,
    EXTRACT(MONTH FROM v.data_venda)::int                 AS mes_venda,
    to_char(v.data_venda, 'YYYY-MM')                      AS ano_mes_venda,
    v._data_extracao
FROM bronze.vendas v;


CREATE OR REPLACE VIEW silver.distratos AS
SELECT
    d.idreserva::bigint                                   AS id_reserva,
    d.idcliente::bigint                                   AS id_cliente,
    d.idcorretor::bigint                                  AS id_corretor,
    d.idimobiliaria::bigint                               AS id_imobiliaria,
    d.idempreendimento::bigint                            AS id_empreendimento,
    d.idunidade::bigint                                   AS id_unidade,
    d.codigointerno_empreendimento::bigint                AS codigo_interno_empreendimento,

    btrim(d.empreendimento)                               AS empreendimento,
    btrim(d.etapa)                                        AS etapa,
    btrim(d.bloco)                                        AS bloco,
    silver.id_texto(d.unidade)                            AS unidade,
    btrim(d.regiao)                                       AS regiao,
    btrim(d.corretor)                                     AS corretor,
    btrim(d.imobiliaria)                                  AS imobiliaria,
    btrim(d.situacao_atual)                               AS situacao_atual,
    btrim(d.motivo_distrato)                              AS motivo_distrato,
    btrim(d.descricao_motivo_distrato)                    AS descricao_motivo_distrato,

    d.data_cad,
    d.situacao_data                                       AS data_situacao,
    d.data_sincronizacao,
    d.valor_contrato,

    btrim(d.cliente)                                      AS cliente,
    d.documento                                           AS documento_cliente,
    d.cep_cliente,

    -- data-ref do distrato = situacao_data, com fallback (alguns têm situacao_data nula)
    EXTRACT(YEAR  FROM coalesce(d.situacao_data, d.data_sincronizacao, d.data_cad))::int  AS ano_distrato,
    EXTRACT(MONTH FROM coalesce(d.situacao_data, d.data_sincronizacao, d.data_cad))::int  AS mes_distrato,
    to_char(coalesce(d.situacao_data, d.data_sincronizacao, d.data_cad), 'YYYY-MM')       AS ano_mes_distrato,
    d._data_extracao,
    coalesce(d.situacao_data, d.data_sincronizacao, d.data_cad) AS data_ref_distrato
FROM bronze.distratos d;


CREATE OR REPLACE VIEW silver.unidades AS
SELECT
    u.idunidade::bigint                                   AS id_unidade,
    u.idempreendimento::bigint                            AS id_empreendimento,
    btrim(u.nome_empreendimento)                          AS empreendimento,
    btrim(u.tipo_empreendimento)                          AS tipo_empreendimento,
    btrim(u.etapa)                                        AS etapa,
    btrim(u.bloco)                                        AS bloco,
    btrim(u.nome)                                         AS unidade,
    u.area_privativa,
    u.area_comum,
    u.andar,
    btrim(u.tipologia)                                    AS tipologia,
    btrim(u.tipo)                                         AS tipo,
    u.vagas_garagem,
    u.valor                                               AS preco,
    CASE WHEN u.area_privativa > 0
         THEN round(u.valor / u.area_privativa, 2) END    AS preco_m2,
    btrim(u.situacao_nome)                                AS situacao,
    (u.situacao_vendida = 1)                              AS eh_vendida,
    u._data_extracao,
    u.idempreendimento_int::bigint                        AS codigo_interno_empreendimento  -- = codigo_cv das metas
FROM bronze.unidades u;


-- DROP: eh_ativo_login entrou no meio da lista (CREATE OR REPLACE não permite);
-- a gold.dim_corretor (dependente) é recriada pelo aplicar_gold na sequência.
DROP VIEW IF EXISTS silver.corretores CASCADE;
CREATE VIEW silver.corretores AS
SELECT
    c.idcorretor::bigint                                  AS id_corretor,
    c.idimobiliaria::bigint                               AS id_imobiliaria,
    btrim(c.nome)                                         AS nome,
    btrim(c.apelido)                                      AS apelido,
    btrim(c.imobiliaria)                                  AS imobiliaria,
    btrim(c.categoria)                                    AS categoria,
    btrim(c.nivel)                                        AS nivel,
    c.creci::text                                         AS creci,
    btrim(c.situacao_creci)                               AS situacao_creci,
    c.documento                                           AS documento,
    btrim(c.email)                                        AS email,
    btrim(c.cidade)                                       AS cidade,
    btrim(c.estado)                                       AS estado,
    c.sexo,
    -- CVDW manda S/N. NB: corretores.ativo é 'S' para TODOS (campo inútil p/ filtro);
    -- quem varia é ativo_login (acesso ao CV habilitado) — use eh_ativo_login.
    (lower(btrim(coalesce(c.ativo,'')))       IN ('s','sim','true','1','ativo')) AS eh_ativo,
    (lower(btrim(coalesce(c.ativo_login,''))) IN ('s','sim','true','1','ativo')) AS eh_ativo_login,
    c._data_extracao
FROM bronze.corretores c;


CREATE OR REPLACE VIEW silver.imobiliarias AS
SELECT
    i.idimobiliaria::bigint                               AS id_imobiliaria,
    btrim(i.nome)                                         AS nome,
    btrim(i.razao_social)                                 AS razao_social,
    silver.id_texto(i.cnpj)                               AS cnpj,
    btrim(i.sigla)                                        AS sigla,
    btrim(i.creci)                                        AS creci,
    i.idcidade::bigint                                    AS id_cidade,
    btrim(i.bairro)                                       AS bairro,
    btrim(i.email)                                        AS email,
    btrim(i.gerente_nome)                                 AS gerente,
    btrim(i.diretor_nome)                                 AS diretor,
    (lower(btrim(coalesce(i.ativo,''))) IN ('s','sim','true','1','ativo')) AS eh_ativo,
    i._data_extracao
FROM bronze.imobiliarias i;


-- ===========================================================================
-- LEADS + PRÉ-CADASTROS (funil de marketing/comercial). Conformação PURA sobre
-- a bronze — sem dependência de seed (as de-paras entram na gold). PII direta
-- (nome/email/telefone/documento) é omitida de propósito: o funil não precisa e
-- os dados têm PII real (ver "Decisões fechadas" do projeto).
-- ===========================================================================

CREATE OR REPLACE VIEW silver.leads AS
SELECT
    l.idlead::bigint                                      AS id_lead,
    l.idsituacao::bigint                                  AS id_situacao,
    btrim(l.situacao)                                     AS situacao,
    btrim(l.nome_situacao_anterior_lead)                  AS situacao_anterior,

    l.data_cad,
    l.data_ultima_interacao,
    l.ultima_data_conversao,
    l.data_cancelamento,
    l.data_vencimento,
    l.data_ultima_alteracao,

    -- origem / mídia: a API traz a "primeira" (original) e a "última" conversão
    btrim(l.origem)                                       AS origem,
    btrim(l.origem_ultimo)                                AS origem_ultimo,
    btrim(l.origem_nome)                                  AS origem_nome,
    btrim(l.origem_ultimo_nome)                           AS origem_ultimo_nome,
    btrim(l.midia_original)                               AS midia_original,
    btrim(l.midia_ultimo)                                 AS midia_ultimo,
    btrim(l.conversao_original)                           AS conversao_original,
    btrim(l.conversao_ultimo)                             AS conversao_ultimo,
    btrim(l.ponto_venda)                                  AS ponto_venda,

    l.idgestor::bigint                                    AS id_gestor,
    btrim(l.gestor)                                       AS gestor,
    l.idcorretor::bigint                                  AS id_corretor,
    btrim(l.corretor)                                     AS corretor,
    l.idimobiliaria::bigint                               AS id_imobiliaria,
    btrim(l.imobiliaria)                                  AS imobiliaria,

    l.idempreendimento::bigint                            AS id_empreendimento,
    btrim(l.empreendimento)                               AS empreendimento,
    l.codigointerno_empreendimento::bigint                AS codigo_interno_empreendimento,
    btrim(l.empreendimento_primeiro)                      AS empreendimento_primeiro,
    btrim(l.empreendimento_ultimo)                        AS empreendimento_ultimo,

    btrim(l.cidade)                                       AS cidade,
    btrim(l.estado)                                       AS estado,
    btrim(l.regiao)                                       AS regiao,

    l.score,
    l.possibilidade_venda,
    btrim(l.profissao)                                    AS profissao,
    btrim(l.renda_familiar)                               AS renda_familiar,
    btrim(l.motivo)                                       AS motivo,
    btrim(l.motivo_cancelamento)                          AS motivo_cancelamento,
    btrim(l.descricao_motivo_cancelamento)                AS descricao_motivo_cancelamento,
    btrim(l.submotivo_cancelamento)                       AS submotivo_cancelamento,
    btrim(l.nome_momento_lead)                            AS momento_lead,

    -- flags de estado do lead
    (lower(btrim(coalesce(l.ativo,'')))   IN ('s','sim','true','1','ativo')) AS eh_ativo,
    (lower(btrim(coalesce(l.vencido,''))) IN ('s','sim','true','1'))         AS eh_vencido,
    (lower(btrim(coalesce(l.novo,'')))    IN ('s','sim','true','1'))         AS eh_novo,
    (lower(btrim(coalesce(l.retorno,''))) IN ('s','sim','true','1'))         AS eh_retorno,
    -- conversão de marketing (teve evento) vs conversão comercial (virou reserva)
    (l.ultima_data_conversao IS NOT NULL)                AS eh_convertido,
    (coalesce(l.reserva, 0) > 0)                          AS eh_convertido_reserva,
    l.reserva                                             AS qtd_reservas,

    EXTRACT(YEAR  FROM l.data_cad)::int                   AS ano_cad,
    EXTRACT(MONTH FROM l.data_cad)::int                   AS mes_cad,
    to_char(l.data_cad, 'YYYY-MM')                        AS ano_mes_cad,
    l._data_extracao,
    -- UTM (campos adicionais jsonb, mesmos cf_* do CSV legado): base da chave do
    -- de-para canal/mídia "D.C" que decide o canal 2.0 (ver gold.fato_leads).
    silver.campo_adicional(l.campos_adicionais, 'utm_source')  AS utm_source,
    silver.campo_adicional(l.campos_adicionais, 'utm_medium')  AS utm_medium,
    silver.campo_adicional(l.campos_adicionais, 'form_url')    AS form_url,
    -- "corretor" some quando o lead é Perdido (a API limpa o campo, 99,9% vazio);
    -- o último corretor que atendeu antes disso fica aqui (~65% preenchido).
    l.idcorretor_ultimo::bigint                           AS id_corretor_ultimo,
    btrim(l.corretor_ultimo)                              AS corretor_ultimo
FROM bronze.leads l;


CREATE OR REPLACE VIEW silver.precadastros AS
SELECT
    p.idprecadastro::bigint                               AS id_precadastro,
    p.codigointerno                                       AS codigo_interno,
    nullif(p.idlead, 0)::bigint                           AS id_lead,       -- liga o funil ao lead
    p.idpessoa::bigint                                    AS id_pessoa,
    p.idsituacao::bigint                                  AS id_situacao,
    btrim(p.situacao)                                     AS situacao,
    btrim(p.situacao_anterior)                            AS situacao_anterior,
    btrim(p.condicao_aprovada)                            AS condicao_aprovada,

    p.idempreendimento::bigint                            AS id_empreendimento,
    btrim(p.empreendimento)                               AS empreendimento,
    nullif(btrim(p.idunidade), '')                        AS id_unidade,
    btrim(p.unidade)                                      AS unidade,
    p.idcorretor::bigint                                  AS id_corretor,
    btrim(p.corretor)                                     AS corretor,
    p.idimobiliaria::bigint                               AS id_imobiliaria,
    btrim(p.imobiliaria)                                  AS imobiliaria,

    btrim(p.tabela)                                       AS tabela_credito,
    btrim(p.intencao_compra)                              AS intencao_compra,

    p.valor_avaliacao,
    p.valor_aprovado,
    p.valor_subsidio,
    p.valor_fgts,
    p.valor_total,
    p.saldo_devedor,
    p.valor_prestacao,
    p.renda_cliente_principal,
    p.renda_total,

    p.data_cad,
    p.vencimento_aprovacao,
    p.data_ultima_alteracao_situacao,

    btrim(p.motivo_reprovacao)                            AS motivo_reprovacao,
    btrim(p.descricao_motivo_reprovacao)                  AS descricao_motivo_reprovacao,
    btrim(p.motivo_cancelamento)                          AS motivo_cancelamento,
    btrim(p.descricao_motivo_cancelamento)                AS descricao_motivo_cancelamento,

    -- desfecho do crédito. condicao_aprovada é código: 'S'=aprovado, 'N'=não, 'R'=c/ restrição.
    -- Reprovado/cancelado pela situação (nomes legíveis) — motivo pode vir vazio.
    (upper(btrim(coalesce(p.condicao_aprovada,''))) = 'S')              AS eh_aprovado,
    (p.situacao ILIKE '%reprovad%')                                    AS eh_reprovado,
    (p.situacao ILIKE '%cancelad%')                                    AS eh_cancelado,

    EXTRACT(YEAR  FROM p.data_cad)::int                   AS ano_cad,
    EXTRACT(MONTH FROM p.data_cad)::int                   AS mes_cad,
    to_char(p.data_cad, 'YYYY-MM')                        AS ano_mes_cad,
    p._data_extracao
FROM bronze.precadastros p;


-- Conversões do lead ao longo do tempo (marketing multi-touch). PII omitida.
CREATE OR REPLACE VIEW silver.leads_conversoes AS
SELECT
    c.idlead_conversao::bigint                            AS id_conversao,
    c.idlead::bigint                                      AS id_lead,
    c.conversao                                           AS data_conversao,
    c.data_cad,
    btrim(c.origem)                                       AS origem,
    btrim(c.origem_conversao)                             AS origem_conversao,
    btrim(c.midia)                                        AS midia,
    btrim(c.midia_conversao)                              AS midia_conversao,
    c.gestor::bigint                                      AS id_gestor,
    c.corretor::bigint                                    AS id_corretor,
    btrim(c.corretor_ultimo)                              AS corretor_ultimo,
    c.empreendimento_ultimo::bigint                       AS id_empreendimento_ultimo,
    EXTRACT(YEAR  FROM c.conversao)::int                  AS ano_conversao,
    EXTRACT(MONTH FROM c.conversao)::int                  AS mes_conversao,
    to_char(c.conversao, 'YYYY-MM')                       AS ano_mes_conversao,
    c._data_extracao
FROM bronze.leads_conversoes c;
