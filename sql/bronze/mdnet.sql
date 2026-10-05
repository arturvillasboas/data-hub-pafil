-- DDL da camada bronze para o CDR de chamadas da MDnet (DDA Telecom).
--
-- Escrito à mão, como o blip.sql: é uma tabela só, de schema pequeno, e nomear as
-- colunas à mão serve de documentação da fonte. As colunas foram modeladas a
-- partir de um export real do relatório de chamadas do painel (05/out/2026), com
-- 15 colunas. O JSON cru de cada linha vai também em `_dados_brutos`, então uma
-- coluna que o painel passe a exportar não se perde enquanto ninguém a adiciona.
--
-- A tabela de controle é a mesma do CVDW (bronze._ingestao_controle), criada por
-- cvdw.db.garantir_schema_e_controle.

CREATE SCHEMA IF NOT EXISTS bronze;

-- ===== mdnet_cdr =====
-- Uma linha por perna de chamada registrada pelo PABX. É o fato central da
-- volumetria de telefonia (entrada, saída e interna).
CREATE TABLE IF NOT EXISTS bronze.mdnet_cdr (
    _id_tecnico bigint GENERATED ALWAYS AS IDENTITY,
    -- É a hora de FIM da chamada (AAAAMMDDHHMMSS) seguida de 2 dígitos que
    -- parecem aleatórios. Não é único sozinho (8 protocolos repetidos na carga de
    -- out/2026, em geral a perna extra de uma transferência), por isso a chave de
    -- negócio soma o início da chamada e o desempate `ordem`.
    -- Valores "SEM-<hash>" são gerados pela carga para as linhas que o painel manda
    -- sem protocolo: tentativas de saída automática que o PABX derruba na hora
    -- (motivo MANDATORY_IE_MISSING). O painel as conta nos totais, então ficam.
    -- O `_dados_brutos` guarda o protocolo vazio, como veio.
    protocolo text NOT NULL,
    -- "Atendida" ou "Não Atendida".
    estado text,
    -- "Entrada", "Saída" ou "Interna".
    direcao text,
    tipo text,
    -- Veio idêntico a `origem` em todas as linhas da amostra.
    nome text,
    origem text,
    -- Em chamada de entrada traz os 10 últimos dígitos do número discado (DDD +
    -- número) com um prefixo que varia (88810, 88830015, 88860 na amostra). A
    -- hipótese é que o prefixo identifica o caminho (URA, fila), mas isso NÃO foi
    -- confirmado com a MDnet. Por isso fica cru aqui e a interpretação é da silver.
    destino text,
    -- Só vem preenchido quando alguém atendeu. Entrada não atendida tem ramal
    -- vazio, então a volumetria por ramal enxerga apenas atendidas e internas.
    ramal text,
    -- Horário local do PABX, sem fuso (timestamp, não timestamptz): o painel não
    -- informa o fuso e supor um aqui seria inventar dado.
    data_hora_inicio timestamp NOT NULL,
    hora_fim timestamp,
    -- Tempo de conversa em HH:MM:SS, não a duração total da chamada. Fica texto
    -- na bronze; a silver converte para segundos.
    tempo_falado text,
    -- "CEGA" na amostra. Uma transferência gera também uma linha extra de direção
    -- Interna entre os dois ramais, o que infla a contagem de internas se a silver
    -- não tratar.
    tipo_transferencia text,
    transferido_de_para text,
    motivo_desligamento text,
    lado_desligamento text,
    -- Desempate da chave de negócio: 0 em quase todas as linhas. Duas chamadas
    -- diferentes podem sair do painel com o mesmo protocolo e o mesmo segundo de
    -- início (3 casos na carga de out/2026, com origem e destino diferentes). A
    -- carga ordena as que colidem pelo conteúdo e numera 0, 1, ..., então a mesma
    -- chamada recebe sempre o mesmo número, seja qual for a ordem do CSV do dia.
    ordem smallint NOT NULL DEFAULT 0,
    _dados_brutos jsonb,
    _hash_linha text NOT NULL,
    _data_extracao timestamptz NOT NULL DEFAULT now(),
    _pagina integer,
    CONSTRAINT pk_mdnet_cdr PRIMARY KEY (_id_tecnico)
);

