"""Reconstrói as transformações em ordem: silver -> gold -> seeds (a bronze já deve existir).

  python aplicar_tudo.py [--xlsm "<Vendas Consolidadas.xlsm>"]
"""
from __future__ import annotations

import argparse
import subprocess
import sys

from cvdw.log import configurar_logging, get_logger

log = get_logger("aplicar_tudo")


def passo(nome: str, args: list[str]) -> bool:
    log.info("=== %s ===", nome)
    r = subprocess.run([sys.executable, *args])
    if r.returncode != 0:
        log.error("Falhou em '%s' (exit %d) — abortando.", nome, r.returncode)
        return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="Aplica silver + gold + seeds em ordem.")
    ap.add_argument("--xlsm", help="repassa p/ popular_seeds (carrega DE_PARA_PRODUTOS)")
    args = ap.parse_args()
    configurar_logging(False)

    etapas = [
        ("Silver (views de conformação)", ["aplicar_silver.py"]),
        ("Gold (star schema + kpi)", ["aplicar_gold.py"]),
        ("Seeds de-para", ["popular_seeds.py"] + (["--xlsm", args.xlsm] if args.xlsm else [])),
    ]
    for nome, cmd in etapas:
        if not passo(nome, cmd):
            return 1
    log.info("Warehouse reconstruído: bronze -> silver -> gold + seeds. OK.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
