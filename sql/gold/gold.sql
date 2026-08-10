-- Camada GOLD: star schema (fato + dimensões) sobre a silver, para o Power BI.
-- Aplicar com aplicar_gold.py. Ver MODELO_SEMANTICO.md e REGRAS_NEGOCIO.md.

CREATE SCHEMA IF NOT EXISTS gold;

-- Calendário diário cobrindo TODOS os fatos (reservas, leads, pré-cadastros), não só
-- as reservas: leads começam em 2018 e cairiam fora se o range viesse só de reservas.
-- Nomes de mês pt-BR via array.
-- DROP: CREATE OR REPLACE não deixa acrescentar coluna (mes_nome).
DROP VIEW IF EXISTS gold.dim_calendario CASCADE;
CREATE VIEW gold.dim_calendario AS
WITH bounds AS (
    SELECT min(data_cad) AS dmin, max(data_cad) AS dmax FROM silver.reservas
    UNION ALL SELECT min(data_venda), max(data_venda) FROM silver.reservas
    UNION ALL SELECT min(data_cad),   max(data_cad)   FROM silver.leads
    UNION ALL SELECT min(data_cad),   max(data_cad)   FROM silver.precadastros
),
limites AS (
    SELECT make_date(EXTRACT(YEAR FROM min(dmin))::int, 1, 1) AS dmin,
           make_date(GREATEST(
               EXTRACT(YEAR FROM max(dmax)),
               EXTRACT(YEAR FROM CURRENT_DATE)
           )::int, 12, 31) AS dmax
    FROM bounds
),
dias AS (
    -- ::timestamp (sem fuso) evita o drift de DST do generate_series sobre timestamptz
    -- (o Brasil teve horário de verão até 2019; sem isso, 31/dez se perde).
    SELECT generate_series(dmin::timestamp, dmax::timestamp, interval '1 day')::date AS data FROM limites
)
SELECT
    data,
    EXTRACT(YEAR    FROM data)::int                       AS ano,
    EXTRACT(MONTH   FROM data)::int                        AS mes,
    EXTRACT(DAY     FROM data)::int                        AS dia,
    (ARRAY['jan','fev','mar','abr','mai','jun',
           'jul','ago','set','out','nov','dez'])[EXTRACT(MONTH FROM data)::int] AS mes_abrev,
    (ARRAY['janeiro','fevereiro','março','abril','maio','junho','julho',
           'agosto','setembro','outubro','novembro','dezembro'])[EXTRACT(MONTH FROM data)::int] AS mes_nome,
    to_char(data, 'YYYY-MM')                               AS ano_mes,
    'T' || EXTRACT(QUARTER FROM data)::int                 AS trimestre,
    EXTRACT(ISODOW FROM data)::int                         AS dia_semana,
    (EXTRACT(ISODOW FROM data) >= 6)                       AS eh_fim_semana
FROM dias;


-- Empreendimento (sem objeto próprio na API): derivado de unidades.
-- codigo_interno_empreendimento = codigo_cv das metas; regional = regional "casa" (seed).
CREATE OR REPLACE VIEW gold.dim_empreendimento AS
SELECT DISTINCT ON (u.id_empreendimento)
    u.id_empreendimento,
    u.empreendimento,
    u.tipo_empreendimento,
    r.regiao,
    silver.conformar_empreendimento(u.empreendimento) AS empreendimento_conformado,
    u.codigo_interno_empreendimento,
    er.regional
FROM silver.unidades u
LEFT JOIN LATERAL (
    SELECT regiao FROM silver.reservas r
    WHERE r.id_empreendimento = u.id_empreendimento AND r.regiao IS NOT NULL
    GROUP BY regiao ORDER BY count(*) DESC LIMIT 1
) r ON true
LEFT JOIN silver.dpara_empreendimento_regional er
       ON er.codigo_interno_empreendimento = u.codigo_interno_empreendimento
WHERE u.id_empreendimento IS NOT NULL
ORDER BY u.id_empreendimento, u.empreendimento;


CREATE OR REPLACE VIEW gold.dim_unidade AS
SELECT id_unidade, id_empreendimento, empreendimento, etapa, bloco, unidade,
       area_privativa, area_comum, andar, tipologia, tipo, vagas_garagem,
       preco, preco_m2, situacao, eh_vendida
FROM silver.unidades;

-- Corretor ATIVO, direto do headcount do backoffice (21/jul/2026) — SEM join com
-- silver.corretores: esse join é o que gerava nome duplicado (mesmo corretor com
-- 2+ cadastros/id_corretor no CVDW casando com a mesma linha do headcount) e campos
-- vazios (LEFT JOIN de corretor fora do headcount) na gold.dim_corretor. Aqui o
-- grão é 1 corretor ATIVO por nome (silver.dpara_corretor_headcount já carrega só
-- Ativos e já é 1 linha por nome).
--
-- RELACIONAR NO POWER BI POR `corretor_chave` (não por `corretor`): a chave é
-- minúscula e sem acento, então absorve a divergência de digitação entre o
-- headcount (manual, backoffice) e o CVDW. `corretor` é só exibição (slicer/ranking).
-- Não há id_corretor no headcount — o nome é a única chave comum.
-- DROP: CREATE OR REPLACE não permite inserir coluna no meio (corretor_chave).
-- Share/House-Parcerias/Regional vêm do ESCRITÓRIO do corretor (DP-13): é assim que
-- leads e pré-cadastros ganham a classificação que a reserva já tem via
-- dpara_gerente_contexto. A junção usa `imobiliaria` (não a coluna `house` do
-- headcount, que tem linhas erradas) — decisão do dev em 21/jul/2026.
DROP VIEW IF EXISTS gold.dim_corretor_headcount CASCADE;
CREATE VIEW gold.dim_corretor_headcount AS
SELECT silver.nome_proprio(h.corretor)   AS corretor,
       silver.chave_nome(h.corretor)     AS corretor_chave,
       h.apelido,
       h.imobiliaria,
       h.house,
       silver.nome_proprio(h.gerente)    AS gerente,      -- normalizado: rótulo de ranking
       silver.nome_proprio(h.supervisor) AS supervisor,   -- (o HC alterna CAIXA ALTA e Title Case)
       ih.share,
       ih.house_parcerias,
       ih.regional
FROM silver.dpara_corretor_headcount h
LEFT JOIN silver.dpara_imobiliaria_house ih
       ON silver.chave_nome(ih.imobiliaria) = silver.chave_nome(h.imobiliaria);

