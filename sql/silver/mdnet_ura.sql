-- Camada SILVER do relatório de URA da MDnet. Aplicar com `aplicar_silver.py --so-mdnet` (que
-- aplica também o mdnet.sql) ou `aplicar_silver.py` (tudo).
--
-- Arquivo separado do mdnet.sql de propósito: estas views dependem da tabela
-- bronze.mdnet_ura, que só existe depois de `ingerir_mdnet_ura.py --criar-tabelas`. Num
-- arquivo só, a falta dessa tabela derrubaria também a view de chamadas, que é independente.
--
-- O relatório de URA tem uma linha por PASSAGEM por um menu (ver o comentário de
-- bronze.mdnet_ura). Aqui ele vira dois níveis:
--
-- 1. silver.mdnet_ura_passagens: uma linha por passagem, com as colunas limpas e a opção
--    rotulada como o gráfico do painel rotula (a descrição quando a pessoa digitou, e o estado
--    quando não digitou ou desligou).
-- 2. silver.mdnet_ura_chamadas: uma linha por LIGAÇÃO que passou pela URA, com o caminho
--    inteiro (menu principal e submenu) e o desfecho dela no CDR (se foi atendida, por quem,
--    quanto esperou).
--
-- O relatório não tem protocolo, então o cruzamento com o CDR é por telefone + horário: o
-- horário da URA é o INÍCIO da ligação e bate, ao segundo, com
-- silver.mdnet_chamadas.data_hora_inicio (diferença zero nas 1.012 ligações de setembro/2026),
-- e o telefone casa pelos 11 últimos dígitos. Número oculto ("Anonymous") casa pelo texto.

CREATE SCHEMA IF NOT EXISTS silver;

-- Aviso para quem for MUDAR a forma destas views: o CREATE OR REPLACE VIEW do Postgres só
-- acrescenta coluna no FIM do SELECT. Renomear, reordenar ou remover coluna faz o comando
-- falhar. Acrescente colunas novas sempre no fim.
CREATE OR REPLACE VIEW silver.mdnet_ura_passagens AS
SELECT
    u.ura || '|' || u.data::text || ' ' || u.hora || '|' || u.origem || '|' || u.ordem
                                                                AS passagem_id,
    u.ura,
    CASE WHEN u.ura = 'Ura_Principal' THEN 'Principal' ELSE 'Submenu' END AS nivel,
    CASE WHEN u.hora ~ '^[0-9]{2}:[0-5][0-9]:[0-5][0-9]$'
         THEN u.data + u.hora::time END                         AS data_hora,
    u.data,
    CASE WHEN u.hora ~ '^[0-9]{2}:' THEN left(u.hora, 2)::int END AS hora,
    u.origem,
    -- Telefone de quem ligou, só dígitos, 11 últimos. É a chave de cruzamento com o CDR.
    nullif(right(regexp_replace(u.origem, '[^0-9]', '', 'g'), 11), '') AS numero_cliente,
    nullif(u.digitacao, '')                                     AS digito,
    -- Digitou, Não Digitou (estourou o tempo) ou Desligou na URA.
    u.estado                                                    AS estado_ura,
    -- Rótulo da escolha, igual ao do gráfico "Quantidades de Chamadas por Opção da URA".
    CASE WHEN u.estado = 'Digitou' THEN u.descricao ELSE u.estado END AS opcao,
    (u.estado = 'Digitou')                                      AS e_digitou,
    (u.estado = 'Desligou na URA')                              AS e_desligou_na_ura,
    nullif(u.acao, '')                                          AS acao,
    nullif(u.aplicacao_destino, '')                             AS destino_codigo,
    -- INFERIDO do padrão dos códigos vistos em set/2026, não confirmado com a MDnet: 50xx são
    -- os submenus, 60xx departamentos ou filas, 8xxx ramais. Os 5 casos de "Não Digitou" com
    -- 0800 ou 8260 são a pessoa digitando um número de 4 dígitos no menu.
    CASE
        WHEN nullif(u.aplicacao_destino, '') IS NULL THEN NULL
        WHEN u.aplicacao_destino ~ '^50[0-9]{2}$' THEN 'Submenu'
        WHEN u.aplicacao_destino ~ '^60[0-9]{2}$' THEN 'Departamento ou fila'
        WHEN u.aplicacao_destino ~ '^8[0-9]{3}$'  THEN 'Ramal'
        ELSE 'Outro'
    END                                                         AS destino_tipo,
    u.descricao,
    u.opcoes_digitos,
    -- Chave de cruzamento: o telefone e, quando o número é oculto ("Anonymous", sem nenhum
    -- dígito), o próprio texto em minúsculas. Sem isso, a ligação anônima nunca casaria, porque
    -- NULL nunca é igual a NULL (3 passagens de 1.419 em set/2026). Fica no fim da lista porque
    -- entrou depois da primeira aplicação da view (CREATE OR REPLACE só acrescenta no fim).
    coalesce(
        nullif(right(regexp_replace(u.origem, '[^0-9]', '', 'g'), 11), ''),
        nullif(lower(btrim(u.origem)), '')
    )                                                           AS chave_origem