-- ===== Evolução do schema =====
-- Os CREATE TABLE são IF NOT EXISTS e não alteram tabela que já existe. A coluna
-- `ordem` entrou em 05/out/2026, depois da primeira carga, e a chave passou de
-- (protocolo, data_hora_inicio) para (protocolo, data_hora_inicio, ordem). A
-- coluna precisa existir ANTES do índice novo, e o índice antigo (mesmo nome, sem
-- `ordem`) precisa sair antes, porque CREATE INDEX IF NOT EXISTS pelo nome o
-- deixaria no lugar. As linhas já gravadas ficam com ordem 0, que é o certo.
ALTER TABLE bronze.mdnet_cdr ADD COLUMN IF NOT EXISTS ordem smallint NOT NULL DEFAULT 0;
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'bronze' AND indexname = 'ux_mdnet_cdr_chave'
          AND indexdef NOT LIKE '%ordem%'
    ) THEN
        DROP INDEX bronze.ux_mdnet_cdr_chave;
    END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS ux_mdnet_cdr_chave ON bronze.mdnet_cdr (protocolo, data_hora_inicio, ordem);
CREATE INDEX IF NOT EXISTS ix_mdnet_cdr_data_hora_inicio ON bronze.mdnet_cdr (data_hora_inicio);
CREATE INDEX IF NOT EXISTS ix_mdnet_cdr_direcao ON bronze.mdnet_cdr (direcao);
CREATE INDEX IF NOT EXISTS ix_mdnet_cdr_ramal ON bronze.mdnet_cdr (ramal);

-- ===== mdnet_cdr_pernas =====
-- Uma linha por PERNA que o painel devolve quando o relatório é filtrado por direção.
-- Existe porque o CSV sem filtro mostra uma perna por ligação (em geral a de Entrada) e
-- esconde as outras: uma ligação de entrada encaminhada para um número de fora tem uma
-- perna inbound e uma outbound, e o sem filtro só traz uma. Medido em 05/out/2026: o
-- filtro outbound devolveu 2.145 linhas, 1.469 já na mdnet_cdr como Saída e 675 com a
-- mesma chave de linhas que a mdnet_cdr guarda como Entrada (655) ou Interna (20).
--
-- A chave de negócio é a da mdnet_cdr mais `filtro_direcao`: a mesma ligação aparece uma
-- vez por filtro em que tem perna. Quem junta as pernas com a ligação é a silver, por
-- (protocolo, data_hora_inicio).
CREATE TABLE IF NOT EXISTS bronze.mdnet_cdr_pernas (
    _id_tecnico bigint GENERATED ALWAYS AS IDENTITY,
    protocolo text NOT NULL,
    estado text,
    direcao text,
    tipo text,
    nome text,
    origem text,
    destino text,
    ramal text,
    data_hora_inicio timestamp NOT NULL,
    hora_fim timestamp,
    tempo_falado text,
    tipo_transferencia text,
    transferido_de_para text,
    motivo_desligamento text,
    lado_desligamento text,
    -- Mesmo desempate da mdnet_cdr, numerado dentro de cada (dia, filtro) exportado.
    ordem smallint NOT NULL DEFAULT 0,
    -- inbound, outbound ou internal: o valor de DIRECTION[] com que o painel devolveu a linha.
    filtro_direcao text NOT NULL,
    _dados_brutos jsonb,
    _hash_linha text NOT NULL,
    _data_extracao timestamptz NOT NULL DEFAULT now(),
    _pagina integer,
    CONSTRAINT pk_mdnet_cdr_pernas PRIMARY KEY (_id_tecnico)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_mdnet_cdr_pernas_chave ON bronze.mdnet_cdr_pernas (protocolo, data_hora_inicio, filtro_direcao, ordem);
CREATE INDEX IF NOT EXISTS ix_mdnet_cdr_pernas_data_hora_inicio ON bronze.mdnet_cdr_pernas (data_hora_inicio);
CREATE INDEX IF NOT EXISTS ix_mdnet_cdr_pernas_protocolo ON bronze.mdnet_cdr_pernas (protocolo);