-- Corretor + equipe. FONTE PRIMÁRIA da equipe (21/jul/2026, passo atrás): a planilha
-- manual de headcount do backoffice (Nome -> Gerente/Supervisor), MUITO mais confiável
-- que qualquer derivação via CVDW — "o que vem do CVDW como equipes é falho" (dev).
-- A derivação antiga (gerente da reserva mais recente ⨝ dpara_gerente_contexto, com
-- override DP-09) vira FALLBACK só para corretor que não está no headcount (ex.:
-- corretor de imobiliária Parceria — a planilha só cobre o quadro próprio da Pafil).
DROP VIEW IF EXISTS gold.dim_corretor CASCADE;
CREATE VIEW gold.dim_corretor AS
WITH gerente_reserva AS (
    SELECT DISTINCT ON (id_corretor)
           id_corretor,
           btrim(regexp_replace(gerente_responsavel, '\s+', ' ', 'g')) AS gerente_responsavel
    FROM silver.reservas
    WHERE id_corretor IS NOT NULL
      AND nullif(btrim(gerente_responsavel), '') IS NOT NULL
      AND btrim(gerente_responsavel) <> 'N/D'
    ORDER BY id_corretor, data_cad DESC NULLS LAST
),
-- Última atividade (lead ou reserva) do corretor: base do filtro "corretor atual"
-- no slicer. corretores.ativo é 'S' p/ todos, e ativo_login (acesso ao CV) esconde
-- corretor com atividade recente — a data é o critério honesto.
atividade AS (
    SELECT id_corretor, max(d)::date AS ultima_atividade
    FROM (
        SELECT id_corretor, max(data_cad) AS d FROM silver.reservas
        WHERE id_corretor IS NOT NULL GROUP BY 1
        UNION ALL
        SELECT id_corretor, max(data_cad) FROM silver.leads
        WHERE id_corretor > 0 GROUP BY 1
    ) x GROUP BY 1
)
SELECT c.id_corretor, c.id_imobiliaria, c.nome, c.apelido, c.imobiliaria,
       c.categoria, c.nivel, c.creci, c.email, c.cidade, c.estado,
       c.eh_ativo, c.eh_ativo_login,
       a.ultima_atividade,
       (hc.corretor IS NOT NULL)                                 AS eh_ativo_headcount,
       coalesce(ov.gerente_responsavel, gr.gerente_responsavel)  AS gerente_responsavel,
       -- equipe: headcount (Supervisor) manda; cai p/ derivação via reserva só
       -- quando o corretor não está no headcount (ex.: Parcerias).
       coalesce(hc.supervisor, ctx.gerente_apelido,
                ov.gerente_responsavel, gr.gerente_responsavel)  AS equipe,
       hc.gerente                                                AS gerente_regional,   -- só via headcount (nível acima do supervisor)
       ctx.share,
       ctx.house_parcerias,
       ctx.regional                                               AS regional_equipe
FROM silver.corretores c
LEFT JOIN atividade a ON a.id_corretor = c.id_corretor
LEFT JOIN gerente_reserva gr ON gr.id_corretor = c.id_corretor
LEFT JOIN silver.dpara_corretor_gerente ov
       ON lower(btrim(ov.corretor)) = lower(c.nome)
LEFT JOIN silver.dpara_gerente_contexto ctx
       -- COLLATE ICU: em cluster com locale C o lower() não baixa acentuados
       -- ('TONHÃO' -> 'tonhÃo') e o match case-insensitive falharia.
       ON lower(btrim(ctx.gerente_responsavel) COLLATE "und-x-icu") =
          lower(coalesce(ov.gerente_responsavel, gr.gerente_responsavel) COLLATE "und-x-icu")
LEFT JOIN silver.dpara_corretor_headcount hc
       ON lower(btrim(hc.corretor) COLLATE "und-x-icu") = lower(btrim(c.nome) COLLATE "und-x-icu");


-- Fato de reservas (1 linha/reserva), enriquecida com distrato, House e metas.
-- DROP CASCADE: a fato mudou de colunas (Phase 2) e o CREATE OR REPLACE não dropa
-- colunas; a CASCADE também remove qualquer view legada que ainda dependa da fato
-- (rankings, esteira, funis) e que não é mais recriada aqui.
DROP VIEW IF EXISTS gold.fato_reservas CASCADE;
CREATE OR REPLACE VIEW gold.fato_reservas AS
SELECT
    r.id_reserva,
    r.id_empreendimento,
    r.id_unidade,
    r.id_corretor,
    r.id_imobiliaria,
    r.id_cliente,
    r.id_lead,
    r.data_cad::date                                      AS data_cad,
    r.data_venda::date                                    AS data_venda,
    r.data_aprovacao::date                                AS data_aprovacao,
    r.data_cancelamento::date                             AS data_cancelamento,
    r.empreendimento, r.etapa, r.bloco, r.unidade, r.regiao,
    r.corretor,
    -- chave de relacionamento com gold.dim_corretor_headcount[corretor_chave]
    -- (minúscula/sem acento — absorve divergência de digitação entre CVDW e o
    -- headcount manual do backoffice), igual ao par já usado em fato_leads/
    -- fato_pre_cadastros. Ocultar no modelo; exibir "corretor".
    silver.chave_nome(r.corretor)                         AS corretor_chave,
    r.imobiliaria, r.situacao, r.tipo_venda, r.midia, r.campanha,
    r.valor_contrato,
    r.valor_liquido_com_juros,
    r.valor_proposta,
    r.eh_venda,
    r.eh_venda_ou_distrato,
    r.eh_distrato,
    r.eh_aprovada,
    d.motivo_distrato,
    d.descricao_motivo_distrato,
    d.data_distrato::date                                 AS data_distrato,
    d.valor_distrato,
    (d.id_reserva IS NOT NULL)                            AS tem_distrato,
    r.ano_venda, r.mes_venda, r.ano_mes_venda,
    silver.conformar_empreendimento(r.empreendimento)     AS empreendimento_conformado,
    r.gerente_responsavel,
    r.cf_tipo_venda,
    r.cf_modalidade_financiamento,
    r.cf_motivo_distrato,
    r.cf_classificacao_vendas_internas,
    er.regional                                           AS regional,          -- regional "casa" do empreendimento (RPO/URA/SCA/MTO, fonte limpa).
    -- NB: house_parcerias, Share, Região (3-way) e origem/canal/mídia agora vêm da
    -- classificação oficial (Vendas Consolidadas) via merge no Power BI, por proposta.
    coalesce(se.situacao_tratada, '99. ' || r.situacao)   AS situacao_tratada,
    coalesce(se.ordem, 99)                                AS situacao_ordem,
    u.area_privativa                                      AS m2_unidade,
    r.motivo_cancelamento,
    r.descricao_motivo_cancelamento,
    -- liga de volta ao pré-cadastro que originou a reserva (funil de crédito ->
    -- reserva). Usado por gold.fato_precadastros p/ "situação da reserva".
    r.id_precadastro
