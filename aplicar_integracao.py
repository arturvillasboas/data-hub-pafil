"""Aplica sql/integracao/integracao.sql e valida (conta linhas das tabelas de controle).

  python aplicar_integracao.py [--validar]
"""
from __future__ import annotations

import argparse

from config.settings import RAIZ, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("aplicar_integracao")

INTEGRACAO_SQL = RAIZ / "sql" / "integracao" / "integracao.sql"

# Tabelas e a view a validar depois de aplicar (devem existir e responder).
OBJETOS = [
    "depara_contato", "dono_campo", "fila_sync", "log_sync",
    "v_fila_para_despachar", "v_reconciliacao_cvcrm",
]


def validar(conn) -> int:
    """Conta linhas de cada tabela/view de integracao; falha se alguma quebrar."""
    falhas = 0
    with conn.cursor() as cur:
        for obj in OBJETOS:
            try:
                cur.execute(f"SELECT count(*) FROM integracao.{obj}")
                log.info("  integracao.%-22s OK  (%s linhas)", obj, cur.fetchone()[0])
            except Exception as exc:  # noqa: BLE001 — queremos reportar todas
                conn.rollback()
                log.error("  integracao.%-22s FALHOU: %s", obj, str(exc).splitlines()[0])
                falhas += 1
    return falhas


def main() -> int:
    ap = argparse.ArgumentParser(description="Aplica o schema integracao (Fase 1: integração CVCRM<->GHL).")
    ap.add_argument("--validar", action="store_true", help="só valida (não aplica DDL)")
    ap.add_argument("--verbose", action="store_true", help="log de debug")
    args = ap.parse_args()

    configurar_logging(args.verbose)
    cfg = carregar_config_pg()

    with db.conectar(cfg) as conn:
        if not args.validar:
            db.aplicar_ddl(conn, str(INTEGRACAO_SQL))
            log.info("Schema integracao aplicado (%s).", INTEGRACAO_SQL.name)

        log.info("Validação smoke do schema integracao:")
        falhas = validar(conn)

    if falhas:
        log.error("%d objeto(s) com erro.", falhas)
        return 1
    log.info("Schema integracao OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