FROM bronze.mdnet_ura u;

-- A árvore do menu da URA, como a operação a descreve (mapeamento de troncos fornecido por
-- quem administra a URA, em 05/out/2026). Os dígitos de cada submenu conferem com os que o
-- relatório registra (conferido nas 1.419 passagens de set/2026). Se o menu mudar, é aqui que
-- se atualiza. `submenu` é o menu para onde o dígito leva, quando leva a um.
CREATE OR REPLACE VIEW silver.mdnet_ura_menu AS
SELECT m.ura, m.digito, m.codigo, m.nome, m.locucao, m.submenu
FROM (VALUES
    ('Ura_Principal',   '1', '1',   'Cliente',                  'se você já é nosso cliente',  'Sub_URA_opcao_1'),
    ('Ura_Principal',   '2', '2',   'Vendas',                   'se deseja adquirir um imóvel', NULL),
    ('Ura_Principal',   '3', '3',   'Fornecedor',               'caso seja fornecedor',        'Sub_URA_opcao_3'),
    ('Sub_URA_opcao_1', '1', '1.1', 'Segunda via de boleto',    'segunda via boleto',          NULL),
    ('Sub_URA_opcao_1', '2', '1.2', 'Renegociação',             'renegociação',                NULL),
    ('Sub_URA_opcao_1', '3', '1.3', 'Acompanhamento de obra',   'acompanhamento de obra',      NULL),
    ('Sub_URA_opcao_1', '4', '1.4', 'Dúvidas de financiamento', 'duvidas financiamento',       NULL),
    ('Sub_URA_opcao_3', '1', '3.1', 'Suprimentos',              'suprimentos',                 NULL),
    ('Sub_URA_opcao_3', '2', '3.2', 'Financeiro',               'financeiro',                  NULL)
) AS m(ura, digito, codigo, nome, locucao, submenu);

