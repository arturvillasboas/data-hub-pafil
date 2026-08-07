"""Aplica silver.sql + seeds.sql sobre a bronze e valida (conta linhas de cada view).

  python aplicar_silver.py [--so-views] [--validar]
"""
from __future__ import annotations

import argparse
from pathlib import Path

from config.settings import RAIZ, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("aplicar_silver")

SILVER_SQL = RAIZ / "sql" / "silver" / "silver.sql"
SEEDS_SQL = RAIZ / "sql" / "silver" / "seeds.sql"

# Views da silver a validar (devem existir após aplicar silver.sql).
VIEWS = [
    "reservas", "vendas", "distratos",
    "unidades", "corretores", "imobiliarias",
    "leads", "precadastros", "leads_conversoes",
]


def validar(conn) -> int:
    """Conta linhas de cada view silver; falha (retorna >0) se alguma quebrar."""
    falhas = 0
    with conn.cursor() as cur:
        for v in VIEWS:
            try:
                cur.execute(f"SELECT count(*) FROM silver.{v}")
                log.info("  silver.%-13s OK  (%s linhas)", v, cur.fetchone()[0])
            except Exception as exc:  # noqa: BLE001 — queremos reportar todas
                conn.rollback()
                log.error("  silver.%-13s FALHOU: %s", v, str(exc).splitlines()[0])
                falhas += 1
    return falhas


def main() -> int:
    ap = argparse.ArgumentParser(description="Aplica a camada silver sobre a bronze.")
    ap.add_argument("--so-views", action="store_true", help="aplica só silver.sql (pula seeds)")
    ap.add_argument("--validar", action="store_true", help="só valida (não aplica DDL)")
    ap.add_argument("--verbose", action="store_true", help="log de debug")
    args = ap.parse_args()

    configurar_logging(args.verbose)
    cfg = carregar_config_pg()

    with db.conectar(cfg) as conn:
        if not args.validar:
            db.aplicar_ddl(conn, str(SILVER_SQL))
            log.info("Views silver aplicadas (%s).", SILVER_SQL.name)
            if not args.so_views:
                db.aplicar_ddl(conn, str(SEEDS_SQL))
                log.info("Seeds de-para aplicadas (%s).", SEEDS_SQL.name)

        log.info("Validação smoke das views:")
        falhas = validar(conn)

    if falhas:
        log.error("%d view(s) com erro — provável divergência de coluna vs bronze.", falhas)
        return 1
    log.info("Silver OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
