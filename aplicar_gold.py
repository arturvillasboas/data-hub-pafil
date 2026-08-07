"""Aplica gold.sql (star schema) sobre a silver e valida. Requer a silver aplicada.

  python aplicar_gold.py [--validar]
"""
from __future__ import annotations

import argparse

from config.settings import RAIZ, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("aplicar_gold")

GOLD_SQL = RAIZ / "sql" / "gold" / "gold.sql"

OBJETOS = [
    "dim_calendario", "dim_empreendimento", "dim_unidade",
    "dim_corretor", "dim_corretor_headcount", "fato_reservas",
    "fato_leads", "fato_precadastros",
]


def validar(conn) -> int:
    falhas = 0
    with conn.cursor() as cur:
        for o in OBJETOS:
            try:
                cur.execute(f"SELECT count(*) FROM gold.{o}")
                log.info("  gold.%-18s OK  (%s linhas)", o, cur.fetchone()[0])
            except Exception as exc:  # noqa: BLE001
                conn.rollback()
                log.error("  gold.%-18s FALHOU: %s", o, str(exc).splitlines()[0])
                falhas += 1
    return falhas


def main() -> int:
    ap = argparse.ArgumentParser(description="Aplica a camada gold sobre a silver.")
    ap.add_argument("--validar", action="store_true", help="só valida (não aplica DDL)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    configurar_logging(args.verbose)
    cfg = carregar_config_pg()

    with db.conectar(cfg) as conn:
        if not args.validar:
            db.aplicar_ddl(conn, str(GOLD_SQL))
            log.info("Views gold aplicadas (%s).", GOLD_SQL.name)
        log.info("Validação smoke:")
        falhas = validar(conn)

    if falhas:
        log.error("%d objeto(s) gold com erro.", falhas)
        return 1
    log.info("Gold OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
