-- Camada GOLD do Blip (atendimento humano). Aplicar com aplicar_gold.py,
-- depois da silver.
--
-- O recorte foi desenhado a partir das telas do painel nativo do Blip que a
-- gestão pediu para replicar: os cartões de tempo médio, o gráfico de tickets
-- abertos contra fechados, e as três abas de corte (atendente, fila e tag).
-- Duas telas do painel ficaram de fora por falta de fonte, e não por decisão de
-- modelagem: "Atingimento SLA" (a regra não é exposta pela API) e
-- "Disponibilidade de atendentes" (a API só devolve o estado do instante).

CREATE SCHEMA IF NOT EXISTS gold;

-- ===== Por que estes DROP existem =====
-- O `CREATE OR REPLACE VIEW` do Postgres só consegue ACRESCENTAR coluna no fim
-- da lista. Ele não renomeia, não reordena e não remove: qualquer uma dessas
-- três coisas faz o comando falhar com "cannot change name of view column" ou
-- "cannot drop columns from view".
--
-- Isso morde exatamente no caso mais comum de evolução de um modelo, que é
-- inserir uma coluna no meio ou tirar uma que saiu de uso. E morde de um jeito
-- ruim: o arquivo inteiro é aplicado numa transação só, então a view fica com a
-- definição ANTIGA no banco enquanto o repositório mostra a nova. Foi assim que
-- `dim_fila` ficou sem `fila_exibicao` depois de ganhar a coluna aqui.
--
-- Dropar antes de criar resolve, e é seguro porque nenhuma destas quatro views
-- tem dependente. Sem CASCADE de propósito: se um dia alguma ganhar dependente,
-- o DROP falha e avisa, em vez de derrubar em silêncio o que depende dela.
DROP VIEW IF EXISTS gold.blip_tags_sem_empreendimento;
DROP VIEW IF EXISTS gold.fato_atendimentos;
DROP VIEW IF EXISTS gold.dim_fila;
DROP VIEW IF EXISTS gold.dim_atendente;

-- ===== Dimensões =====

-- As duas dimensões abaixo nascem da UNIÃO entre o cadastro do Blip e o que
-- aparece de fato nos tickets, e não só do cadastro. O motivo é integridade
-- referencial: a fila `DIRECT_TRANSFER` (a "Transferência direta" do painel,
-- a maior de todas em volume) não existe no /teams, e um atendente desligado
-- some do /attendants sem que os tickets dele sumam junto. Montando a dimensão
-- só do cadastro, esses tickets ficariam órfãos e o Power BI simplesmente
-- deixaria de mostrá-los em qualquer visual fatiado pela dimensão, sem erro e
-- sem aviso. A coluna `cadastrada_no_blip` guarda a diferença.

CREATE OR REPLACE VIEW gold.dim_fila AS
SELECT
    f.fila,
    -- O Blip guarda esta fila com nome técnico e a exibe traduzida no painel.
    CASE f.fila
        WHEN 'DIRECT_TRANSFER' THEN 'Transferência direta'
        ELSE f.fila
    END                                   AS fila_exibicao,
    c.agents_online                       AS agentes_online_agora,
    (c.fila IS NOT NULL)                  AS cadastrada_no_blip
FROM (
    SELECT DISTINCT fila FROM silver.blip_tickets WHERE fila IS NOT NULL
    UNION
    SELECT fila FROM silver.blip_filas
) f
LEFT JOIN silver.blip_filas c ON c.fila = f.fila;

CREATE OR REPLACE VIEW gold.dim_atendente AS
SELECT
    i.atendente_identity,
    -- Sem cadastro, o nome é derivado da própria identidade do ticket, que é
    -- o e-mail codificado. Melhor um nome aproximado do que uma linha em branco.
    coalesce(
        a.atendente,
        split_part(
            lower(replace(regexp_replace(i.atendente_identity, '@blip\.ai$', ''), '%40', '@')),
            '@', 1)
    )                                     AS atendente,
    coalesce(
        a.atendente_email,
        lower(replace(regexp_replace(i.atendente_identity, '@blip\.ai$', ''), '%40', '@'))
    )                                     AS atendente_email,
    a.ativo,
    a.filas,
    (a.atendente_identity IS NOT NULL)    AS cadastrado_no_blip
FROM (
    SELECT DISTINCT atendente_identity FROM silver.blip_tickets
     WHERE atendente_identity IS NOT NULL
    UNION
    SELECT atendente_identity FROM silver.blip_atendentes
) i
LEFT JOIN silver.blip_atendentes a ON a.atendente_identity = i.atendente_identity;

