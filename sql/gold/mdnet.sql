-- Camada GOLD da telefonia (MDnet). Aplicar com aplicar_gold.py, depois da silver
-- (aplicar_silver.py --so-mdnet) e da carga dos ramais (popular_seeds.py --ramais).
--
-- Duas peças, no mesmo desenho do Blip:
--
--   gold.fato_chamadas  uma LIGAÇÃO por linha, com tudo o que o Power BI precisa para cortar:
--                       direção, atendida, tempos, ramal, número chamado, o caminho na URA e a
--                       marca de ruído (robocall e spam).
--   gold.dim_ramal      de quem é cada ramal (setor, responsável), a partir da planilha de ramais.
--
-- Por que UMA fato só, com a URA dentro, e não duas: a pergunta da gestão é sempre "das ligações
-- que chegaram, o que aconteceu com elas", e a URA é só mais um atributo da ligação (a opção
-- que a pessoa escolheu). Com a URA numa fato separada, cada visual precisaria de duas fatos e de
-- uma ponte, para responder o que uma coluna responde. A silver mantém os dois grãos
-- (mdnet_ura_passagens é por passagem em menu), e a gold entrega o da ligação.
--
-- O que NÃO está aqui, de propósito:
--   * Telefone de cliente. O CDR traz o número de quem ligou, e isso é dado pessoal. O Power BI
--     recebe `chamador_id`, um identificador derivado (md5), que basta para contar clientes
--     distintos e ligações repetidas sem expor o número. Não é anonimização forte (telefone tem
--     pouca entropia), é para não deixar o número à vista em visual, exportação ou tooltip.
--   * Recurso do PABX (captura de chamada *8) e perna de transferência. Não são ligações entre
--     pessoas e inflariam a volumetria; a silver os marca em e_chamada_real e a gold os deixa
--     de fora. Com esse corte, Entrada fecha com o cartão do painel web (21.137 em jan a out/2026).

CREATE SCHEMA IF NOT EXISTS gold;

-- DROP antes do CREATE: o CREATE OR REPLACE VIEW só acrescenta coluna no fim, e uma fato evolui
-- inserindo e tirando coluna. Sem CASCADE de propósito: se uma view ganhar dependente, o DROP
-- falha e avisa, em vez de derrubar em silêncio o que depende dela. Estas views NÃO dependem de
-- gold.dim_calendario (o gold.sql a recria com CASCADE), de modo que reaplicar o gold.sql não as
-- derruba.
DROP VIEW IF EXISTS gold.fato_chamadas;
DROP VIEW IF EXISTS gold.dim_ramal;

-- ===== Dimensão =====
-- Nasce da UNIÃO entre a planilha e o que aparece de fato nas ligações. Só da planilha, um ramal
-- que atendeu e não está nela (o 8223, que atendeu 63 ligações de abril a setembro e saiu da
-- lista de ativos) deixaria essas ligações órfãs, e o Power BI esconderia a linha em qualquer
-- visual cortado pela dimensão, sem erro e sem aviso. `cadastrado_na_planilha` guarda a diferença.
--
-- A planilha é uma foto de HOJE. O ramal 8256 está "Vago" e atendeu 134 entradas de janeiro a
-- abril. Por isso `setor_grupo` é o grão estável para somar, e `responsavel` é informação do
-- momento e pode estar errada para ligações antigas.
CREATE VIEW gold.dim_ramal AS
SELECT
    r.ramal,
    coalesce(d.unidade, 'Sem cadastro')                       AS unidade,
    d.setor,
    coalesce(d.setor_grupo, 'Sem cadastro')                   AS setor_grupo,
    d.responsavel,
    coalesce(d.eh_vago, false)                                AS eh_vago,
    (d.ramal IS NOT NULL)                                     AS cadastrado_na_planilha,
    -- O que aparece em tabela e slicer: "8260 Suprimentos 1 - Maria".
    r.ramal || coalesce(' ' || d.setor, ' (sem cadastro)')
            || coalesce(' - ' || d.responsavel, '')           AS ramal_exibicao
