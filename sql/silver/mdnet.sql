-- Camada SILVER do CDR de telefonia da MDnet (DDA Telecom). Aplicar com
-- `aplicar_silver.py` (tudo) ou `aplicar_silver.py --so-mdnet` (só este arquivo).
--
-- Arquivo próprio, pelo mesmo motivo do silver/blip.sql: é outra fonte, com outro
-- vocabulário e outro ciclo de vida.
--
-- A bronze (bronze.mdnet_cdr) guarda o CSV do painel como veio. O painel tem três
-- defeitos que esta camada corrige, todos medidos na carga de 05/out/2026
-- (26.922 linhas, de 02/01 a 05/10):
--
-- 1. A coluna Direção mistura a perna do ramal com a perna do tronco da MESMA
--    ligação. Uma ligação feita por um ramal pode aparecer como "Saída" (perna do
--    ramal) ou como "Entrada Não Atendida" (perna do tronco, em que o campo Ramal
--    vira o número discado com prefixo de roteamento, tipo 999xx), e o painel
--    escolhe uma das duas ao acaso a cada exportação. As 147 linhas desse segundo
--    tipo têm origem igual a um ramal e TODAS têm conversa, então são saídas
--    atendidas. A regra é: Entrada com origem de ramal é, na verdade, Saída.
--
-- 2. O Estado "Não Atendida" não é confiável. Aquelas mesmas 147 linhas dizem "Não
--    Atendida" e têm tempo falado. Atendida aqui é Estado = Atendida OU tempo
--    falado maior que zero.
--
-- 3. Códigos de recurso do PABX (captura de chamada *8, *18259 etc.) aparecem como
--    chamadas Interna, 441 linhas. Não são ligações entre pessoas e inflam a
--    volumetria de internas. Viram a direção "Recurso".
--
-- 4. Ligação de ENTRADA encaminhada para um número de fora aparece como "Saída"
--    (479 linhas atendidas): a origem é quem ligou, o destino é o número chamado da
--    empresa (prefixo + 10 dígitos) e o campo Ramal traz o número que atendeu. O
--    painel web as conta como Entrada nos cartões. A regra é: destino longo é Entrada.
--
-- 5. O painel web conta as ligações nos cartões por PRIORIDADE entre as pernas: com
--    perna de entrada é Entrada, senão com perna de saída é Saída, senão Interna. O
--    CSV sem filtro mostra uma perna só por ligação, então a bronze.mdnet_cdr_pernas
--    (relatório filtrado por direção) é quem diz que pernas a ligação tem. Medido em
--    05/out/2026 sobre 26.900 ligações: Entrada 21.137, Saída 1.062 e Interna 4.701,
--    iguais aos cartões. As colunas direcao_cartao e estado_cartao seguem esse critério.
--
-- Além disso, uma transferência gera uma perna extra Interna entre os dois ramais
-- (1.055 linhas casadas, 949 delas "Não Atendida" por CANCELADA PELA ORIGEM). Elas
-- são sinalizadas em e_perna_de_transferencia. Para contar ligações de verdade,
-- filtre e_chamada_real.
--
-- O que esta view NÃO faz, e por quê: o CSV não traz a opção escolhida na URA nem a
-- fila. O que existe é o prefixo do Destino (rota_entrada), que NÃO foi confirmado
-- com a MDnet, então vai cru, sem rótulo.

CREATE SCHEMA IF NOT EXISTS silver;

