-- Camada SILVER do Blip (atendimento humano). Aplicar com aplicar_silver.py.
--
-- Arquivo próprio, e não um bloco no silver.sql, pelo mesmo motivo do
-- sql/bronze/blip.sql: o Blip é outra fonte, com outro vocabulário e outro
-- ciclo de vida. Misturar as duas num arquivo só faria toda mudança no Blip
-- aparecer como diff no meio do CVDW.
--
-- A bronze do Blip já vem tipada (o DDL é escrito à mão), então aqui não há
-- cast tolerante. O trabalho desta camada é outro: traduzir o vocabulário do
-- Blip para o do negócio, calcular as durações que o painel mostra, e separar
-- a tag, que o Blip guarda como lista única misturando empreendimento e motivo.

CREATE SCHEMA IF NOT EXISTS silver;

-- Aviso para quem for MUDAR a forma destas views, e não só o conteúdo delas:
-- o `CREATE OR REPLACE VIEW` do Postgres só acrescenta coluna no fim. Renomear,
-- reordenar ou remover coluna faz o comando falhar, e como o arquivo inteiro é
-- aplicado numa transação só, a view continua no banco com a definição antiga
-- enquanto o repositório já mostra a nova. O sintoma aparece longe daqui, em
-- forma de "coluna não pode ser encontrada" no Power BI.
--
-- O gold/blip.sql resolve isso com DROP antes do CREATE, mas aqui não dá para
-- fazer o mesmo sem cuidado: gold.fato_atendimentos depende de
-- silver.blip_tickets, então um DROP sem CASCADE falha e um DROP com CASCADE
-- derruba a gold junto. Se precisar mudar a forma de uma view desta camada,
-- rode `aplicar_tudo.py`, que reconstrói silver e gold na ordem certa.

-- ===== Filas de atendimento =====
CREATE OR REPLACE VIEW silver.blip_filas AS
SELECT
    btrim(t.name)   AS fila,
    -- Agentes online no instante da coleta. Não é histórico: para série
    -- temporal, a fonte é bronze.blip_teams_snapshot.
    t.agents_online,
    t._data_extracao
FROM bronze.blip_teams t
WHERE t.name IS NOT NULL;

-- ===== Atendentes =====
CREATE OR REPLACE VIEW silver.blip_atendentes AS
SELECT
    a.identity                              AS atendente_identity,
    lower(btrim(a.email))                   AS atendente_email,
    -- O fullName às vezes é o próprio e-mail, quando o atendente foi
    -- cadastrado sem nome. Exibir o e-mail inteiro numa coluna chamada "nome"
    -- polui a tabela do dashboard, então fica o trecho antes do @.
    CASE
        WHEN a.full_name IS NULL OR btrim(a.full_name) = ''
            THEN split_part(a.email, '@', 1)
        WHEN a.full_name LIKE '%@%'
            THEN split_part(a.full_name, '@', 1)
        ELSE btrim(a.full_name)
    END                                     AS atendente,
    a.is_enabled                            AS ativo,
    a.status                                AS status_no_momento_da_coleta,
    a.teams                                 AS filas,
    a._data_extracao
FROM bronze.blip_attendants a
WHERE a.identity IS NOT NULL;

