-- Schema integracao: integracao bidirecional CVCRM <-> GoHighLevel (GHL).
--
-- Fase 1 do plano de migracao (dbt-core + Airflow + integracao GHL), construida
-- antes da fundacao nova existir. Por isso toda a logica de decisao mora aqui, em
-- SQL puro, e nao em models do dbt: quando a fundacao chegar (Fase 5), esses
-- mesmos objetos migram quase sem reescrever, so trocando FROM integracao.x por
-- ref('x').
--
-- O n8n (ver integracao_ghl_cvcrm/workflow_n8n.json) e so a porta de entrada e
-- saida: recebe webhook, grava na fila, despacha o que este schema decidir que
-- deve ser despachado. Nenhuma regra de negocio fica em no Code do n8n.
--
-- pgcrypto e usado so pela funcao de hash (deteccao de eco); nao guarda segredo
-- nenhum, so evita reescrever sha256 a mao em PL/pgSQL.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS integracao;

-- =============================================================================
-- Tabelas
-- =============================================================================

-- De-para de contato: uma linha por pessoa, cruzando os dois lados pela chave de
-- match (telefone normalizado, com e-mail e CPF como reforco). E o equivalente,
-- para pessoas, do que os dpara_* da silver sao para gerentes/produtos/etc.
CREATE TABLE IF NOT EXISTS integracao.depara_contato (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    telefone_chave  text UNIQUE,           -- E.164, ex.: +5511999998888
    email           text,
    cpf             text,                  -- só dígitos
    idlead_cvcrm    text,
    id_contato_ghl  text,
    criado_em       timestamptz NOT NULL DEFAULT now(),
    atualizado_em   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_depara_contato_email ON integracao.depara_contato (email);
CREATE INDEX IF NOT EXISTS ix_depara_contato_cpf   ON integracao.depara_contato (cpf);

-- Dono do campo: por chave de campo do payload, quem tem autoridade para
-- escrever nele. Fica em tabela (não hardcoded), no mesmo espírito dos de-para
-- de planilha do resto do projeto: é regra de negócio, pode mudar sem deploy.
CREATE TABLE IF NOT EXISTS integracao.dono_campo (
    campo      text PRIMARY KEY,
    dono       text NOT NULL CHECK (dono IN ('ghl', 'cvcrm')),
    descricao  text
);
INSERT INTO integracao.dono_campo (campo, dono, descricao) VALUES
    ('tags',                     'ghl',   'Tags de marketing/nutrição'),
    ('etapa_funil_marketing',    'ghl',   'Etapa do funil de marketing'),
    ('origem_campanha',          'ghl',   'UTM / origem de campanha'),
    ('situacao_lead',            'cvcrm', 'Situação comercial do lead no CRM'),
    ('corretor_responsavel',     'cvcrm', 'Corretor responsável pelo atendimento'),
    ('empreendimento_interesse', 'cvcrm', 'Empreendimento de interesse')
ON CONFLICT (campo) DO NOTHING;
-- Ajustar essa lista é o primeiro passo antes de ligar o fluxo de verdade: os
-- nomes de campo aqui são um ponto de partida razoável, não confirmados contra
-- o payload real de nenhuma das duas plataformas ainda.

-- Fila (outbox) de eventos recebidos por webhook, pendentes de decisão/despacho.
CREATE TABLE IF NOT EXISTS integracao.fila_sync (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    origem         text NOT NULL CHECK (origem IN ('ghl', 'cvcrm')),
    tipo_evento    text NOT NULL,          -- ex.: contact.created, lead.situacao_alterada
    contato_id     bigint REFERENCES integracao.depara_contato(id),
    telefone_bruto text,
    email_bruto    text,
    cpf_bruto      text,
    campos         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- só os campos que mudaram
    hash_evento    text,                   -- preenchido pelo trigger abaixo
    status         text NOT NULL DEFAULT 'pendente'
                       CHECK (status IN ('pendente', 'processado', 'erro', 'descartado')),
    tentativas     int NOT NULL DEFAULT 0,
    criado_em      timestamptz NOT NULL DEFAULT now(),
    processado_em  timestamptz,
    erro_msg       text
);
CREATE INDEX IF NOT EXISTS ix_fila_sync_status ON integracao.fila_sync (status, criado_em);
CREATE INDEX IF NOT EXISTS ix_fila_sync_contato ON integracao.fila_sync (contato_id);

-- Log (auditoria) do que foi de fato escrito no destino: é contra isto que a
-- detecção de eco compara o hash de um evento recém-chegado.
CREATE TABLE IF NOT EXISTS integracao.log_sync (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fila_sync_id     bigint REFERENCES integracao.fila_sync(id),
    contato_id       bigint REFERENCES integracao.depara_contato(id),
    destino          text NOT NULL CHECK (destino IN ('ghl', 'cvcrm')),
    campos_enviados  jsonb NOT NULL,
    hash_evento      text NOT NULL,
    status           text NOT NULL CHECK (status IN ('enviado', 'erro')),
    criado_em        timestamptz NOT NULL DEFAULT now(),
    detalhe          text
);
CREATE INDEX IF NOT EXISTS ix_log_sync_contato_destino ON integracao.log_sync (contato_id, destino, criado_em DESC);

-- =============================================================================
-- Funções
-- =============================================================================

-- Normaliza telefone para E.164 (assume Brasil: DDI 55). Tolerante a máscara,
-- espaço, parênteses e DDI já presente ou ausente.
CREATE OR REPLACE FUNCTION integracao.normalizar_telefone(bruto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN bruto IS NULL OR btrim(bruto) = '' THEN NULL
        ELSE '+' || CASE
            WHEN regexp_replace(bruto, '\D', '', 'g') ~ '^55\d{10,11}$'
                THEN regexp_replace(bruto, '\D', '', 'g')
            WHEN length(regexp_replace(bruto, '\D', '', 'g')) IN (10, 11)
                THEN '55' || regexp_replace(bruto, '\D', '', 'g')
            ELSE regexp_replace(bruto, '\D', '', 'g')
        END
    END;
$$;

-- Hash estável de um conjunto de campos (chave:valor, ordenado por chave), usado
-- tanto para gravar o que foi enviado (log_sync) quanto para comparar um evento
-- recebido contra o último envio (detecção de eco). Hashear campos específicos,
-- em vez do jsonb bruto, evita falso-negativo por ordem de chave diferente entre
-- requisições equivalentes.
CREATE OR REPLACE FUNCTION integracao.calcular_hash_evento(p_campos jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT encode(
        digest(
            COALESCE(
                (SELECT string_agg(chave || ':' || COALESCE(p_campos ->> chave, ''), '|' ORDER BY chave)
                   FROM jsonb_object_keys(p_campos) AS chave),
                ''
            ),
            'sha256'
        ),
        'hex'
    );
$$;

-- Acha (por telefone > e-mail > CPF, nessa ordem de prioridade) ou cria o
-- contato correspondente em depara_contato, e devolve o id. Chamada pelo
-- trigger de fila_sync; não precisa ser chamada à mão.
CREATE OR REPLACE FUNCTION integracao.resolver_contato(
    p_telefone       text,
    p_email          text,
    p_cpf            text,
    p_idlead_cvcrm   text DEFAULT NULL,
    p_id_contato_ghl text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_telefone_chave text := integracao.normalizar_telefone(p_telefone);
    v_email          text := NULLIF(lower(btrim(p_email)), '');
    v_cpf            text := NULLIF(regexp_replace(COALESCE(p_cpf, ''), '\D', '', 'g'), '');
    v_id             bigint;
BEGIN
    SELECT id INTO v_id
      FROM integracao.depara_contato
     WHERE (v_telefone_chave IS NOT NULL AND telefone_chave = v_telefone_chave)
        OR (v_email IS NOT NULL AND email = v_email)
        OR (v_cpf IS NOT NULL AND cpf = v_cpf)
     ORDER BY (telefone_chave = v_telefone_chave) DESC NULLS LAST
     LIMIT 1;

    IF v_id IS NULL THEN
        INSERT INTO integracao.depara_contato
            (telefone_chave, email, cpf, idlead_cvcrm, id_contato_ghl)
        VALUES
            (v_telefone_chave, v_email, v_cpf, p_idlead_cvcrm, p_id_contato_ghl)
        RETURNING id INTO v_id;
    ELSE
        UPDATE integracao.depara_contato
           SET telefone_chave = COALESCE(v_telefone_chave, telefone_chave),
               email          = COALESCE(v_email, email),
               cpf            = COALESCE(v_cpf, cpf),
               idlead_cvcrm   = COALESCE(p_idlead_cvcrm, idlead_cvcrm),
               id_contato_ghl = COALESCE(p_id_contato_ghl, id_contato_ghl),
               atualizado_em  = now()
         WHERE id = v_id;
    END IF;

    RETURN v_id;
END;
$$;

-- Preenche contato_id e hash_evento automaticamente em todo INSERT em
-- fila_sync. É o que permite o n8n só gravar os campos crus do webhook, sem
-- precisar chamar resolver_contato/calcular_hash_evento ele mesmo.
CREATE OR REPLACE FUNCTION integracao.preencher_fila_sync()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.contato_id := integracao.resolver_contato(
        NEW.telefone_bruto,
        NEW.email_bruto,
        NEW.cpf_bruto,
        CASE WHEN NEW.origem = 'cvcrm' THEN NEW.campos ->> 'idlead_cvcrm' END,
        CASE WHEN NEW.origem = 'ghl'   THEN NEW.campos ->> 'id_contato_ghl' END
    );
    NEW.hash_evento := integracao.calcular_hash_evento(NEW.campos);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_preencher_fila_sync ON integracao.fila_sync;
CREATE TRIGGER trg_preencher_fila_sync
    BEFORE INSERT ON integracao.fila_sync
    FOR EACH ROW EXECUTE FUNCTION integracao.preencher_fila_sync();

-- Marca o resultado do processamento de uma linha da fila. Chamada pelo n8n
-- depois de tentar despachar (sucesso, erro, ou descartada por ser eco).
CREATE OR REPLACE FUNCTION integracao.marcar_fila_processada(
    p_fila_sync_id bigint,
    p_status       text,
    p_erro_msg     text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE integracao.fila_sync
       SET status        = p_status,
           processado_em = now(),
           erro_msg      = p_erro_msg,
           tentativas    = tentativas + 1
     WHERE id = p_fila_sync_id;
END;
$$;

-- Registra um envio bem-sucedido (ou com erro) no log_sync. Chamada pelo n8n
-- logo após tentar despachar para a API de destino.
CREATE OR REPLACE FUNCTION integracao.registrar_envio(
    p_fila_sync_id bigint,
    p_contato_id   bigint,
    p_destino      text,
    p_campos       jsonb,
    p_hash         text,
    p_status       text,
    p_detalhe      text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO integracao.log_sync
        (fila_sync_id, contato_id, destino, campos_enviados, hash_evento, status, detalhe)
    VALUES
        (p_fila_sync_id, p_contato_id, p_destino, p_campos, p_hash, p_status, p_detalhe);
END;
$$;

-- =============================================================================
-- View de despacho
-- =============================================================================

-- O que o Schedule Trigger do n8n consulta. Já resolve, em SQL: (a) pra qual
-- plataforma despachar (o inverso da origem), (b) só os campos que a origem tem
-- autoridade para escrever (dono_campo), e (c) se é eco de um envio nosso
-- anterior (comparando o hash contra o último log_sync no mesmo sentido).
-- O n8n só decide "descarta se eh_eco, senão despacha campos_permitidos".
CREATE OR REPLACE VIEW integracao.v_fila_para_despachar AS
SELECT
    f.id AS fila_sync_id,
    f.contato_id,
    c.idlead_cvcrm,
    c.id_contato_ghl,
    f.origem,
    CASE WHEN f.origem = 'ghl' THEN 'cvcrm' ELSE 'ghl' END AS destino,
    COALESCE(
        (SELECT jsonb_object_agg(chave, f.campos -> chave)
           FROM jsonb_object_keys(f.campos) AS chave
           JOIN integracao.dono_campo dc ON dc.campo = chave AND dc.dono = f.origem),
        '{}'::jsonb
    ) AS campos_permitidos,
    f.hash_evento,
    f.tentativas,
    f.criado_em,
    EXISTS (
        SELECT 1
          FROM integracao.log_sync l
         WHERE l.contato_id = f.contato_id
           AND l.destino = f.origem  -- alguma vez já escrevemos no lado de onde este evento chegou?
    ) AS tem_envio_anterior,
    EXISTS (
        SELECT 1
          FROM integracao.log_sync l
         WHERE l.contato_id = f.contato_id
           AND l.destino = f.origem
           AND l.hash_evento = f.hash_evento
    ) AS eh_eco
FROM integracao.fila_sync f
LEFT JOIN integracao.depara_contato c ON c.id = f.contato_id
WHERE f.status = 'pendente'
ORDER BY f.criado_em ASC;

COMMENT ON VIEW integracao.v_fila_para_despachar IS
    'Fila pronta para despacho: destino resolvido, campos filtrados por dono_campo, eco detectado. Fase 5 migra isto para um model dbt sem mudar a lógica.';