FROM silver.reservas r
LEFT JOIN LATERAL (
    -- 1 distrato por reserva (o mais recente)
    SELECT id_reserva, motivo_distrato, descricao_motivo_distrato,
           data_situacao AS data_distrato, valor_contrato AS valor_distrato
    FROM silver.distratos dd
    WHERE dd.id_reserva = r.id_reserva
    ORDER BY dd.data_situacao DESC NULLS LAST
    LIMIT 1
) d ON true
LEFT JOIN silver.dpara_empreendimento_regional er
       ON er.codigo_interno_empreendimento = r.codigo_interno_empreendimento
LEFT JOIN silver.dpara_situacao_esteira se ON se.situacao = r.situacao
LEFT JOIN silver.unidades u ON u.id_unidade = r.id_unidade;


-- ===========================================================================
-- FUNIL LEADS -> PRÉ-CADASTRO -> RESERVA -> VENDA (marketing + comercial).
-- Fatos no grão da entidade. Ligam nas dims existentes (calendário por data_cad,
-- empreendimento, corretor). Agregados/funis ficam por conta do Power BI.
-- ===========================================================================

-- Fato de leads (1 linha/lead). qualificado vem do dpara (situação -> MQL);
-- regional "casa" via código interno do empreendimento.
--
-- CANAL/MÍDIA (replica a cascata do f_leads legado, decifrada do BI Matriz):
--   1. chave origem+mídia  = "Primeira Origem (nome)_Primeira Mídia"  -> dpara_canal_midia
--   2. chave UTM ("D.C")   = utm_source & '__' & utm_medium & form_url & '_'
--                            & última mídia & '!' & última origem (nome) -> dpara_canal_midia_dc
--   3. canal_acdc: entrada <= 31/out/24 -> (1) com fallback (2); depois -> só (2)
--   4. canal_20:   hard-code Campanha de Ativação (5 SDRs -> 'Lead'; senão 'Painel
--      Corretor'), senão canal_acdc.  midia_20 análogo (sem o hard-code).
--   5. ativo_receptivo: canal_20 -> dpara_ativo_receptivo.
-- Ambos os de-paras são mantidos pelo analista na aba Apoio do Base de Leads.xlsm
-- (popular_seeds.py --leads-apoio recarrega). A aba tem variação de GRAFIA para a
-- mesma chave (ex.: "Site"/"SIte", "WhatsApp/Blip"/"Whatsapp/BLIP", "Facebook"/
-- "facebook") — o join por chave já é case-insensitive (lower(btrim(...))), mas o
-- VALOR retornado preservava a grafia da linha que bateu, então canal_20/midia_acdc
-- saíam com 2 rótulos pro mesmo conceito. Isso é o que fazia a tentativa de
-- dim_origem no Power Query dar "valores duplicados" ao relacionar — Table.Distinct
-- (M) diferencia maiúscula/minúscula, o motor do relacionamento não (03/ago/2026).
-- NORMALIZADO abaixo: escolhe 1 grafia canônica por chave (a mais frequente nos
-- próprios leads; empate -> ordem alfabética), sem depender de editar a planilha.
DROP VIEW IF EXISTS gold.fato_leads CASCADE;
CREATE VIEW gold.fato_leads AS
WITH base AS (
    SELECT
        l.*,
        -- "Data usar" do legado: data da última entrada do lead (vazio -> pós-corte)
        coalesce(l.ultima_data_conversao, l.data_cad)::date AS data_usar,
        coalesce(l.origem_nome, '') || '_' || coalesce(l.midia_original, '')  AS chave_om,
        coalesce(l.utm_source, '') || '__' || coalesce(l.utm_medium, '')
            || coalesce(l.form_url, '') || '_' || coalesce(l.midia_ultimo, '')
            || '!' || coalesce(l.origem_ultimo_nome, '')                      AS chave_dc
    FROM silver.leads l
),
mesclado_raw AS (
    SELECT
        b.*,
        om.canal  AS canal_om_raw,
        om.midia  AS midia_om_raw,
        dc.canal  AS canal_dc_raw,
        dc.midia  AS midia_dc_raw,
        dc.trafego
    FROM base b
    LEFT JOIN silver.dpara_canal_midia    om ON lower(btrim(om.concat)) = lower(btrim(b.chave_om))
    LEFT JOIN silver.dpara_canal_midia_dc dc ON lower(btrim(dc.concat)) = lower(btrim(b.chave_dc))
),
grafia_canonica AS (
    -- 1 grafia por chave case-insensitive (canal OU mídia, das 2 fontes om/dc
    -- juntas) = a que mais aparece nos leads; empate -> ordem alfabética (só p/
    -- ser determinístico).
    SELECT DISTINCT ON (chave) chave, grafia
    FROM (
        SELECT lower(btrim(valor)) AS chave, valor AS grafia, count(*) AS n
        FROM (
            SELECT canal_om_raw AS valor FROM mesclado_raw WHERE nullif(btrim(canal_om_raw), '') IS NOT NULL
            UNION ALL
            SELECT midia_om_raw FROM mesclado_raw WHERE nullif(btrim(midia_om_raw), '') IS NOT NULL
            UNION ALL
            SELECT canal_dc_raw FROM mesclado_raw WHERE nullif(btrim(canal_dc_raw), '') IS NOT NULL
            UNION ALL
            SELECT midia_dc_raw FROM mesclado_raw WHERE nullif(btrim(midia_dc_raw), '') IS NOT NULL
        ) v
        GROUP BY 1, 2
    ) freq
    ORDER BY chave, n DESC, grafia
),
mesclado AS (
    SELECT
        r.*,
        c1.grafia AS canal_om,
        c2.grafia AS midia_om,
        c3.grafia AS canal_dc,
        c4.grafia AS midia_dc,
        CASE WHEN r.data_usar <= DATE '2024-10-31'
             THEN coalesce(nullif(c1.grafia, ''), c3.grafia)
             ELSE c3.grafia
        END AS canal_acdc,
        CASE WHEN r.data_usar <= DATE '2024-10-31'
             THEN coalesce(nullif(c2.grafia, ''), c4.grafia)
             ELSE c4.grafia
        END AS midia_acdc
    FROM mesclado_raw r
    LEFT JOIN grafia_canonica c1 ON c1.chave = lower(btrim(r.canal_om_raw))
    LEFT JOIN grafia_canonica c2 ON c2.chave = lower(btrim(r.midia_om_raw))
    LEFT JOIN grafia_canonica c3 ON c3.chave = lower(btrim(r.canal_dc_raw))
    LEFT JOIN grafia_canonica c4 ON c4.chave = lower(btrim(r.midia_dc_raw))
),
classificado AS (
    SELECT
        m.*,
        CASE WHEN m.midia_acdc = 'Campanha de Ativação' THEN
            -- hard-code herdado do legado (R16): ativação disparada pelos SDRs conta
            -- como Lead; disparada por corretor conta como Painel Corretor.
            CASE WHEN m.gestor IN ('Giovana Rodrigues Gonçalves de Queiroz',
                                   'Luiz Henrique Silva',
                                   'Allison Lunardelo',
                                   'José Roberto Trigueiro Junior',
                                   'Alexia Gabriellen Magalhães De Oliveira')
                 THEN 'Lead' ELSE 'Painel Corretor' END
        ELSE m.canal_acdc END AS canal_20,
        -- ordem do funil de lead ("Situação Leads Tratada" do legado, hard-code 1:1)
        CASE m.situacao
            WHEN 'Aguardando Atendimento SDR'      THEN '00. Aguardando Atendimento SDR'
            WHEN 'Aguardando Resposta Cliente SDR' THEN '01. Aguardando Resposta Cliente SDR'
            WHEN 'Atendimento SDR'                 THEN '02. Atendimento SDR'
            WHEN 'Interesse SDR'                   THEN '03. Interesse SDR'
            WHEN 'Aguardando Atendimento'          THEN '04. Aguardando Atendimento'
            WHEN 'Em Contato'                      THEN '05. Em Contato'
            WHEN 'Em Negociação'                   THEN '06. Em Negociação'
            WHEN 'Em Análise de Crédito'           THEN '07. Em Análise de Crédito'
            WHEN 'Com Reserva'                     THEN '08. Com Reserva'
            WHEN 'Venda Realizada'                 THEN '09. Venda Realizada'
            WHEN 'Perdido'                         THEN '10. Descartado'
            ELSE m.situacao
        END AS situacao_tratada
    FROM mesclado m
)
-- Nomes de coluna = f_leads do BI Matriz (decisão 16/jul: a view é o ponto único
-- de verdade dos nomes de apresentação; o Power BI consome como está, sem rename
-- no Power Query). Ficam em snake_case: chaves id_*, datas (sustentam
-- relacionamentos no PBI), ativo_receptivo_20 (o Power Query do .pbix a remove
-- pelo nome — "atv/recept 2" é coluna calculada DAX lá) e campos da modelagem
-- nova sem equivalente legado (empreendimento_conformado, regional, flags eh_*).
SELECT
    l.id_lead,
    l.id_empreendimento,
    l.id_corretor,
    l.id_imobiliaria,
    l.id_gestor,
    l.data_cad::date                                      AS data_cad,
    -- "Data da Última Entrada"/"Data da Última Interação": nomes e valores iguais
    -- ao CSV legado da f_leads (relatorios_interessados.csv) — confirmado campo a
    -- campo (20 leads, 08/jul/2026) contra ultima_data_conversao/data_ultima_interacao
    -- do CVDW; batem ao segundo, inclusive quando divergem entre si (lead 62479).
    -- Antes existia aqui uma "data_conversao" com nome técnico — removida a favor
    -- do nome do CSV, que o gestor já reconhece. ATENÇÃO: o relacionamento ativo
    -- da fato_leads com dim_calendario no Power BI apontava para "data_conversao"
    -- — precisa ser refeito para "Data da Última Entrada" (TOM Rename + Update
    -- sourceColumn, depois Atualizar no Desktop; ver pegadinhas TOM×Desktop).
    l.ultima_data_conversao::date                         AS "Data da Última Entrada",
    l.data_ultima_interacao::date                         AS "Data da Última Interação",
    l.data_cancelamento::date                             AS data_cancelamento,
    l.situacao                                            AS "Situação",
    l.situacao_anterior                                   AS "Situação Anterior",
    l.situacao_tratada                                    AS "Situação Leads Tratada",
    -- "Situação Leads Tratada 2.0": descartado repartido por quem segurava o lead
    CASE WHEN l.situacao_tratada = '10. Descartado' THEN
        CASE WHEN l.situacao_anterior IN ('Aguardando Atendimento SDR',
                                          'Aguardando Resposta Cliente SDR',
                                          'Atendimento SDR', 'Interesse SDR')
             THEN '10. Descartado SDR' ELSE '10. Descartado Corretor' END
    ELSE l.situacao_tratada END                           AS "Situação Leads Tratada 2.0",
    ql.qualificado                                        AS "MQL",
    -- "MQL 2" do legado: perdido que já tinha avançado na esteira conta como MQL
    CASE WHEN l.canal_20 = 'Lead' AND l.situacao = 'Perdido'
              AND l.situacao_anterior IN ('Em Contato', 'Aguardando Atendimento',
                                          'Aguardando Atendimento Corretor',
                                          'Em Análise de Crédito', 'Em Negociação',
                                          'Com Reserva', 'Venda Realizada',
                                          'Em Atendimento', 'Visita Agendada',
                                          'Visita Realizada')
         THEN 'SIM' ELSE ql.qualificado END               AS "MQL 2",
    l.origem,
    l.origem_ultimo,
    l.origem_nome                                         AS "Primeira Origem",
    l.origem_ultimo_nome                                  AS "Última Origem",
    l.midia_original                                      AS "Primeira Mídia de Visita",
    l.midia_ultimo                                        AS "Última Mídia de Visita",
    -- canal/mídia conformados (cascata legada, nomes 1:1 com o f_leads) -------
    l.canal_om                                            AS "canal",
    l.midia_om                                            AS "midia",
    l.canal_dc                                            AS "canal 2",
    l.midia_dc                                            AS "midia 2",
    l.trafego                                             AS "Tráfego",
    l.canal_20                                            AS "canal 2.0",
    l.midia_acdc                                          AS "midia acdc",
    -- chave de relacionamento com gold.dim_origem[origem_chave] (mesmo padrão de
    -- corretor_chave): grafia já canonizada acima, nunca nula (par vazio vira o
    -- sentinela "(Não informado)_(Não informado)", que dim_origem também expõe —
    -- assim o slicer de origem não derruba silenciosamente as ~0,2% de linhas sem
    -- canal/mídia). Ocultar no modelo; exibir via dim_origem.
    coalesce(nullif(btrim(l.canal_20), ''), '(Não informado)')
        || '_' || coalesce(nullif(btrim(l.midia_acdc), ''), '(Não informado)') AS origem_chave,
    ar.lead_ou_prospect                                   AS "atv/recept",
    -- "atv/recept 2" do legado: Campanha de Ativação é sempre trabalho Ativo
    CASE WHEN l.midia_acdc = 'Campanha de Ativação' THEN 'Ativo'
         ELSE ar.lead_ou_prospect END                     AS ativo_receptivo_20,
    l.chave_om                                            AS "canal/midia",       -- auditoria
    l.chave_dc                                            AS "canal/midia D.C",   -- de-para (sem match -> Excel)
    l.ponto_venda                                         AS "Ponto de Venda",
    l.gestor                                              AS "Gestor",
    l.corretor                                            AS "Corretor",
    -- nome tratado p/ slicer, padrão pt-BR (conectivo minúsculo): antes era um
    -- initcap solto, que devolvia "De Paula E Silva" e não casava com o headcount.
    silver.nome_proprio(l.corretor)                       AS "Corretor Trat",
    -- chave de relacionamento com gold.dim_corretor_headcount[corretor_chave]
    -- (minúscula/sem acento — absorve divergência de digitação entre CVDW e o
    -- headcount manual do backoffice). Ocultar no modelo; exibir "Corretor Trat".
    silver.chave_nome(l.corretor)                         AS corretor_chave,
    -- "corretor" some quando o lead é Perdido (99,9% vazio); "corretor_ultimo"
    -- guarda quem atendeu por último e continua preenchido (~65% dos perdidos).
    l.corretor_ultimo                                     AS "Último Corretor",
    silver.nome_proprio(l.corretor_ultimo)                AS "Último Corretor Trat",
    silver.chave_nome(l.corretor_ultimo)                  AS corretor_ultimo_chave,
    l.imobiliaria                                         AS "Imobiliária",
    coalesce(nullif(btrim(l.empreendimento_ultimo), ''), l.empreendimento) AS "Empreendimento",
    silver.conformar_empreendimento(
        coalesce(nullif(btrim(l.empreendimento_ultimo), ''), l.empreendimento)
    )                                                     AS empreendimento_conformado,
    er.regional,
    l.cidade                                              AS "Cidade",
    l.estado                                              AS "Estado",
    l.regiao,
    l.score                                               AS "Score",
    l.possibilidade_venda                                 AS "Possibilidade de venda",
    l.momento_lead                                        AS "Momento do Lead",
    l.motivo_cancelamento                                 AS "Motivo de Cancelamento",
    l.eh_ativo,
    l.eh_vencido,
    l.eh_novo,
    l.eh_convertido,
    l.eh_convertido_reserva,
    l.qtd_reservas                                        AS "Reserva",
    l.ano_cad,
    l.mes_cad,
    l.ano_mes_cad
FROM classificado l
LEFT JOIN silver.dpara_qualificacao_lead ql
       ON btrim(ql.situacao) = l.situacao
LEFT JOIN silver.dpara_ativo_receptivo ar
       ON ar.canal = l.canal_20
LEFT JOIN silver.dpara_empreendimento_regional er
       ON er.codigo_interno_empreendimento = l.codigo_interno_empreendimento;


-- Dimensão de origem (canal 2.0 + mídia acdc), conformada = 1 linha por par único
-- já com a grafia canonizada acima. Fonte única dos filtros de canal/mídia nos
-- dashboards de Leads/Pré-Cadastro — substitui a dim_origem que existia só no
-- Power Query (Table.Distinct sobre fato_leads), que dava "valores duplicados" ao
-- relacionar porque Table.Distinct (M) diferencia maiúscula/minúscula e o motor
-- de relacionamento do Power BI não (03/ago/2026).
-- NÃO cobre gold.fato_reservas: lá "Canal"/"Mídia" vêm da classificação MANUAL da
-- Vendas Consolidadas via merge no Power Query (ver comentário no início de
-- gold.fato_reservas) — outra governança, outro domínio de valores (ex.: "Carteira
-- Corretor"/"Parcerias"/"Venda Interna" não existem no canal 2.0 de leads);
-- unificar exige decisão de negócio (de-para classificação manual -> canal 2.0),
-- não é só join por chave.
DROP VIEW IF EXISTS gold.dim_origem CASCADE;
CREATE VIEW gold.dim_origem AS
SELECT DISTINCT
    origem_chave,
    "canal 2.0",
    "midia acdc"
FROM gold.fato_leads;


-- Fato de pré-cadastros (1 linha/pré-cadastro) — funil de crédito. Página "Pré
-- Cadastro" do BI Matriz legado (REGRAS_NEGOCIO.md DP-05/KPI-25..27/37).
--
-- ETAPA BI / BI DETALHADA (DP-05): a "Situação" crua do CVCRM não é o funil de
-- crédito que o negócio enxerga — dpara_etapa_precadastro (aba Apoio do Base -
-- Crédito.xlsm, popular_seeds --etapa-precadastro) traduz p/ etapa_bi (Montagem
-- de Pasta/Análise Documental/Análise de Crédito/Crédito Aprovado/Com Reserva/
-- Ajustes/Cancelada/Vencida) e etapa_bi_detalhada (a mesma, numerada "0."→"6.").
-- "Qtd Pastas" do legado = tudo MENOS etapa_bi_detalhada IN
-- {"0. Montagem de Pasta","5. Cancelada"} — replicar na medida DAX, não aqui.
--
-- SITUAÇÃO DA RESERVA: liga de volta em gold.fato_reservas por id_precadastro
-- (a reserva "sabe" de qual pré-cadastro nasceu; o contrário não existe no CVDW).
-- Só pega 1 reserva por pré-cadastro (a mais recente) — cobre o caso raro de
-- mais de uma reserva ligada ao mesmo pré-cadastro.
--
-- EQUIPE / HOUSE-PARCERIAS / REGIONAL do corretor: NÃO ficam aqui — vêm de
-- gold.dim_corretor (relação id_corretor, mesmo padrão de fato_leads desde
-- 21/jul/2026). O de-para "equipe_corretor" do legado (Corretor -> Categoria)
-- foi supersedido por essa fonte (ver config/deparas.yml).
--
-- APROVAÇÃO DE CRÉDITO / ENCAMINHADO AO CCA: colunas nativas só do export
-- manual (silver.precadastros_credito_manual, popular_seeds --credito-manual)
-- — NÃO existem na API CVDW. Cobrem só ~9% dos pré-cadastros (os tocados
-- recentemente pelo time de crédito); NULL é esperado pro resto, não é falha
-- de match. Alimentam os donuts "Aprovação de Crédito"/"Encaminhado ao CCA".
--
-- RENDA: renda_cliente_principal (só o titular, NULL quando não preenchida) e
-- renda_total (titular + compositores; o CVDW manda 0 em vez de NULL quando vazia
-- — ~36% dos casos). Média/mediana em DAX precisam excluir o 0, senão puxam pra
-- baixo. Há digitação livre sem validação no CVCRM: 55 registros acima de R$ 1 mi
-- (vários no teto 99.999.999,99) — usar mediana, não média, em visual agregado.
--
-- CANAL/MÍDIA: o CVDW não retorna canal/mídia de pré-cadastro (só de lead). Como
-- todo pré-cadastro nasce de um lead (id_lead), busca-se origem_chave em
-- gold.fato_leads por esse ID (~96,5% casa; o resto é pré-cadastro sem id_lead ou
-- sem lead correspondente — cai no mesmo sentinela '(Não informado)_(Não
-- informado)' usado em fato_leads pra canal/mídia vazio, então sempre casa com
-- gold.dim_origem). Feito aqui em SQL (não no Power Query) para não repetir a
-- lógica de origem por fato — a gold.dim_origem é a única fonte do filtro nos
-- dois dashboards.
DROP VIEW IF EXISTS gold.fato_precadastros CASCADE;
CREATE VIEW gold.fato_precadastros AS
SELECT
    p.id_precadastro,
    p.id_lead,
    p.id_empreendimento,
    p.id_corretor,
    p.id_imobiliaria,
    p.data_cad::date                                      AS data_cad,
    p.situacao,
    p.situacao_anterior,
    ep.etapa_bi,
    ep.etapa_bi_detalhada,
    cm.aprovacao_credito,
    cm.encaminhado_cca,
    p.condicao_aprovada,
    p.empreendimento,
    silver.conformar_empreendimento(p.empreendimento)     AS empreendimento_conformado,
    p.corretor,
    -- par exibição/chave igual ao da fato_leads ("Corretor Trat"/corretor_chave lá;
    -- snake_case aqui porque o pré-cadastro é modelagem nova, sem nome legado a honrar).
    silver.nome_proprio(p.corretor)                       AS corretor_tratado,
    silver.chave_nome(p.corretor)                         AS corretor_chave,
    p.imobiliaria,
    p.intencao_compra,
    p.tabela_credito,
    p.valor_avaliacao,
    p.valor_aprovado,
    p.valor_subsidio,
    p.valor_fgts,
    p.valor_total,
    p.saldo_devedor,
    p.renda_cliente_principal,
    p.renda_total,
    p.eh_aprovado,
    p.eh_reprovado,
    p.eh_cancelado,
    p.motivo_reprovacao,
    p.motivo_cancelamento,
    p.ano_cad,
    p.mes_cad,
    p.ano_mes_cad,
    -- chave de relacionamento com gold.dim_origem[origem_chave] (ver comentário
    -- acima); coalesce cobre o pré-cadastro sem id_lead ou sem match em fato_leads.
    coalesce(l.origem_chave, '(Não informado)_(Não informado)') AS origem_chave,
    resv.id_reserva,
    resv.situacao_tratada                                 AS situacao_reserva,
    resv.situacao_ordem                                    AS situacao_reserva_ordem,
    resv.eh_venda                                          AS eh_venda_reserva,
    resv.eh_distrato                                        AS eh_distrato_reserva
FROM silver.precadastros p
LEFT JOIN silver.dpara_etapa_precadastro ep
       ON ep.etapa_wkf = p.situacao
LEFT JOIN silver.precadastros_credito_manual cm
       ON cm.id_precadastro = p.id_precadastro
LEFT JOIN gold.fato_leads l
       ON l.id_lead = p.id_lead
LEFT JOIN LATERAL (
    SELECT fr.id_reserva, fr.situacao_tratada, fr.situacao_ordem, fr.eh_venda, fr.eh_distrato
    FROM gold.fato_reservas fr
    WHERE fr.id_precadastro = p.id_precadastro
    ORDER BY fr.data_cad DESC NULLS LAST
    LIMIT 1
) resv ON true;


-- ===========================================================================
-- PREÇO / ESTOQUE / METAS / VIABILIDADE (task 6.4 do roadmap) — tabelas que NÃO
-- vêm da API CVDW: planejamento/input manual da gestão (risco R5 do
-- REGRAS_NEGOCIO.md). Fonte: silver.d_estrutura / d_metas_empreendimentos /
-- d_viabilidade (seeds carregadas por popular_seeds.py a partir de base_precos.xlsm,
-- Meta.xlsx e d_para empreendimentos.xlsx). Alimentam os insights do BI de Preço
-- (estoque/VSO/margem) e Empreendimento x Meta — ver powerbi/MEDIDAS_ESTOQUE_PRECO.dax.
-- ===========================================================================

-- Matriz de preço/estoque por unidade + status calculado contra a fato de reservas.
-- ⚠️ Chave de join p/ status: a API CVDW não expõe o mesmo "Código interno da
-- unidade" que o CSV legado tinha (só codigo_interno_empreendimento a nível de
-- empreendimento) — o match usa (codigo_cv, bloco, unidade) normalizado.
-- Achado na validação (task 6.4): em produto de torre única, silver.reservas.bloco
-- vem preenchido com o PRÓPRIO NOME DO EMPREENDIMENTO (ex.: "PARC DAS ARTES
-- RESIDENCIAL"), enquanto d_estrutura.bloco fica NULL pro mesmo caso — sem
-- normalizar isso, o match zerava pra todo produto sem torre (confirmado: Parc
-- das Artes dava 0 "Realizado" antes deste ajuste). Por isso o bloco só entra na
-- chave quando é um valor de torre "de verdade" (≠ nome do empreendimento);
-- comparação NULL-safe (IS NOT DISTINCT FROM) pra não perder produto sem bloco.
-- Chaves via silver.chave_bloco/chave_unidade (funções compartilhadas, mesma
-- normalização usada em gold.dim_distratos_2025 — task 6.4/distratos 2025,
-- ago/2026): trata bloco=nome-do-empreendimento como NULL nos dois lados E
-- remove zero à esquerda do número da unidade ("027"->"27", "QUADRA 06"->
-- "QUADRA 6"), pra casar com a grafia de d_estrutura sem depender de código
-- de unidade (a API CVDW não expõe o mesmo "Código interno da unidade" do
-- CSV legado — ver R17 do REGRAS_NEGOCIO.md).
DROP VIEW IF EXISTS gold.dim_estrutura CASCADE;
CREATE VIEW gold.dim_estrutura AS
WITH vendidas AS (
    SELECT DISTINCT
           r.codigo_interno_empreendimento,
           silver.chave_bloco(r.bloco, r.empreendimento) AS bloco_norm,
           silver.chave_unidade(r.unidade) AS unidade_norm
    FROM silver.reservas r
    WHERE r.eh_venda_ou_distrato
)
SELECT
    e.codigo_interno,
    e.codigo_cv,
    e.produto,
    silver.conformar_empreendimento(e.produto) AS empreendimento_conformado,
    e.bloco,
    e.unidade,
    e.area_privativa,
    e.config_1, e.config_2, e.config_3,
    e.permuta,
    e.preco,
    e.preco_m2,
    CASE
        WHEN e.permuta THEN 'Permuta'
        WHEN v.codigo_interno_empreendimento IS NOT NULL THEN 'Realizado'
        ELSE 'Estoque'
    END AS status_unidade
FROM silver.d_estrutura e
LEFT JOIN vendidas v
       ON v.codigo_interno_empreendimento = e.codigo_cv
      AND v.bloco_norm IS NOT DISTINCT FROM silver.chave_bloco(e.bloco, e.produto)
      AND v.unidade_norm = silver.chave_unidade(e.unidade);


-- Metas/forecast mensais por empreendimento (Meta.xlsx). Grão = codigo_cv x mês x
-- status_meta (Start/Replan) — mesmo grão do legado (KPI-31..33).
DROP VIEW IF EXISTS gold.dim_metas_empreendimentos CASCADE;
CREATE VIEW gold.dim_metas_empreendimentos AS
SELECT
    m.codigo_cv,
    de.id_empreendimento,
    coalesce(de.empreendimento_conformado, m.empreendimento) AS empreendimento,
    m.data,
    m.status_meta,
    m.mes,
    coalesce(m.regional, de.regional)                        AS regional,
    m.status_empreendimento,
    m.meta_qtd, m.meta_vgv,
    m.forecast_qtd, m.forecast_vgv,
    m.meta_house, m.meta_imobiliaria, m.meta_gv_house, m.meta_gv_imob,
    m.meta_digital_rpo, m.meta_digital_regional, m.meta_digital,
    m.qtd_apresentacao, m.vgv_apresentacao
FROM silver.d_metas_empreendimentos m
LEFT JOIN gold.dim_empreendimento de
       ON de.codigo_interno_empreendimento = m.codigo_cv;


-- Parâmetros de margem por empreendimento — pivot do EAV silver.d_viabilidade.
-- Resolve R4: no legado eram ~12 conjuntos de constantes coladas no DAX (uma
-- "Margem"/"MargemViab" por empreendimento); aqui viram 1 linha parametrizável,
-- consumida por 1 única medida DAX (ver powerbi/MEDIDAS_ESTOQUE_PRECO.dax).
DROP VIEW IF EXISTS gold.dim_viabilidade CASCADE;
CREATE VIEW gold.dim_viabilidade AS
SELECT
    codigo_cv,
    max(valor)      FILTER (WHERE tipo = 'Receita Bruta')                    AS receita_bruta,
    max(valor)      FILTER (WHERE tipo = 'Deduções')                         AS deducoes_valor,
    max(percentual) FILTER (WHERE tipo = 'Deduções')                         AS deducoes_pct,
    max(valor)      FILTER (WHERE tipo = 'Receita Liquida')                  AS receita_liquida,
    max(valor)      FILTER (WHERE tipo = 'Custos e Despesas')                AS custos_despesas,
    max(valor)      FILTER (WHERE tipo = 'Terreno')                         AS terreno_valor,
    max(percentual) FILTER (WHERE tipo = 'Terreno')                         AS terreno_pct,
    max(valor)      FILTER (WHERE tipo = 'Construção')                       AS construcao_valor,
    max(percentual) FILTER (WHERE tipo = 'Construção')                       AS construcao_pct,
    max(valor)      FILTER (WHERE tipo = 'Despesas')                         AS despesas_valor,
    max(percentual) FILTER (WHERE tipo = 'Despesas')                         AS despesas_pct
FROM silver.d_viabilidade
GROUP BY codigo_cv;


-- Curva PADRÃO de IVV (índice de velocidade de vendas) por empreendimento x mês
-- desde o lançamento — visual "IVV x Empreendimento" do BI legado (mesmo arquivo
-- de dim_viabilidade, abas IVV_padrão + d_para empreendimentos). Não vem da API
-- CVDW: input de planejamento da gestão.
--
-- meses_desde_lancamento/eh_mes_atual substituem a coluna calculada DAX do legado
-- (`DATEDIFF(RELATED(...), TODAY(), MONTH)` + comparação) — aqui é 1 view viva
-- (recalcula a cada consulta), então não precisa de relacionamento nem de coluna
-- calculada no Power BI: a medida só filtra `eh_mes_atual = TRUE` pra pegar o
-- ponto da curva referente a hoje (equivalente à MEDIDA m_ivv_padrao do legado).
DROP VIEW IF EXISTS gold.dim_ivv_padrao CASCADE;
CREATE VIEW gold.dim_ivv_padrao AS
SELECT
    v.codigo_cv,
    v.empreendimento,
    silver.conformar_empreendimento(v.empreendimento) AS empreendimento_conformado,
    v.regional,
    v.assinatura,
    v.mes,
    v.pct_ivv,
    el.data_lancamento,
    el.tipo_produto,
    ( extract(year  FROM age(current_date, el.data_lancamento)) * 12
    + extract(month FROM age(current_date, el.data_lancamento)) )::int AS meses_desde_lancamento,
    v.mes = ( extract(year  FROM age(current_date, el.data_lancamento)) * 12
            + extract(month FROM age(current_date, el.data_lancamento)) )::int AS eh_mes_atual
FROM silver.d_ivv v
LEFT JOIN silver.d_empreendimento_legado el ON el.codigo_cv = v.codigo_cv;


-- distratos 2025 — detalhe financeiro (multa/pago/devolução/parcelas) que não vem
-- da API CVDW; complementa gold.fato_reservas (que já cobre motivo/data/valor via
-- cvdw.distratos, fonte viva — ver R2 do REGRAS_NEGOCIO.md). Share/House-Parcerias/
-- Regional reaproveitados de silver.dpara_gerente_contexto (DP-01) em vez de
-- reimplementar a lista de nomes hardcoded que o DAX legado tinha por classificação.
--
-- ✅ RELACIONADA a gold.fato_reservas (ago/2026, resolve o "ainda não relacionada"
-- anterior): "Contrato" é ID do MEGA (financeiro), não bate com nada do CVCRM — o
-- match usa (empreendimento conformado, chave_bloco, chave_unidade) contra
-- silver.distratos ⨝ silver.reservas (mesmas funções de silver.chave_bloco/
-- chave_unidade usadas em gold.dim_estrutura), desempatando pela reserva com
-- data_situacao mais próxima de "Data do Distrato" quando bloco+unidade batem em
-- mais de uma. Validado manualmente (860 linhas): 742 casaram (86%); as ~118 sem
-- match são ~36 de empreendimentos que não existem no CVCRM (produtos antigos) e
-- o resto variação de grafia de bloco/unidade não coberta pela normalização atual.
-- motivo_1_resolvido/gerente_responsavel_resolvido preenchem a lacuna quando a
-- planilha vem sem essas colunas (chegam de silver.reservas/silver.distratos, não
-- exigem mais o preenchimento manual que foi feito uma vez via Excel).
-- ⚠️ Qualidade: 455/860 linhas com gerente_responsavel preenchido não casam em
-- silver.dpara_gerente_contexto (43 linhas, só gestores atuais) — a planilha é
-- histórico 2023-2025, com nomes de gerentes que já saíram. share/house_parcerias/
-- regional ficam NULL nesses casos (esperado, não é falha de match).
DROP VIEW IF EXISTS gold.dim_distratos_2025 CASCADE;
CREATE VIEW gold.dim_distratos_2025 AS
WITH d25 AS (
    SELECT
        d._id_tecnico, d.contrato,
        silver.conformar_empreendimento(d.produto) AS emp_conf,
        silver.chave_bloco(d.bloco, d.produto)      AS bloco_chave,
        silver.chave_unidade(d.unidade)             AS unidade_chave,
        d.data_distrato
    FROM silver.distratos_2025 d
),
dist AS (
    SELECT
        ds.id_reserva, ds.motivo_distrato, ds.data_situacao::date AS data_distrato_db,
        r.gerente_responsavel,
        silver.conformar_empreendimento(r.empreendimento) AS emp_conf,
        silver.chave_bloco(r.bloco, r.empreendimento)      AS bloco_chave,
        silver.chave_unidade(r.unidade)                    AS unidade_chave
    FROM silver.distratos ds
    JOIN silver.reservas r ON r.id_reserva = ds.id_reserva
),
match AS (
    SELECT DISTINCT ON (d25._id_tecnico)
        d25._id_tecnico,
        dist.id_reserva,
        dist.motivo_distrato       AS motivo_distrato_reserva,
        dist.gerente_responsavel   AS gerente_responsavel_reserva,
        abs(dist.data_distrato_db - d25.data_distrato) AS dif_dias_match
    FROM d25
    JOIN dist
      ON dist.emp_conf = d25.emp_conf
     AND dist.bloco_chave IS NOT DISTINCT FROM d25.bloco_chave
     AND d25.unidade_chave IS NOT NULL
     AND (dist.unidade_chave = d25.unidade_chave
          OR d25.unidade_chave = ANY(string_to_array(dist.unidade_chave, ' ')))
    ORDER BY d25._id_tecnico, abs(dist.data_distrato_db - d25.data_distrato) NULLS LAST
)
SELECT
    d.contrato,
    d.produto,
    silver.conformar_empreendimento(d.produto) AS empreendimento_conformado,
    d.bloco, d.unidade, d.cliente,
    d.data_contrato, d.data_distrato,
    (d.data_distrato - d.data_contrato) AS dias_ate_distrato,
    CASE
        WHEN d.data_distrato IS NULL OR d.data_contrato IS NULL   THEN NULL
        WHEN d.data_distrato - d.data_contrato <= 7                THEN '01 - até 7 dias'
        WHEN d.data_distrato - d.data_contrato <= 30                THEN '02 - 7 a 30 dias'
        WHEN d.data_distrato - d.data_contrato <= 90                THEN '03 - 30 a 90 dias'
        WHEN d.data_distrato - d.data_contrato <= 180               THEN '04 - 90 a 180 dias'
        WHEN d.data_distrato - d.data_contrato <= 365               THEN '05 - 180 a 360 dias'
        ELSE '06 - acima de 360 dias'
    END AS range_dias_ate_distrato,
    d.valor_venda, d.valor_contrato, d.area_privativa,
    d.valor_pago, d.valor_pago_atualizado, d.valor_multa,
    d.fruicao, d.valor_devolucao, d.forma_devolucao, d.numero_parcelas,
    d.status_contrato, d.tipo_contrato, d.trans_fil, d.motivo_1, d.motivo_2,
    d.gerente_responsavel,
    ctx.share, ctx.house_parcerias, ctx.regional,
    m.id_reserva,
    m.dif_dias_match,
    coalesce(d.motivo_1, m.motivo_distrato_reserva)             AS motivo_1_resolvido,
    coalesce(d.gerente_responsavel, m.gerente_responsavel_reserva) AS gerente_responsavel_resolvido
FROM silver.distratos_2025 d
LEFT JOIN silver.dpara_gerente_contexto ctx
       ON lower(btrim(ctx.gerente_responsavel) COLLATE "und-x-icu") =
          lower(btrim(d.gerente_responsavel) COLLATE "und-x-icu")
LEFT JOIN match m ON m._id_tecnico = d._id_tecnico;