-- ===== Fato =====
-- Grão: um ticket, que é uma conversa atendida por gente.
--
-- Sobre relacionamento com gold.dim_calendario: o fato tem três datas
-- (criação, abertura e fechamento). A que responde "quantos atendimentos
-- aconteceram no período", que é a pergunta do painel, é a de FECHAMENTO, então
-- ela é a candidata natural a relacionamento ativo, com as outras duas
-- inativas. Mesmo padrão já usado em fato_reservas.
--
-- Sobre e_continuacao: ticket transferido gera um registro novo apontando para
-- o anterior. A flag fica exposta em vez de a view filtrar sozinha, porque as
-- duas leituras são legítimas: contar conversas (excluindo continuação) e
-- contar atendimentos prestados (incluindo). Quem decide é a medida.
CREATE OR REPLACE VIEW gold.fato_atendimentos AS
SELECT
    t.sequential_id,
    t.id_ticket,
    t.parent_sequential_id,
    t.e_continuacao,

    -- --- dimensões ------------------------------------------------------
    t.fila,
    -- Só a chave: nome e e-mail do atendente moram em gold.dim_atendente, que
    -- é quem sabe tratar o atendente sem cadastro. Repetir o atributo aqui
    -- criaria duas versões do mesmo nome, que divergem no dia em que uma das
    -- duas ganhar um coalesce e a outra não.
    t.atendente_identity,
    t.canal,
    t.motivo_encerramento,

    -- Empreendimento vindo da tag. O caminho passa pela mesma de-para que o
    -- resto do projeto usa (silver.dpara_empreendimento, alimentada pela
    -- planilha do backoffice), então grafia nova do Blip se resolve lá e não
    -- aqui no SQL. Quando a tag não casa, id_empreendimento fica NULL e o
    -- empreendimento_tag continua disponível para investigar o gap.
    t.empreendimento_codigo,
    t.empreendimento_tag,
    e.id_empreendimento,
    e.empreendimento,

    -- --- situação -------------------------------------------------------
    t.status_origem,
    t.situacao,
    t.fechado,
    (t.situacao = 'Finalizado')  AS finalizado,
    (t.situacao = 'Abandonado')  AS abandonado,
    (t.situacao = 'Transferido') AS transferido,

    -- --- datas ----------------------------------------------------------
    t.data_criacao,
    t.data_abertura,
    t.data_fechamento,
    t.storage_date,
    t.open_date,
    t.first_response_date,
    t.close_date,

    -- --- medidas, em segundos --------------------------------------------
    -- Ficam em segundos de propósito. Média de segundos é somável e divisível;
    -- média de texto "01:09:12" não é. A formatação em hh:mm:ss é trabalho da
    -- medida no Power BI, não da camada de dados.
    t.espera_fila_seg,
    t.ate_primeira_resposta_seg,
    t.espera_total_seg,
    t.atendimento_seg,
    t.tempo_resposta_medio_seg,

    -- --- outros ----------------------------------------------------------
    t.prioridade,
    t.avaliacao,
    t.id_campanha,
    t.qtd_tags
FROM silver.blip_tickets t
LEFT JOIN gold.dim_empreendimento e
       ON silver.conformar_empreendimento(t.empreendimento_tag) = e.empreendimento_conformado;

-- ===== Conferência do gap de empreendimento =====
-- Não é uma view de consumo do Power BI: existe para responder, numa consulta
-- só, quanto da tag do Blip está chegando ao empreendimento do DW. Enquanto
-- houver linha com id_empreendimento nulo e tag preenchida, falta entrada na
-- de-para, e o corte por produto do dashboard fica incompleto sem avisar.
CREATE OR REPLACE VIEW gold.blip_tags_sem_empreendimento AS
SELECT
    t.empreendimento_codigo,
    t.empreendimento_tag,
    silver.conformar_empreendimento(t.empreendimento_tag) AS nome_conformado,
    count(*)                                              AS tickets
FROM silver.blip_tickets t
LEFT JOIN gold.dim_empreendimento e
       ON silver.conformar_empreendimento(t.empreendimento_tag) = e.empreendimento_conformado
WHERE t.empreendimento_tag IS NOT NULL
  AND e.id_empreendimento IS NULL
GROUP BY 1, 2, 3
ORDER BY tickets DESC;
