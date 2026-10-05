"""Despeja a bronze.mdnet_cdr num CSV local, para análise offline. Só leitura.

  python exportar_bronze_mdnet.py [--saida reconciliacao/bronze_mdnet_cdr.csv]
  python exportar_bronze_mdnet.py --pernas     # a tabela de pernas, com filtro_direcao

O arquivo sai sem o JSON cru nem o hash, ordenado por início da chamada. Traz telefone
de cliente, então o padrão é a pasta reconciliacao/, que o .gitignore já cobre para
*.csv. Não mova para um lugar versionado.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from psycopg import sql

from config.settings import carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger
from mdnet.objetos import CDR, CDR_PERNAS

log = get_logger("exportar_bronze_mdnet")

RAIZ = Path(__file__).resolve().parent
SAIDA_PADRAO = RAIZ / "reconciliacao" / "bronze_mdnet_cdr.csv"
SAIDA_PERNAS = RAIZ / "reconciliacao" / "bronze_mdnet_cdr_pernas.csv"


def main() -> int:
    parser = argparse.ArgumentParser(description="Despeja bronze.mdnet_cdr num CSV.")
    parser.add_argument("--saida", type=Path, default=None)
    parser.add_argument("--pernas", action="store_true",
                        help="Despeja bronze.mdnet_cdr_pernas em vez de bronze.mdnet_cdr.")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    args = parser.parse_args()
    configurar_logging(args.verbose)

    cfg = carregar_config_pg()
    objeto = CDR_PERNAS if args.pernas else CDR
    colunas = list(objeto.campos.values()) + ["ordem"]
    if args.pernas:
        colunas.append("filtro_direcao")
    if args.saida is None:
        args.saida = SAIDA_PERNAS if args.pernas else SAIDA_PADRAO
    consulta = sql.SQL(
        "COPY (SELECT {cols} FROM {sch}.{tab} ORDER BY data_hora_inicio, protocolo, ordem) "
        "TO STDOUT WITH (FORMAT CSV, HEADER true)"
    ).format(
        cols=sql.SQL(", ").join(map(sql.Identifier, colunas)),
        sch=sql.Identifier(cfg.bronze_schema),
        tab=sql.Identifier(objeto.nome_logico),
    )

    args.saida.parent.mkdir(parents=True, exist_ok=True)
    with db.conectar(cfg) as conn, conn.cursor() as cur, open(args.saida, "wb") as arquivo:
        with cur.copy(consulta) as copia:
            for bloco in copia:
                arquivo.write(bloco)
        linhas = cur.rowcount

    log.info("%d linha(s) gravadas em %s", linhas, args.saida)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