FROM (
    SELECT DISTINCT c.ramal FROM silver.mdnet_chamadas c
     WHERE c.ramal IS NOT NULL AND c.e_chamada_real
    UNION
    SELECT p.ramal FROM silver.dpara_ramais p
) r
LEFT JOIN silver.dpara_ramais d ON d.ramal = r.ramal;

-- ===== Fato =====
-- Grão: uma ligação (Entrada, Saída ou Interna) que não seja recurso do PABX nem perna de
-- transferência.
--
-- Sobre `atendida`: Estado = Atendida OU tempo falado maior que zero. O estado do painel não é
-- confiável sozinho (há ligações "Não Atendida" com conversa), ver o cabeçalho de silver/mdnet.sql.
--
-- Sobre `direcao` e `atendida` DA LIGAÇÃO: seguem a regra do painel web (a mesma dos cartões), e
-- não a leitura da perna que o CSV mostra. O CSV sem filtro mostra UMA perna por ligação, e às vezes
-- é a perna errada: uma ligação que entrou, foi atendida e foi encaminhada para um número de fora
-- aparece como "Saída" (a perna de saída), e a silver lê "Saída". Mas ela entrou. Medido em
-- 05/out/2026: 52 ligações reais assim (43 atendidas) e 8 lidas como Interna, o que fazia a
-- Entrada do Power BI ficar 44 abaixo do cartão do painel (e 43 atendidas abaixo, 0,8%). Com a
-- regra do painel (tem perna de entrada, é Entrada), Entrada e Atendida da gold passam a fechar
-- com o cartão. Para Saída e Interna vale a nossa leitura, que tira recurso do PABX e perna de
-- transferência (o painel os conta; veja docs em powerbi/PAGINA_TELEFONIA.md).
-- `direcao_cartao` continua exposta, só para conferir.
--
-- Sobre `e_ruido`: marca ligação de ENTRADA que não foi atendida e que tem o padrão de robocall
-- ou spam. Duas regras, nesta ordem:
--   1. origem em formato internacional ("00...": no CDR são telemarketing de SP escrito como
--      00 55 11 ..., 1.695 ligações de jan a out/2026, 9% atendidas);
--   2. a mesma origem liga 10 vezes ou mais no mês, com 3% ou menos de atendimento E duração
--      média de até 10 s. O limite de duração é o que separa robocall (a linha cai em segundos)
--      de cliente de verdade insistindo (espera dezenas de segundos e ninguém atende). Sem ele,
--      a regra de contagem pura apagaria os clientes com a pior experiência do mês.
-- Ligação ATENDIDA nunca é ruído, por definição: houve conversa. A flag marca, não apaga, e as
-- medidas do Power BI mostram os dois números (com e sem ruído).
--
-- Sobre o cruzamento com a URA: vem de silver.mdnet_ura_chamadas, que liga por telefone mais o
-- horário de início. O painel só mostra a configuração ATUAL dos menus (em ago/2026 um menu foi
-- renomeado e o antigo, de 245 ligações, sumiu do relatório), então `passou_ura` falso quer dizer
-- "não aparece no relatório de URA atual", e não necessariamente "nunca chegou à URA".
CREATE VIEW gold.fato_chamadas AS
WITH ura AS (
    -- Uma linha por ligação do CDR. A silver liga cada passagem a uma ligação, e duas passagens
    -- idênticas escolheriam a mesma; o DISTINCT ON garante que a fato não duplique linha.
    SELECT DISTINCT ON (u.chamada_id)
        u.chamada_id,
        u.escolha_principal,
        u.codigo_opcao,
        u.caminho_nome,
        u.e_menu_atual
    FROM silver.mdnet_ura_chamadas u
    WHERE u.chamada_id IS NOT NULL
    ORDER BY u.chamada_id, u.passagem_id
),
base AS (
    SELECT
        c.*,
        -- Chave de quem ligou: os 11 últimos dígitos, ou o texto quando o número é oculto
        -- ("Anonymous"). Só para ligação de entrada; em interna a origem é um ramal.
        CASE WHEN c.direcao = 'Entrada' THEN
            coalesce(nullif(right(regexp_replace(c.origem, '[^0-9]', '', 'g'), 11), ''),
                     nullif(lower(btrim(c.origem)), ''))
        END                                                   AS origem_chave,
        -- Regra do painel web: com perna de entrada, é Entrada. A leitura da silver só vale quando
        -- o painel não diz Entrada; e quando ELA diz Entrada e o painel não (16 casos, todos não
        -- atendidos, sem perna de entrada carregada), vale o painel.
        CASE
            WHEN c.direcao_cartao = 'Entrada' THEN 'Entrada'
            WHEN c.direcao = 'Entrada' THEN c.direcao_cartao
            ELSE c.direcao
        END                                                   AS direcao_final,
        -- Em Entrada, atendida é o estado da perna de entrada. Mantemos a nossa regra extra (tempo
        -- falado maior que zero) só quando a perna mostrada é a própria perna de entrada.
        CASE
            WHEN c.direcao_cartao = 'Entrada'
                THEN (c.estado_cartao = 'Atendida' OR (c.direcao = 'Entrada' AND c.atendida))
            ELSE c.atendida
        END                                                   AS atendida_final
    FROM silver.mdnet_chamadas c
    WHERE c.e_chamada_real
),
chamador_mes AS (
    SELECT
        b.origem_chave,
        date_trunc('month', b.data_hora_inicio)               AS mes,
        count(*)                                              AS ligacoes,
        count(*) FILTER (WHERE b.atendida)                    AS atendidas,
        avg(b.duracao_total_s)                                AS duracao_media_s
    FROM base b
    WHERE b.direcao = 'Entrada' AND b.origem_chave IS NOT NULL
    GROUP BY 1, 2
)
SELECT
    b.chamada_id,
    b.protocolo,

    -- --- tempo -------------------------------------------------------------------------
    b.data_hora_inicio,
    b.hora_fim,
    b.data,
    b.hora,
    b.dia_semana,
    (ARRAY['seg','ter','qua','qui','sex','sáb','dom'])[b.dia_semana] AS dia_semana_nome,
    b.e_dia_util,

    -- --- o que foi a ligação -------------------------------------------------------------
    b.direcao_final                                           AS direcao,
    b.atendida_final                                          AS atendida,
    -- A silver decide o desfecho pela perna mostrada. Se a ligação não é atendida pela regra do
    -- painel mas a perna mostrada tinha conversa, o desfecho "Atendida" ficaria contraditório.
    CASE
        WHEN b.atendida_final THEN 'Atendida'
        WHEN b.desfecho = 'Atendida' THEN 'Outro'
        ELSE b.desfecho
    END                                                       AS desfecho,
    b.e_transferida,
    b.tipo_transferencia,
    b.transferido_para_ramal,

    -- --- tempos, em segundos --------------------------------------------------------------
    -- Segundos de propósito: média de segundos soma e divide, texto "00:01:12" não. A formatação
    -- em mm:ss é trabalho da medida no Power BI.
    b.falado_s,
    b.duracao_total_s,
    -- Só existe para ligação atendida: quanto a pessoa esperou até alguém atender, contando o
    -- tempo dentro da URA (duração total menos o tempo falado).
    CASE WHEN b.atendida_final THEN b.espera_s END            AS espera_s,
    b.faixa_duracao,
    b.faixa_duracao_ordem,

    -- --- ramal e número chamado ------------------------------------------------------------
    -- Em Entrada atendida é quem atendeu. Em Saída é quem ligou. Vazio quando ninguém atendeu.
    -- Só a chave: setor e responsável moram em gold.dim_ramal.
    b.ramal,
    b.atendido_por,
    b.numero_chamado,
    b.rota_entrada,

    -- --- quem ligou, sem expor o telefone --------------------------------------------------
    CASE WHEN b.origem_chave IS NOT NULL
         THEN left(md5('mdnet|' || b.origem_chave), 12) END   AS chamador_id,
    -- Quantas vezes essa mesma origem ligou no mês da ligação: a leitura de "quem insiste".
    cm.ligacoes::int                                          AS chamador_ligacoes_mes,

    -- --- ruído ---------------------------------------------------------------------------
    -- coalesce: sem a linha de chamador_mes (origem vazia) as comparações dão NULL, e a flag
    -- tem que ser falso, não nulo.
    coalesce(b.direcao_final = 'Entrada' AND NOT b.atendida_final AND (
         b.origem ~ '^00'
         OR (cm.ligacoes >= 10
             AND cm.atendidas::numeric / cm.ligacoes <= 0.03
             AND cm.duracao_media_s <= 10)
    ), false)                                                 AS e_ruido,
    CASE
        WHEN b.direcao_final <> 'Entrada' OR b.atendida_final THEN NULL
        WHEN b.origem ~ '^00' THEN 'Origem em formato internacional (00...)'
        WHEN cm.ligacoes >= 10
             AND cm.atendidas::numeric / cm.ligacoes <= 0.03
             AND cm.duracao_media_s <= 10
            THEN 'Repete 10 vezes ou mais no mês, sem atendimento e com ligação curta'
    END                                                       AS motivo_ruido,

    -- --- URA --------------------------------------------------------------------------------
    (u.chamada_id IS NOT NULL)                                AS passou_ura,
    -- O desfecho dentro da URA, em quatro valores mais o menu antigo. É o primeiro degrau do funil.
    CASE
        WHEN u.chamada_id IS NULL THEN NULL
        WHEN NOT u.e_menu_atual THEN 'Menu antigo'
        WHEN u.codigo_opcao IS NOT NULL THEN 'Chegou a um destino'
        WHEN u.escolha_principal = 'Não Digitou' THEN 'Não digitou nada'
        WHEN u.escolha_principal = 'Desligou na URA' THEN 'Desligou no menu principal'
        ELSE 'Desistiu no submenu'
    END                                                       AS ura_resultado,
    -- A opção como a locução da URA a descreve: "1.2 Cliente > Renegociação". Quando não houve
    -- escolha, o motivo ("Não Digitou", "Cliente > Desligou na URA").
    CASE
        WHEN u.chamada_id IS NULL THEN NULL
        WHEN NOT u.e_menu_atual THEN 'Menu antigo (' || u.caminho_nome || ')'
        ELSE coalesce(u.codigo_opcao || ' ', '') || u.caminho_nome
    END                                                       AS ura_opcao,
    -- Ordem para o visual: as opções do menu em ordem de código, depois quem não escolheu.
    CASE
        WHEN u.chamada_id IS NULL THEN NULL
        WHEN NOT u.e_menu_atual THEN 99
        WHEN u.codigo_opcao ~ '^[0-9]+(\.[0-9]+)?$'
            THEN split_part(u.codigo_opcao, '.', 1)::int * 10
                 + coalesce(nullif(split_part(u.codigo_opcao, '.', 2), '')::int, 0)
        WHEN u.escolha_principal = 'Não Digitou' THEN 90
        WHEN u.escolha_principal = 'Desligou na URA' THEN 91
        ELSE 92
    END                                                       AS ura_opcao_ordem,
    u.codigo_opcao                                            AS ura_codigo_opcao,
    coalesce(u.e_menu_atual, false)                           AS ura_menu_atual,

    -- --- só para conferir contra o painel -----------------------------------------------------
    b.direcao_cartao,
    b.estado_cartao,
    b.lado_desligamento,
    b.motivo_desligamento
FROM base b
LEFT JOIN chamador_mes cm
       ON cm.origem_chave = b.origem_chave
      AND cm.mes = date_trunc('month', b.data_hora_inicio)
LEFT JOIN ura u ON u.chamada_id = b.chamada_id;

-- ===== Permissão de leitura para o Power BI =====
-- DROP VIEW seguido de CREATE VIEW zera as permissões da view: ela nasce nova, e o que valia para a
-- anterior se perde. Se o dono de quem aplica este arquivo não for o dono dos ALTER DEFAULT
-- PRIVILEGES (infra/grants_bi.sql), a role de leitura do Power BI deixa de ver as duas views, e o
-- Atualizar do Desktop falha com "A chave não correspondia a nenhuma linha na tabela" (o conector
-- lista só o que a role pode ler). Por isso o GRANT mora aqui, e roda a cada aplicação. Só vale
-- se a role existir (em desenvolvimento ela pode não existir), e quem aplica é o dono das views.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pafil_bi') THEN
        GRANT SELECT ON gold.fato_chamadas, gold.dim_ramal TO pafil_bi;
    END IF;
END $$;