-- ===== Tickets =====
-- Uma linha por ticket, que é uma conversa atendida por gente.
CREATE OR REPLACE VIEW silver.blip_tickets AS
WITH tags AS (
    -- O Blip empilha, no mesmo campo, dois tipos de rótulo: o empreendimento
    -- ("PDO - Parc das Orquideas RP") e o motivo de encerramento ("Cliente
    -- indisponível"). O padrão de três caracteres seguido de " - " separa os
    -- dois com segurança.
    --
    -- Na base de 09/set/2026 nenhum ticket tinha mais de uma tag. O max() é o
    -- que mantém esta view correta caso isso mude: em vez de duplicar a linha
    -- do ticket e inflar a contagem de atendimentos, ele escolhe uma, e a
    -- coluna qtd_tags denuncia que houve escolha.
    SELECT
        t.sequential_id,
        max(tag) FILTER (WHERE tag ~ '^[A-Z0-9]{3} - ')  AS tag_empreendimento,
        max(tag) FILTER (WHERE tag !~ '^[A-Z0-9]{3} - ') AS tag_motivo,
        count(*)                                         AS qtd_tags
    FROM bronze.blip_tickets t
    CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(t.tags, '[]'::jsonb)) AS x(tag)
    GROUP BY t.sequential_id
)
SELECT
    t.sequential_id,
    t.id                                    AS id_ticket,
    t.parent_sequential_id,
    -- Ticket transferido gera um registro novo apontando para o anterior. Sem
    -- esta flag, uma conversa transferida duas vezes vira três atendimentos na
    -- volumetria.
    (t.parent_sequential_id IS NOT NULL)    AS e_continuacao,

    -- --- situação -------------------------------------------------------
    t.status                                AS status_origem,
    CASE t.status
        WHEN 'ClosedAttendant'        THEN 'Finalizado'
        WHEN 'ClosedClient'           THEN 'Finalizado'
        WHEN 'ClosedClientInactivity' THEN 'Abandonado'
        WHEN 'Open'                   THEN 'Aberto'
        WHEN 'Waiting'                THEN 'Em espera'
        WHEN 'Transferred'            THEN 'Transferido'
        ELSE t.status
    END                                     AS situacao,
    (t.status IN ('ClosedAttendant', 'ClosedClient', 'ClosedClientInactivity'))
                                            AS fechado,

    -- --- quem e onde ----------------------------------------------------
    btrim(t.team)                           AS fila,
    -- Junta com silver.blip_atendentes por esta coluna: os dois lados vêm do
    -- Blip no mesmo formato, então o join é exato e não depende da
    -- decodificação abaixo.
    t.agent_identity                        AS atendente_identity,
    -- Versão legível: "mateus.pandochi%40pafil.com.br@blip.ai" vira
    -- "mateus.pandochi@pafil.com.br". Serve para exibir e para cruzar com
    -- outros sistemas por e-mail, nunca como chave de join interna.
    lower(replace(regexp_replace(t.agent_identity, '@blip\.ai$', ''), '%40', '@'))
                                            AS atendente_email,
    lower(replace(regexp_replace(t.closed_by, '@blip\.ai$', ''), '%40', '@'))
                                            AS encerrado_por_email,

    -- --- cliente e canal ------------------------------------------------
    -- A identidade do cliente vem tunelada (...@tunnel.msging.net), não é o
    -- telefone. O canal real fica no domínio.
    t.customer_identity,
    t.customer_domain,
    CASE t.customer_domain
        WHEN 'wa.gw.msging.net' THEN 'WhatsApp'
        ELSE t.customer_domain  -- acrescentar conforme novos canais aparecerem
    END                                     AS canal,

    -- --- tags -----------------------------------------------------------
    g.tag_empreendimento,
    substring(g.tag_empreendimento from '^([A-Z0-9]{3}) - ')    AS empreendimento_codigo,
    substring(g.tag_empreendimento from '^[A-Z0-9]{3} - (.*)$') AS empreendimento_tag,
    g.tag_motivo                            AS motivo_encerramento,
    coalesce(g.qtd_tags, 0)                 AS qtd_tags,

    -- --- momentos (UTC, como a API entrega) ------------------------------
    t.storage_date,
    t.open_date,
    t.first_response_date,
    t.close_date,
    t.status_date,

    -- --- datas locais, para agrupar por dia ------------------------------
    -- O fuso é explícito de propósito. Um ::date direto usaria o timezone da
    -- sessão, e uma conexão em UTC (tarefa agendada, gateway do Power BI)
    -- jogaria tudo que aconteceu depois das 21h para o dia seguinte, sem erro
    -- visível: o gráfico simplesmente não bateria com o painel do Blip.
    (t.storage_date AT TIME ZONE 'America/Sao_Paulo')::date AS data_criacao,
    (t.open_date    AT TIME ZONE 'America/Sao_Paulo')::date AS data_abertura,
    (t.close_date   AT TIME ZONE 'America/Sao_Paulo')::date AS data_fechamento,

    -- --- durações, em segundos -------------------------------------------
    -- Duração negativa é erro de dado, não medida. O CASE devolve NULL nesse
    -- caso, porque um negativo entrando numa média a puxa para baixo em
    -- silêncio e ninguém percebe olhando o cartão.
    CASE WHEN t.open_date >= t.storage_date
         THEN EXTRACT(EPOCH FROM (t.open_date - t.storage_date))::numeric END
                                            AS espera_fila_seg,
    CASE WHEN t.first_response_date >= t.open_date
         THEN EXTRACT(EPOCH FROM (t.first_response_date - t.open_date))::numeric END
                                            AS ate_primeira_resposta_seg,
    CASE WHEN t.first_response_date >= t.storage_date
         THEN EXTRACT(EPOCH FROM (t.first_response_date - t.storage_date))::numeric END
                                            AS espera_total_seg,
    CASE WHEN t.close_date >= t.open_date
         THEN EXTRACT(EPOCH FROM (t.close_date - t.open_date))::numeric END
                                            AS atendimento_seg,
    -- Já vem calculado pelo Blip, em segundos. É o "Tempo médio de resposta"
    -- do painel, e não se deriva das outras datas.
    t.average_agent_response_time           AS tempo_resposta_medio_seg,

    -- --- outros ----------------------------------------------------------
    t.priority                              AS prioridade,
    -- Veio 0 em 100% da base de 09/set/2026, o que sugere recurso não usado.
    -- Confirmar antes de construir qualquer medida de satisfação em cima.
    t.rating                                AS avaliacao,
    t.campaign_id                           AS id_campanha,
    t._data_extracao
FROM bronze.blip_tickets t
LEFT JOIN tags g ON g.sequential_id = t.sequential_id;