CREATE OR REPLACE VIEW silver.mdnet_ura_chamadas AS
SELECT
    p.passagem_id,
    p.data_hora,
    p.data,
    p.hora,
    p.origem,
    p.numero_cliente,
    -- Escolha no menu principal: Cliente, Vendas, Fornecedor, Não Digitou ou Desligou na URA.
    p.opcao                                                     AS escolha_principal,
    p.estado_ura                                                AS estado_principal,
    p.digito                                                    AS digito_principal,
    p.destino_codigo                                            AS destino_principal,
    -- Submenu (Cliente leva ao Sub_URA_opcao_1, Fornecedor ao Sub_URA_opcao_3).
    s.ura                                                       AS submenu,
    s.opcao                                                     AS escolha_submenu,
    s.destino_codigo                                            AS destino_submenu,
    (s.passagem_id IS NOT NULL)                                 AS entrou_submenu,
    p.opcao || coalesce(' > ' || s.opcao, '')                   AS caminho,
    coalesce(s.destino_codigo, p.destino_codigo)                AS destino_final,
    -- Do CDR. Ficam vazios quando a ligação não foi achada (2 de 1.012 em set/2026).
    (c.chamada_id IS NOT NULL)                                  AS tem_cdr,
    c.chamada_id,
    c.atendida,
    c.ramal                                                     AS ramal_atendente,
    c.atendido_por,
    c.espera_s,
    c.falado_s,
    c.duracao_total_s,
    c.e_transferida,
    c.tipo_transferencia,
    c.desfecho                                                  AS desfecho_chamada,
    c.numero_chamado,
    c.rota_entrada,
    p.chave_origem,
    -- Opção escolhida, com o código e o nome que a locução da URA usa (silver.mdnet_ura_menu):
    -- 1.2 e Renegociação, por exemplo. Vazio quando a pessoa não digitou ou desligou.
    CASE
        WHEN s.passagem_id IS NOT NULL AND s.estado_ura = 'Digitou' THEN ms.codigo
        WHEN s.passagem_id IS NULL AND p.estado_ura = 'Digitou' THEN mp.codigo
    END                                                         AS codigo_opcao,
    -- Nome da opção mais funda (o do submenu, se entrou num). Quando não houve opção, o motivo:
    -- Não Digitou ou Desligou na URA.
    CASE
        WHEN s.passagem_id IS NOT NULL THEN coalesce(ms.nome, s.opcao)
        ELSE coalesce(mp.nome, p.opcao)
    END                                                         AS nome_opcao,
    coalesce(mp.nome, p.opcao) || coalesce(' > ' || coalesce(ms.nome, s.opcao), '')
                                                                AS caminho_nome,
    -- Falso para o que o menu atual não explica: dígito de submenu que não é o do menu principal
    -- (ex.: Vendas seguida de Renegociação) ou dígito que o menu não tem. Vem do menu antigo,
    -- das primeiras semanas (mar a mai/2026), e vale tratar como legado.
    coalesce(
        CASE
            WHEN s.passagem_id IS NULL
                THEN p.estado_ura <> 'Digitou' OR mp.codigo IS NOT NULL
            ELSE p.estado_ura = 'Digitou' AND mp.submenu = s.ura
                 AND (s.estado_ura <> 'Digitou' OR ms.codigo IS NOT NULL)
        END,
        false
    )                                                           AS e_menu_atual,
    -- Quem atendeu, pelo ramal (silver.dpara_ramais). Vazio quando ninguém atendeu, quando o
    -- ramal não está na planilha ou quando a ligação não foi achada no CDR.
    c.unidade_ramal                                             AS unidade_atendente,
    c.setor_ramal                                               AS setor_atendente,
    c.setor_grupo_ramal                                         AS setor_grupo_atendente,
    c.responsavel_ramal                                         AS responsavel_atendente
FROM silver.mdnet_ura_passagens p
LEFT JOIN LATERAL (
    -- Uma ligação que entra num submenu tem uma segunda linha com o mesmo horário e telefone.
    SELECT s0.*
    FROM silver.mdnet_ura_passagens s0
    WHERE s0.nivel = 'Submenu'
      AND s0.chave_origem = p.chave_origem
      AND s0.data_hora = p.data_hora
    ORDER BY s0.passagem_id
    LIMIT 1
) s ON true
LEFT JOIN LATERAL (
    SELECT c0.*
    FROM silver.mdnet_chamadas c0
    WHERE c0.direcao_painel = 'Entrada'
      AND c0.data_hora_inicio = p.data_hora
      AND coalesce(
              nullif(right(regexp_replace(c0.origem, '[^0-9]', '', 'g'), 11), ''),
              nullif(lower(btrim(c0.origem)), '')
          ) = p.chave_origem
    ORDER BY c0.chamada_id
    LIMIT 1
) c ON true
LEFT JOIN silver.mdnet_ura_menu mp
       ON mp.ura = p.ura AND mp.digito = p.digito AND p.estado_ura = 'Digitou'
LEFT JOIN silver.mdnet_ura_menu ms
       ON ms.ura = s.ura AND ms.digito = s.digito AND s.estado_ura = 'Digitou'
WHERE p.nivel = 'Principal';
