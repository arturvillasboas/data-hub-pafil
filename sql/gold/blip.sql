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

-- ===== Dimensões =====

CREATE OR REPLACE VIEW gold.dim_fila AS
SELECT
    f.fila,
    f.agents_online AS agentes_online_agora
FROM silver.blip_filas f;

CREATE OR REPLACE VIEW gold.dim_atendente AS
SELECT
    a.atendente_identity,
    a.atendente,
    a.atendente_email,
    a.ativo,
    a.filas
FROM silver.blip_atendentes a;

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
    t.atendente_identity,
    a.atendente,
    a.atendente_email,
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
LEFT JOIN silver.blip_atendentes a
       ON a.atendente_identity = t.atendente_identity
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
