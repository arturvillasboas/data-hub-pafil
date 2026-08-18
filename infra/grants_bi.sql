-- grants_bi.sql — permissão de LEITURA para o Power BI (role pafil_bi).
--
-- Etapa 7.5. Rodar DEPOIS de aplicar_tudo.py, porque concede sobre objetos que
-- só existem quando as camadas já foram criadas.
--
--   psql -d pafil_dw -U pafil_app -f infra/grants_bi.sql
--
-- Princípio: o Power BI lê a gold e nada mais. A silver entra só porque algumas
-- medidas de conferência ainda consultam os de-paras direto; a bronze fica de
-- fora de propósito — dado cru não é superfície de consumo, e é onde mora a PII
-- em estado bruto.
--
-- Idempotente: pode rodar de novo a cada vez que a gold ganhar tabela nova.
-- (Os ALTER DEFAULT PRIVILEGES cobrem o futuro; os GRANT cobrem o que já existe.)

\set ON_ERROR_STOP on

-- --- Acesso aos schemas ------------------------------------------------------
GRANT USAGE ON SCHEMA gold   TO pafil_bi;
GRANT USAGE ON SCHEMA silver TO pafil_bi;

-- --- Leitura no que já existe ------------------------------------------------
GRANT SELECT ON ALL TABLES    IN SCHEMA gold   TO pafil_bi;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA gold   TO pafil_bi;
GRANT SELECT ON ALL TABLES    IN SCHEMA silver TO pafil_bi;

-- --- Leitura no que for criado daqui pra frente ------------------------------
-- Sem isto, toda tabela nova da gold nasce invisível para o Power BI e o painel
-- quebra com "permission denied" depois de um deploy que parecia inofensivo.
ALTER DEFAULT PRIVILEGES FOR ROLE pafil_app IN SCHEMA gold
  GRANT SELECT ON TABLES TO pafil_bi;
ALTER DEFAULT PRIVILEGES FOR ROLE pafil_app IN SCHEMA silver
  GRANT SELECT ON TABLES TO pafil_bi;

-- --- Barreiras explícitas ----------------------------------------------------
REVOKE ALL ON SCHEMA bronze FROM pafil_bi;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- --- Conferência -------------------------------------------------------------
-- Deve listar as tabelas da gold/silver e NENHUMA da bronze.
SELECT table_schema, count(*) AS tabelas_legiveis
FROM information_schema.table_privileges
WHERE grantee = 'pafil_bi' AND privilege_type = 'SELECT'
GROUP BY table_schema
ORDER BY table_schema;
