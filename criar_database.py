"""Bootstrap do banco: cria o database PG_DB se ainda não existir.

O sql/bronze/bronze.sql cria o *schema* bronze e as tabelas, mas pressupõe que o
*database* (PG_DB) já exista. Este script preenche essa lacuna — é o primeiro
passo num PostgreSQL recém-provisionado (local, VPS ou Azure).

Conecta no database de manutenção `postgres`, verifica a existência de PG_DB e,
se faltar, executa CREATE DATABASE (fora de transação, como o Postgres exige).
Idempotente: se o banco já existe, não faz nada.

Uso:
  python criar_database.py
"""
from __future__ import annotations

import psycopg
from psycopg import sql

from config.settings import ConfigPostgres, carregar_config_pg
from cvdw.log import configurar_logging, get_logger

log = get_logger("criar_database")

# Database de manutenção sempre presente num cluster PostgreSQL.
_DB_MANUTENCAO = "postgres"


def _conninfo_manutencao(cfg: ConfigPostgres) -> str:
    """conninfo apontando para o database de manutenção (não o PG_DB alvo)."""
    return (
        f"host={cfg.host} port={cfg.port} dbname={_DB_MANUTENCAO} "
        f"user={cfg.user} password={cfg.password} sslmode={cfg.sslmode}"
    )


def criar_database() -> int:
    """Cria o database alvo se necessário. Retorna o exit code (0 = ok)."""
    cfg = carregar_config_pg()
    if cfg.db == _DB_MANUTENCAO:
        log.info("PG_DB=%s é o próprio database de manutenção; nada a criar.", cfg.db)
        return 0

    # autocommit: CREATE DATABASE não roda dentro de transação.
    with psycopg.connect(_conninfo_manutencao(cfg), autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (cfg.db,))
            if cur.fetchone():
                log.info("Database %s já existe — nada a fazer.", cfg.db)
                return 0
            cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(cfg.db)))
            log.info("Database %s criado.", cfg.db)
    return 0


if __name__ == "__main__":
    configurar_logging(False)
    raise SystemExit(criar_database())