-- Aviso para quem for MUDAR a forma desta view: o CREATE OR REPLACE VIEW do
-- Postgres só acrescenta coluna no fim. Renomear, reordenar ou remover coluna faz o
-- comando falhar. Acrescente colunas novas sempre no fim do SELECT final.
CREATE OR REPLACE VIEW silver.mdnet_chamadas AS
WITH transferencias AS (
    -- Quem transferiu para quem, e quando. Serve só para reconhecer a perna Interna
    -- que a transferência gera.
    SELECT t.ramal, t.transferido_de_para, t.data_hora_inicio, t.hora_fim
    FROM bronze.mdnet_cdr t
    WHERE t.tipo_transferencia IS NOT NULL
),
base AS (
    SELECT
        b.protocolo,
        b.ordem,
        b.data_hora_inicio,
        b.hora_fim,
        b.estado,
        b.direcao,
        b.origem,
        b.destino,
        b.ramal,
        -- Tempo de conversa em segundos. O regex protege a view de um valor fora do
        -- formato HH:MM:SS, que de outro modo derrubaria a consulta inteira.
        CASE WHEN b.tempo_falado ~ '^[0-9]+:[0-5][0-9]:[0-5][0-9]$'
             THEN extract(epoch FROM b.tempo_falado::interval)::int
             ELSE 0 END                                         AS falado_s,
        CASE WHEN b.hora_fim IS NOT NULL
             THEN greatest(extract(epoch FROM (b.hora_fim - b.data_hora_inicio))::int, 0)
             ELSE 0 END                                         AS duracao_total_s,
        b.tipo_transferencia,
        b.transferido_de_para,
        b.motivo_desligamento,
        b.lado_desligamento,
        (b.origem ~ '^[*]' OR b.destino ~ '^[*]')               AS e_recurso,
        (b.origem ~ '^[0-9]{1,5}$')                             AS origem_e_ramal,
        (b.destino ~ '^[0-9]{15,}$')                            AS destino_e_longo
    FROM bronze.mdnet_cdr b
),
classificada AS (
    SELECT
        base.*,
        CASE
            WHEN base.e_recurso THEN 'Recurso'
            WHEN base.destino_e_longo AND base.direcao <> 'Interna' THEN 'Entrada'
            WHEN base.direcao = 'Entrada' AND base.origem_e_ramal THEN 'Saída'
            ELSE base.direcao
        END                                                     AS direcao_real,
        (coalesce(base.estado = 'Atendida', false) OR base.falado_s > 0) AS atendida,
        (base.direcao = 'Interna' AND EXISTS (
            SELECT 1
            FROM transferencias t
            WHERE t.ramal = base.origem
              AND t.transferido_de_para = base.destino
              AND base.data_hora_inicio >= t.data_hora_inicio - interval '2 seconds'
              AND base.data_hora_inicio <= t.hora_fim + interval '5 seconds'
        ))                                                      AS e_perna_de_transferencia
    FROM base
)
SELECT
    c.protocolo || '|' || to_char(c.data_hora_inicio, 'YYYYMMDDHH24MISS') || '|' || c.ordem
                                                                AS chamada_id,
    c.protocolo,
    c.data_hora_inicio,
    c.hora_fim,
    c.data_hora_inicio::date                                    AS data,
    extract(hour FROM c.data_hora_inicio)::int                  AS hora,
    extract(isodow FROM c.data_hora_inicio)::int                AS dia_semana,
    -- Segunda a sexta. Não conhece feriado.
    (extract(isodow FROM c.data_hora_inicio) <= 5)              AS e_dia_util,
    c.direcao                                                   AS direcao_painel,
    -- Entrada, Saída, Interna ou Recurso, já com as correções 1, 3 e 4 do cabeçalho.
    -- No período de 01/01 a 05/10, com o Estado do painel, esta regra põe 99,4% das
    -- linhas na mesma célula dos cartões do painel web. O resíduo (cerca de 170
    -- linhas) está em Saída Atendida (395 aqui contra 251 no painel) e não tem regra
    -- simples: não é limiar de tempo falado.
    c.direcao_real                                              AS direcao,
    -- Ligação de verdade: não é código de recurso nem perna de transferência.
    (c.direcao_real <> 'Recurso' AND NOT c.e_perna_de_transferencia) AS e_chamada_real,
    c.atendida,
    -- Só faz sentido para Entrada e Saída. Em Interna, o lado que desligou tem outro
    -- significado.
    CASE
        WHEN c.atendida THEN 'Atendida'
        WHEN c.lado_desligamento = 'Rede Pública' THEN 'Cliente desligou'
        WHEN c.lado_desligamento = 'PABX' THEN 'PABX encerrou'
        WHEN c.motivo_desligamento = 'CANCELADA PELA ORIGEM' THEN 'Origem cancelou'
        ELSE 'Outro'
    END                                                         AS desfecho,
    c.falado_s,
    c.duracao_total_s,
    -- Tempo até atender, incluindo URA e fila: duração total menos o tempo falado.
    -- Só existe para chamada atendida. Nas não atendidas, duracao_total_s é quanto
    -- tempo a chamada durou antes de acabar.
    CASE WHEN c.atendida THEN greatest(c.duracao_total_s - c.falado_s, 0) END AS espera_s,
    CASE
        WHEN c.duracao_total_s <= 3  THEN '0 a 3 s'
        WHEN c.duracao_total_s <= 10 THEN '4 a 10 s'
        WHEN c.duracao_total_s <= 30 THEN '11 a 30 s'
        WHEN c.duracao_total_s <= 60 THEN '31 a 60 s'
        ELSE 'Mais de 60 s'
    END                                                         AS faixa_duracao,
    -- Ramal de 1 a 5 dígitos. Em Entrada é quem atendeu (vazio se ninguém atendeu).
    -- Em saída pela perna do tronco, o campo vem com o número discado, então vale a
    -- origem, que é o ramal que ligou. Em saída pela perna do ramal já vem certo. Nas
    -- saídas cujo Ramal veio como número discado e a origem é o número da empresa, o
    -- ramal que ligou não é conhecido (cerca de 560 linhas), e fica vazio.
    CASE
        WHEN c.ramal ~ '^[0-9]{1,5}$' THEN c.ramal
        WHEN c.direcao = 'Entrada' AND c.origem_e_ramal THEN c.origem
    END                                                         AS ramal,
    -- Só para Entrada atendida. "Número externo" é a chamada encaminhada para um
    -- número de fora (prefixo 55163, por exemplo), e "Captura de chamada" é *8.
    CASE
        WHEN c.direcao_real = 'Entrada' AND c.atendida THEN
            CASE
                WHEN c.ramal ~ '^[0-9]{1,5}$' THEN 'Ramal'
                WHEN c.ramal ~ '^[*]' THEN 'Captura de chamada'
                WHEN c.ramal ~ '^[0-9]+$' THEN 'Número externo'
            END
    END                                                         AS atendido_por,
    -- Em Entrada o Destino vem como prefixo + número chamado (10 dígitos). Os
    -- prefixos vistos são 88810, 88860 (5 caracteres) e 88830015 (8 caracteres), e o
    -- mesmo número chamado aparece com os três ao longo do ano. Presumivelmente é a
    -- rota ou o tronco por onde a chamada entrou, mas NÃO foi confirmado com a MDnet.
    -- Cru, sem rótulo.
    CASE WHEN c.direcao_real = 'Entrada' AND c.destino ~ '^[0-9]{11,}$'
         THEN left(c.destino, length(c.destino) - 10) END       AS rota_entrada,
    -- Número chamado (DDD + número). O principal concentra cerca de 59% das entradas.
    CASE WHEN c.direcao_real = 'Entrada' AND c.destino ~ '^[0-9]{10,}$'
         THEN right(c.destino, 10) END                          AS numero_chamado,
    (c.tipo_transferencia IS NOT NULL)                          AS e_transferida,
    c.tipo_transferencia,
    CASE WHEN c.transferido_de_para ~ '^[0-9]{1,5}$'
         THEN c.transferido_de_para END                         AS transferido_para_ramal,
    c.e_perna_de_transferencia,
    c.e_recurso,
    -- Entrada que na verdade é a perna do tronco de uma saída (correção 1).
    (c.direcao = 'Entrada' AND c.origem_e_ramal)                AS e_perna_de_tronco,
    c.lado_desligamento,
    c.motivo_desligamento,
    c.estado                                                    AS estado_painel,
    c.origem,
    c.destino,
    CASE
        WHEN c.duracao_total_s <= 3  THEN 1
        WHEN c.duracao_total_s <= 10 THEN 2
        WHEN c.duracao_total_s <= 30 THEN 3
        WHEN c.duracao_total_s <= 60 THEN 4
        ELSE 5
    END                                                         AS faixa_duracao_ordem,
    -- Pernas da ligação, da bronze.mdnet_cdr_pernas. tem_perna_interna só fica verdadeira
    -- depois de carregar o filtro internal (ingerir_mdnet_pernas.py --direcoes internal).
    pe.tem_perna_entrada,
    pe.tem_perna_saida,
    pe.tem_perna_interna,
    pe.estado_perna_entrada,
    pe.estado_perna_saida,
    -- Direção como o painel web conta nos cartões (item 5 do cabeçalho). É a que fecha
    -- com o painel; a coluna `direcao` acima é a nossa leitura da perna que o CSV mostra.
    CASE
        WHEN pe.tem_perna_entrada THEN 'Entrada'
        WHEN pe.tem_perna_saida THEN 'Saída'
        ELSE 'Interna'
    END                                                         AS direcao_cartao,
    -- Estado da perna que classifica a ligação. Em Entrada e Interna fecha com os cartões
    -- do painel (5.100 / 16.037 e 3.049 / 1.652). Em Saída NÃO fecha: o painel mostra 251
    -- atendidas e a perna de saída diz 512, e nenhum critério simples reproduz o 251.
    -- A maioria dessas 512 tem conversa longa (mediana de 65 s), então tratamos o painel
    -- como divergente e mantemos o estado da perna. Para decisão, prefira `atendida`.
    CASE
        WHEN pe.tem_perna_entrada THEN pe.estado_perna_entrada
        WHEN pe.tem_perna_saida THEN pe.estado_perna_saida
        ELSE c.estado
    END                                                         AS estado_cartao
FROM classificada c
CROSS JOIN LATERAL (
    -- Um agregado sem GROUP BY devolve sempre uma linha, então a ligação sem nenhuma
    -- perna carregada continua na view (com as marcas falsas).
    SELECT
        coalesce(bool_or(p.filtro_direcao = 'inbound'), false)  AS tem_perna_entrada,
        coalesce(bool_or(p.filtro_direcao = 'outbound'), false) AS tem_perna_saida,
        coalesce(bool_or(p.filtro_direcao = 'internal'), false) AS tem_perna_interna,
        min(p.estado) FILTER (WHERE p.filtro_direcao = 'inbound')  AS estado_perna_entrada,
        min(p.estado) FILTER (WHERE p.filtro_direcao = 'outbound') AS estado_perna_saida
    FROM bronze.mdnet_cdr_pernas p
    WHERE p.protocolo = c.protocolo
      AND p.data_hora_inicio = c.data_hora_inicio
) pe;
