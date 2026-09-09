-- DDL da camada bronze para os dados de atendimento do Blip.
--
-- Diferente do bronze.sql, este arquivo é escrito à mão e não gerado. O
-- gerar_ddl_bronze.py monta o schema a partir da descoberta da API do CVDW, que
-- tem centenas de campos por objeto; o Blip são três objetos pequenos e de
-- schema estável, então nomear as colunas à mão sai mais legível (`sequential_id`
-- em vez de `sequentialid`) e serve de documentação da fonte.
--
-- As colunas foram modeladas a partir da descoberta de 09/set/2026
-- (explorar_blip.py), sobre uma amostra de 200 tickets, 10 filas e 26
-- atendentes. Como a amostra não cobre os ~52 mil tickets da base, cada tabela
-- guarda também o JSON cru em `_dados_brutos`: se o Blip passar a devolver um
-- campo novo, ele não se perde enquanto ninguém adiciona a coluna.

CREATE SCHEMA IF NOT EXISTS bronze;

-- A tabela de controle é a mesma do CVDW (bronze._ingestao_controle), de
-- propósito: uma consulta só responde "tudo carregou hoje?" para as duas
-- fontes. Ela é criada por cvdw.db.garantir_schema_e_controle.

-- ===== blip_tickets =====
-- Um ticket é um atendimento humano. É o fato central da volumetria.
CREATE TABLE IF NOT EXISTS bronze.blip_tickets (
    _id_tecnico bigint GENERATED ALWAYS AS IDENTITY,
    -- Chave de negócio: número sequencial do ticket, legível e estável.
    sequential_id bigint,
    -- Quando o atendimento é transferido, o novo ticket aponta para o anterior.
    -- Sem tratar isso, uma transferência conta como dois atendimentos.
    parent_sequential_id bigint,
    id text,
    external_id text,
    owner_identity text,
    -- Identidade tunelada do cliente (...@tunnel.msging.net). Não é o telefone:
    -- o número não é exposto por esta API. Ainda assim é dado pessoal
    -- pseudonimizado, e o canal real fica em customer_domain.
    customer_identity text,
    customer_domain text,
    -- Vem URL-encoded ("nome%40pafil.com.br@blip.ai"). A decodificação para
    -- casar com blip_attendants.email é trabalho da silver, não da bronze.
    agent_identity text,
    closed_by text,
    -- Nome da fila. O /teams não expõe id, então o nome é a única chave de join.
    team text,
    status text,
    closed boolean,
    priority integer,
    -- Avaliação do atendimento. Veio 0 em 100% da amostra, o que sugere recurso
    -- não usado; confirmar antes de construir qualquer métrica de satisfação.
    rating integer,
    unread_messages integer,
    -- Momento em que o ticket foi criado. NÃO se move quando o ticket é
    -- atualizado ou fechado (medido: storage_date < open_date < close_date no
    -- mesmo ticket), e é por isso que a carga incremental usa uma janela de
    -- vários dias em vez de só o delta desde a última execução.
    storage_date timestamptz,
    open_date timestamptz,
    close_date timestamptz,
    first_response_date timestamptz,
    status_date timestamptz,
    -- Tempo médio de resposta do agente, em segundos, já calculado pelo Blip.
    average_agent_response_time numeric,
    distribution_type text,
    is_automatic_distribution boolean,
    -- Veio "Lime" em 100% da amostra. Guardado como coluna não por valor
    -- analítico, mas porque a alternativa era o aviso de drift disparar em toda
    -- execução, para sempre, por um campo que já sabemos que existe. Aviso que
    -- toca todo dia é aviso que ninguém lê.
    provider text,
    campaign_id text,
    -- Lista de tags. Na Pafil elas carregam o código do empreendimento
    -- ("PDP - Parc das Primaveras RP"), que é o que liga o atendimento à gold.
    tags jsonb,
    _dados_brutos jsonb,
    _hash_linha text NOT NULL,
    _data_extracao timestamptz NOT NULL DEFAULT now(),
    _pagina integer,
    CONSTRAINT pk_blip_tickets PRIMARY KEY (_id_tecnico)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_blip_tickets_chave ON bronze.blip_tickets (sequential_id);
CREATE INDEX IF NOT EXISTS ix_blip_tickets_storage_date ON bronze.blip_tickets (storage_date);
CREATE INDEX IF NOT EXISTS ix_blip_tickets_close_date ON bronze.blip_tickets (close_date);
CREATE INDEX IF NOT EXISTS ix_blip_tickets_team ON bronze.blip_tickets (team);
CREATE INDEX IF NOT EXISTS ix_blip_tickets_agent ON bronze.blip_tickets (agent_identity);
CREATE INDEX IF NOT EXISTS ix_blip_tickets_status ON bronze.blip_tickets (status);

-- Não existe blip_tickets_snapshot, e isso é decisão, não esquecimento. O
-- snapshot diário do CVDW existe para tabelas em que o estado atual sobrescreve
-- o anterior sem deixar rastro. Aqui o ticket já carrega a própria história nas
-- datas (open/first_response/close/status), e um snapshot diário de 52 mil
-- linhas somaria perto de 19 milhões de linhas por ano para responder o que as
-- datas já respondem.

-- ===== blip_teams =====
-- Filas de atendimento. Dimensão pequena (10 linhas na descoberta).
CREATE TABLE IF NOT EXISTS bronze.blip_teams (
    _id_tecnico bigint GENERATED ALWAYS AS IDENTITY,
    name text,
    -- Quantos agentes estão online NESTE INSTANTE. É medição de momento, não
    -- histórico: só faz sentido em série temporal via a tabela de snapshot.
    agents_online integer,
    _dados_brutos jsonb,
    _hash_linha text NOT NULL,
    _data_extracao timestamptz NOT NULL DEFAULT now(),
    _pagina integer,
    CONSTRAINT pk_blip_teams PRIMARY KEY (_id_tecnico)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_blip_teams_chave ON bronze.blip_teams (name);

CREATE TABLE IF NOT EXISTS bronze.blip_teams_snapshot (
    _id_snapshot bigint GENERATED ALWAYS AS IDENTITY,
    _data_snapshot date NOT NULL DEFAULT CURRENT_DATE,
    name text,
    agents_online integer,
    _dados_brutos jsonb,
    _hash_linha text,
    _data_extracao timestamptz,
    _pagina integer,
    CONSTRAINT pk_blip_teams_snapshot PRIMARY KEY (_id_snapshot)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_blip_teams_snapshot_dia ON bronze.blip_teams_snapshot (_data_snapshot, name);
CREATE INDEX IF NOT EXISTS ix_blip_teams_snapshot_data ON bronze.blip_teams_snapshot (_data_snapshot);

-- ===== blip_attendants =====
-- Atendentes. Dimensão pequena (26 linhas na descoberta).
CREATE TABLE IF NOT EXISTS bronze.blip_attendants (
    _id_tecnico bigint GENERATED ALWAYS AS IDENTITY,
    -- Chave: mesma forma URL-encoded que aparece em blip_tickets.agent_identity,
    -- então o join com o ticket é direto, sem normalizar nada na bronze.
    identity text,
    email text,
    full_name text,
    is_enabled boolean,
    -- Online/Offline no instante da coleta. Mesmo caso do agents_online.
    status text,
    -- Lista de nomes de fila. Um atendente pode estar em mais de uma.
    teams jsonb,
    _dados_brutos jsonb,
    _hash_linha text NOT NULL,
    _data_extracao timestamptz NOT NULL DEFAULT now(),
    _pagina integer,
    CONSTRAINT pk_blip_attendants PRIMARY KEY (_id_tecnico)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_blip_attendants_chave ON bronze.blip_attendants (identity);

CREATE TABLE IF NOT EXISTS bronze.blip_attendants_snapshot (
    _id_snapshot bigint GENERATED ALWAYS AS IDENTITY,
    _data_snapshot date NOT NULL DEFAULT CURRENT_DATE,
    identity text,
    email text,
    full_name text,
    is_enabled boolean,
    status text,
    teams jsonb,
    _dados_brutos jsonb,
    _hash_linha text,
    _data_extracao timestamptz,
    _pagina integer,
    CONSTRAINT pk_blip_attendants_snapshot PRIMARY KEY (_id_snapshot)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_blip_attendants_snapshot_dia ON bronze.blip_attendants_snapshot (_data_snapshot, identity);
CREATE INDEX IF NOT EXISTS ix_blip_attendants_snapshot_data ON bronze.blip_attendants_snapshot (_data_snapshot);

-- ===== Evolução do schema =====
-- Os CREATE TABLE acima são IF NOT EXISTS, então não alteram tabela que já
-- existe: numa base já criada, coluna nova só entra por ALTER. Toda vez que um
-- campo sair do aviso de drift e virar coluna, ele entra nos dois lugares, no
-- CREATE (para instalação nova) e aqui (para as que já rodaram).
ALTER TABLE bronze.blip_tickets ADD COLUMN IF NOT EXISTS provider text;
