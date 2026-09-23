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
-- Adicionada 23/set/2026: guarda o id da ultima interacao (anotacao) do CVCRM
-- ja processada por contato. Necessario porque o gatilho "Nova interacao" do
-- CVCRM nao dispara de verdade (confirmado ao vivo -- nenhuma anotacao de
-- teste chamou o webhook); em vez disso, a interacao mais recente vem de
-- carona em QUALQUER evento do CVCRM que ja funciona (Associar Atendente,
-- mudanca de situacao etc.), porque "Buscar lead CVCRM" sempre busca o lead
-- inteiro. Sem esse controle, a mesma anotacao antiga seria reenviada como
-- nota nova no GHL toda vez que outro campo mudasse.
ALTER TABLE integracao.depara_contato ADD COLUMN IF NOT EXISTS ultima_interacao_id_cvcrm bigint;

-- Dono do campo: por chave de campo do payload, quem tem autoridade para
-- escrever nele. Fica em tabela (não hardcoded), no mesmo espírito dos de-para
-- de planilha do resto do projeto: é regra de negócio, pode mudar sem deploy.
CREATE TABLE IF NOT EXISTS integracao.dono_campo (
    campo      text PRIMARY KEY,
    dono       text NOT NULL CHECK (dono IN ('ghl', 'cvcrm')),
    descricao  text
);
-- campo_destino entrou depois (18/set/2026): CREATE TABLE IF NOT EXISTS não
-- altera uma tabela que já existe, então precisa do ALTER explícito para
-- quem já rodou a versão anterior deste script.
ALTER TABLE integracao.dono_campo ADD COLUMN IF NOT EXISTS campo_destino text;  -- chave/id do campo real na plataforma de DESTINO (a outra). NULL = ainda sem mapeamento confirmado, fica de fora do despacho.
INSERT INTO integracao.dono_campo (campo, dono, campo_destino, descricao) VALUES
    ('tags',                     'ghl',   'tags',
        'Tags de marketing. GHL: array nativo. CVCRM: campo tags real, mas em string separada por vírgula (confirmado 18/set/2026) -- conversão de formato fica no n8n.'),
    ('origem_campanha',          'cvcrm', 'X9HoukgKTYlebZNCSyvA',
        'Decisão de negócio fechada em 21/set/2026: quem gerencia campanha e origem de lead é o CVCRM, não o GHL, então o dono é cvcrm (invertido do que estava antes). O campo origem do CVCRM é uma lista fechada de ~30 valores padronizados (Facebook, Google, Portais, Painel Gestor etc. -- não aceita texto livre), então não precisa de de-para: o valor passa direto pro GHL, que aceita texto livre. Destino: Custom Field GHL "Midia CVCRM" (chave {{contact.midia_cv}}), criado em 28/mai/2026 junto com os outros três, mas nunca usado até agora.'),
    ('situacao_lead',            'ghl',   'idsituacao',
        'Invertido em 22/set/2026 (decisão de negócio: GHL vira a fonte de verdade de onde o lead está, situação do CVCRM passa a refletir o estágio do pipeline "Pipeline de Leads" no GHL -- os 11 nomes de etapa são idênticos, na mesma ordem, dos dois lados, então o de-para é por ID de estágio, ver integracao.depara_situacao_ghl). Destino = campo idsituacao no corpo do POST /api/v1/comercial/leads do CVCRM (confirmado contra a API real: aceita qualquer id de situação, sem exigir ordem sequencial, diferente da tela). Antes disso, o campo era dono-CVCRM, indo pro Custom Field "Situacao Lead CV" no GHL (contact.situacao_lead_cv) -- esse Custom Field fica sem uso a partir de agora, a menos que seja reaproveitado depois.'),
    ('corretor_responsavel',     'cvcrm', 'MzBSUBH8ttuLVPCX16JU',
        'Nome do corretor responsável (texto, não o idcorretor -- decisão de 18/set/2026). Destino = Custom Field "Nome Corretor CVCRM" no GHL (contact.nome_corretor_cvcrm), criado em 18/set/2026 especificamente para isto (já existia um "ID Corretor CVCRM" com outro propósito).'),
    ('empreendimento_interesse', 'cvcrm', 'VU4yvq6ZFoJkAhzJhS26',
        'Destino = Custom Field "Empreendimento CV" no GHL (contact.empreendimento_cv), já existia na sub-account desde 28/mai/2026.'),
    ('nota_ghl',                 'ghl',   'interacoes',
        'Adicionado 23/set/2026: nota/observação da aba "Notas" do contato no GHL, virando interação no CVCRM. Nota não é um campo simples -- campo_destino "interacoes" não é uma chave de corpo comum, é um marcador especial que o node Enviar CVCRM trata separado (empacota como [{tipo: ''A'', descricao: valor}], formato exigido pela API). Escopado ao piloto (tag piloto-fiusa016-set2026 no gatilho do GHL), porque mandar interação pra um lead sem idlead_cvcrm resolvido corre o mesmo risco do incidente do lead 105112 (CVCRM cria lead novo em vez de falhar).'),
    ('interacao_cvcrm',          'cvcrm', 'nota_ghl',
        'Adicionado 23/set/2026: interação/anotação do CVCRM virando nota na aba "Notas" do contato no GHL. campo_destino "nota_ghl" também é um marcador especial (não é um Custom Field ID) -- o desvio "Tem nota pra criar?" detecta essa chave e roteia pro node "Criar nota GHL" (POST /contacts/:id/notes), em vez de seguir pro "Enviar GHL" (PUT customFields).'),
    ('tarefa_cvcrm',              'cvcrm', 'tarefa_ghl',
        'Adicionado 23/set/2026: tarefa criada no lead do CVCRM (aba "Tarefa") virando Task no GHL. Só direção CVCRM->GHL por enquanto -- o gatilho "Nova tarefa" do CVCRM funciona de verdade (diferente de "Nova interação") e manda idtarefa direto no corpo do webhook, sem precisar de piggyback/dedup. campo_destino "tarefa_ghl" é marcador especial (não é Custom Field ID) -- o desvio "Tem tarefa pra criar?" roteia pro node "Criar tarefa GHL" (POST /contacts/:id/tasks). Direção contrária (GHL->CVCRM) fica pendente: não achamos o endpoint de criação de tarefa no CVCRM ainda, ver RUNBOOK.md.')
ON CONFLICT (campo) DO UPDATE SET dono = EXCLUDED.dono, campo_destino = EXCLUDED.campo_destino, descricao = EXCLUDED.descricao;
-- Achado em 18/set/2026: a sub-account do GHL já tinha, desde 28/mai/2026, um
-- conjunto de Custom Fields pensados especificamente para uma integração com o
-- CVCRM (situacao_lead_cv, empreendimento_cv, midia_cv, idcorretor_cv,
-- idlead_cv, idreserva_cv, idimobiliaria_cv, idprecadastro_cv, cpf_cv, entre
-- outros) -- alguem ja tinha planejado isso antes deste projeto. Usamos os que
-- fazem sentido pro escopo atual (lead); o resto fica disponivel pra quando o
-- escopo crescer (reserva, pre-cadastro).
--
-- Do lado CVCRM, os nomes internos (situacao_lead/corretor_responsavel/
-- empreendimento_interesse) correspondem as colunas situacao/corretor/
-- empreendimento_ultimo de bronze.leads (confirmado contra a API real em
-- 18/set/2026), mas o ENVIO pra dentro do CVCRM (a direcao ghl->cvcrm) ainda
-- não foi confirmado contra a API de escrita -- só a leitura foi validada.

-- De-para de estágio do pipeline "Pipeline de Leads" do GHL (locationId
-- QKKhoj5ZU9PHD4j66T0E, pipeline Sc3mUXtldce6M594bWXP) para o idsituacao do
-- CVCRM. Os dois lados usam os mesmos 11 nomes de etapa, na mesma ordem --
-- alguém já desenhou o pipeline do GHL pra espelhar a esteira do CVCRM antes
-- deste projeto -- então o de-para é 1:1 por nome, confirmado contra as duas
-- APIs reais em 22/set/2026. idsituacao 1 x 11 ("Aguardando Atendimento SDR"
-- duplicado no CVCRM): testado ao vivo contra a API, 1 é o correto (11 deve
-- ser um código legado/duplicado, não usado).
CREATE TABLE IF NOT EXISTS integracao.depara_situacao_ghl (
    pipeline_stage_id_ghl text PRIMARY KEY,
    idsituacao_cvcrm      int NOT NULL,
    nome                  text NOT NULL
);
INSERT INTO integracao.depara_situacao_ghl (pipeline_stage_id_ghl, idsituacao_cvcrm, nome) VALUES
    ('961f8977-ad8a-41fd-9232-16fcccb9a6ca', 1,  'Aguardando Atendimento SDR'),
    ('039ccdac-b4df-4e27-aa6a-7b0b15ea9082', 13, 'Aguardando Resposta Cliente SDR'),
    ('ba2efb8c-9a23-4268-b14b-190761fbc4d4', 12, 'Atendimento SDR'),
    ('2ce763b7-85fc-4006-b3eb-089c234736b7', 14, 'Interesse SDR'),
    ('8b12d6de-6624-4111-a0bd-c6892508d9c7', 2,  'Aguardando Atendimento'),
    ('fbeff8d6-18cf-42a1-b072-7e8e52ea60fc', 4,  'Em Contato'),
    ('b456172f-1d97-428a-a0be-b96223bc1db7', 8,  'Em Negociação'),
    ('4d1ceb68-40d5-41ef-b3b6-1e40b04b3ba2', 7,  'Em Análise de Crédito'),
    ('94f15eb2-9b02-4872-b580-63430dc1b11e', 5,  'Com Reserva'),
    ('c2e1084d-a95c-4133-8d63-984d0ce13250', 6,  'Venda Realizada'),
    ('4f87718b-8e60-4ce6-8792-006c8655403a', 3,  'Perdido')
ON CONFLICT (pipeline_stage_id_ghl) DO UPDATE SET idsituacao_cvcrm = EXCLUDED.idsituacao_cvcrm, nome = EXCLUDED.nome;

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
--
-- Dedup de interacao_cvcrm (23/set/2026): interacao_cvcrm/interacao_cvcrm_id
-- chegam em TODO evento do CVCRM (Buscar lead CVCRM sempre busca o lead
-- inteiro), nao so quando uma anotacao nova e' criada -- ver comentario em
-- depara_contato.ultima_interacao_id_cvcrm. Se o id nao for mais novo que o
-- ja visto pra esse contato, interacao_cvcrm sai de NEW.campos antes do hash,
-- pra nao reenviar a mesma nota de novo no GHL. interacao_cvcrm_id nunca vai
-- pro dono_campo (nao e' um campo que se despacha, so controle), entao fica
-- em campos so pra auditoria.
--
-- Eco de nota/interacao por TEXTO (23/set/2026, incidente ao vivo): o
-- eh_eco generico (em v_fila_para_despachar) compara o hash de TODOS os
-- campos entre origem e destino, e nunca bate pra esse par -- nota_ghl vem
-- sozinho, interacao_cvcrm vem junto de corretor/empreendimento/origem, a
-- forma nunca e' igual dos dois lados. Sem checagem dedicada, uma nota
-- criada de um lado ecoa pro outro, que ecoa de volta, infinitamente (visto
-- ao vivo: uma unica "oi" virou 4 notas/interacoes duplicadas em ~16min,
-- uma a cada ciclo de despacho, ate o node de despacho ser desativado a
-- mao). Aqui a comparacao e' por TEXTO contra o log_sync mais recente na
-- direcao correspondente: se o texto que chegou e' exatamente o que a gente
-- mesmo acabou de escrever no destino por ultimo, e' eco, nao repropaga.
CREATE OR REPLACE FUNCTION integracao.preencher_fila_sync()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_interacao_id      bigint;
    v_ultima_interacao  bigint;
    v_ultimo_enviado    text;
BEGIN
    NEW.contato_id := integracao.resolver_contato(
        NEW.telefone_bruto,
        NEW.email_bruto,
        NEW.cpf_bruto,
        CASE WHEN NEW.origem = 'cvcrm' THEN NEW.campos ->> 'idlead_cvcrm' END,
        CASE WHEN NEW.origem = 'ghl'   THEN NEW.campos ->> 'id_contato_ghl' END
    );

    IF NEW.origem = 'cvcrm' AND NEW.campos ? 'interacao_cvcrm_id' THEN
        v_interacao_id := NULLIF(NEW.campos ->> 'interacao_cvcrm_id', '')::bigint;

        SELECT ultima_interacao_id_cvcrm INTO v_ultima_interacao
          FROM integracao.depara_contato
         WHERE id = NEW.contato_id;

        IF v_interacao_id IS NULL
           OR (v_ultima_interacao IS NOT NULL AND v_interacao_id <= v_ultima_interacao) THEN
            NEW.campos := NEW.campos - 'interacao_cvcrm';
        ELSE
            UPDATE integracao.depara_contato
               SET ultima_interacao_id_cvcrm = v_interacao_id
             WHERE id = NEW.contato_id;
        END IF;
    END IF;

    IF NEW.origem = 'ghl' AND NEW.campos ? 'nota_ghl' THEN
        SELECT l.campos_enviados ->> 'interacoes' INTO v_ultimo_enviado
          FROM integracao.log_sync l
         WHERE l.contato_id = NEW.contato_id AND l.destino = 'cvcrm'
         ORDER BY l.criado_em DESC
         LIMIT 1;

        IF v_ultimo_enviado IS NOT NULL AND v_ultimo_enviado = (NEW.campos ->> 'nota_ghl') THEN
            NEW.campos := NEW.campos - 'nota_ghl';
        END IF;
    END IF;

    IF NEW.origem = 'cvcrm' AND NEW.campos ? 'interacao_cvcrm' THEN
        SELECT l.campos_enviados ->> 'nota_ghl' INTO v_ultimo_enviado
          FROM integracao.log_sync l
         WHERE l.contato_id = NEW.contato_id AND l.destino = 'ghl'
         ORDER BY l.criado_em DESC
         LIMIT 1;

        IF v_ultimo_enviado IS NOT NULL AND v_ultimo_enviado = (NEW.campos ->> 'interacao_cvcrm') THEN
            NEW.campos := NEW.campos - 'interacao_cvcrm';
        END IF;
    END IF;

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
-- autoridade para escrever E que já têm mapeamento confirmado pro campo real
-- do destino (dono_campo.campo_destino IS NOT NULL -- um campo sem destino
-- mapeado fica de fora do despacho de propósito, em vez de mandar lixo), e
-- (c) se é eco de um envio nosso anterior (hash contra o último log_sync no
-- mesmo sentido). campos_permitidos já sai no formato do CAMPO REAL do
-- destino (não no nome interno), então o n8n só decide "descarta se eh_eco,
-- senão despacha campos_permitidos direto no corpo da API".
CREATE OR REPLACE VIEW integracao.v_fila_para_despachar AS
SELECT
    f.id AS fila_sync_id,
    f.contato_id,
    c.idlead_cvcrm,
    c.id_contato_ghl,
    f.origem,
    CASE WHEN f.origem = 'ghl' THEN 'cvcrm' ELSE 'ghl' END AS destino,
    COALESCE(
        (SELECT jsonb_object_agg(dc.campo_destino, f.campos -> chave)
           FROM jsonb_object_keys(f.campos) AS chave
           JOIN integracao.dono_campo dc ON dc.campo = chave AND dc.dono = f.origem
          WHERE dc.campo_destino IS NOT NULL),
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
    ) AS eh_eco,
    c.telefone_chave AS contato_telefone,  -- o CVCRM exige email OU telefone no corpo, mesmo numa edição.
    c.email           AS contato_email      -- no final da lista de propósito: CREATE OR REPLACE VIEW só aceita coluna nova no fim.
FROM integracao.fila_sync f
LEFT JOIN integracao.depara_contato c ON c.id = f.contato_id
WHERE f.status = 'pendente'
ORDER BY f.criado_em ASC;

COMMENT ON VIEW integracao.v_fila_para_despachar IS
    'Fila pronta para despacho: destino resolvido, campos filtrados por dono_campo, eco detectado. Fase 5 migra isto para um model dbt sem mudar a lógica.';

-- =============================================================================
-- Reconciliação (lado CVCRM): sem chamada de API nenhuma
-- =============================================================================

-- O CVDW já ingere `leads` de hora em hora (ver ingestao.py). Em vez de criar um
-- caminho de leitura próprio pra CVCRM, a reconciliação desse lado só compara o
-- que já está em bronze.leads contra o último estado que a integração já viu
-- daquele contato. Se divergir (ou nunca tiver visto), é sinal de que um webhook
-- foi perdido, e a linha entra na fila do mesmo jeito que um webhook entraria.
CREATE OR REPLACE VIEW integracao.v_reconciliacao_cvcrm AS
SELECT
    c.id                                                   AS contato_id,
    c.idlead_cvcrm,
    l.telefone                                             AS telefone_bruto,
    l.email                                                AS email_bruto,
    jsonb_build_object(
        'idlead_cvcrm',             l.idlead::text,
        'situacao_lead',            l.situacao,
        'corretor_responsavel',     l.corretor,
        'empreendimento_interesse', l.empreendimento_ultimo,
        'origem_campanha',          l.origem_nome
    )                                                      AS campos_candidatos,
    integracao.calcular_hash_evento(jsonb_build_object(
        'idlead_cvcrm',             l.idlead::text,
        'situacao_lead',            l.situacao,
        'corretor_responsavel',     l.corretor,
        'empreendimento_interesse', l.empreendimento_ultimo,
        'origem_campanha',          l.origem_nome
    ))                                                     AS hash_candidato,
    (
        SELECT f.hash_evento
          FROM integracao.fila_sync f
         WHERE f.contato_id = c.id AND f.origem = 'cvcrm'
         ORDER BY f.criado_em DESC
         LIMIT 1
    )                                                      AS hash_conhecido
FROM integracao.depara_contato c
JOIN bronze.leads l ON l.idlead::text = c.idlead_cvcrm
WHERE c.idlead_cvcrm IS NOT NULL
  -- Trava de seguranca adicionada em 22/set/2026, depois de um incidente real:
  -- o node Reconciliar CVCRM no n8n foi reativado sem querer (ou nunca ficou
  -- desativado de verdade) e, como essa view nao tinha filtro de
  -- empreendimento, varreu bronze.leads inteiro e criou ~90 contatos
  -- indevidos no GHL, fora do escopo do piloto. Restringir aqui, na propria
  -- view, garante que mesmo se o node for reativado por engano de novo, o
  -- dano fica contido ao piloto. Remover esse filtro (ou trocar por uma
  -- lista maior) so quando o escopo real da integracao for expandido pra
  -- alem do piloto FIUSA 016 (ver issue #30 no GitHub).
  AND l.empreendimento_ultimo = 'FIUSA 016';

COMMENT ON VIEW integracao.v_reconciliacao_cvcrm IS
    'Compara bronze.leads (ja ingerido pelo CVDW) contra o ultimo hash que a integracao conhece por contato. Base da funcao rodar_reconciliacao_cvcrm().';

-- Materializa a reconciliação: grava em fila_sync só os contatos cujo hash
-- mudou (ou nunca foi visto). Devolve quantas linhas novas foram criadas —
-- o n8n só precisa chamar isto e seguir o pipeline normal a partir daqui.
CREATE OR REPLACE FUNCTION integracao.rodar_reconciliacao_cvcrm()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
    v_inseridas int;
BEGIN
    WITH candidatos AS (
        SELECT * FROM integracao.v_reconciliacao_cvcrm
         WHERE hash_conhecido IS NULL OR hash_conhecido <> hash_candidato
    )
    INSERT INTO integracao.fila_sync (origem, tipo_evento, telefone_bruto, email_bruto, campos)
    SELECT 'cvcrm', 'reconciliacao', telefone_bruto, email_bruto, campos_candidatos
      FROM candidatos;
    GET DIAGNOSTICS v_inseridas = ROW_COUNT;
    RETURN v_inseridas;
END;
$$;

COMMENT ON FUNCTION integracao.rodar_reconciliacao_cvcrm() IS
    'Chamada pelo n8n (Gatilho reconciliacao). Insere em fila_sync um evento sintético para cada contato cujo estado no CVCRM (via bronze.leads, sem chamada de API) mudou desde o último evento que a integração conhece.';

-- =============================================================================
-- Reconciliação (lado GHL): precisa de chamada de API, feita pelo n8n
-- =============================================================================

-- Não existe um espelho local dos contatos do GHL (diferente do CVCRM, que já
-- tem bronze.leads via CVDW), então esta reconciliação depende do n8n buscar os
-- contatos atualizados recentemente na API e chamar esta função uma vez por
-- contato. A função só decide "isso já é conhecido, ou é novo?" -- a mesma
-- decisão que integracao.v_reconciliacao_cvcrm toma em SQL puro, só que aqui
-- alimentada por dado que chegou de fora, não de uma tabela local.
CREATE OR REPLACE FUNCTION integracao.registrar_reconciliacao_ghl(
    p_id_contato_ghl text,
    p_telefone       text,
    p_email          text,
    p_campos         jsonb
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_contato_id  bigint;
    v_hash_novo   text := integracao.calcular_hash_evento(p_campos);
    v_hash_antigo text;
BEGIN
    v_contato_id := integracao.resolver_contato(p_telefone, p_email, NULL, NULL, p_id_contato_ghl);

    SELECT f.hash_evento INTO v_hash_antigo
      FROM integracao.fila_sync f
     WHERE f.contato_id = v_contato_id AND f.origem = 'ghl'
     ORDER BY f.criado_em DESC
     LIMIT 1;

    IF v_hash_antigo IS NOT DISTINCT FROM v_hash_novo THEN
        RETURN false;  -- nada mudou desde o último evento conhecido
    END IF;

    INSERT INTO integracao.fila_sync (origem, tipo_evento, telefone_bruto, email_bruto, campos)
    VALUES ('ghl', 'reconciliacao', p_telefone, p_email, p_campos || jsonb_build_object('id_contato_ghl', p_id_contato_ghl));

    RETURN true;
END;
$$;

COMMENT ON FUNCTION integracao.registrar_reconciliacao_ghl(text, text, text, jsonb) IS
    'Chamada pelo n8n uma vez por contato retornado da busca de "atualizados recentemente" no GHL. Devolve true se gravou um evento novo em fila_sync, false se já era conhecido (nada a fazer).';
