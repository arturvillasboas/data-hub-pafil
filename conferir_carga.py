"""Confere a completude da carga bronze: total da ORIGEM (API) vs. linhas na bronze.

Para cada objeto do config/objetos.yml, lê o `total_de_registros` que a API
reporta no envelope (1 requisição leve por objeto) e compara com a contagem real
na tabela bronze. Dá a "noção da carga" (quanto a origem tem vs. quanto
ingerimos) e serve de checagem de completude para a reconciliação.

Diferença esperada:
  - dif = 0  -> bronze tem exatamente o que a origem reporta.
  - dif > 0  -> origem tem mais que a bronze (carga incompleta? checar).
  - dif < 0  -> bronze tem mais que a origem (origem encolheu desde a carga;
                normal se houve exclusões na fonte após a ingestão).

Uso:
  python conferir_carga.py
"""
from __future__ import annotations

import logging

from psycopg import sql

from config.settings import carregar_config_api, carregar_config_pg, carregar_objetos
from cvdw import db
from cvdw.api import ClienteCVDW
from cvdw.log import configurar_logging, get_logger

log = get_logger("conferir_carga")


def _contar(conn, schema: str, tabela: str) -> int | None:
    """Conta as linhas da tabela bronze; None se a tabela não existir."""
    if not db.tabela_existe(conn, schema, tabela):
        return None
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL("SELECT count(*) FROM {}.{}").format(
                sql.Identifier(schema), sql.Identifier(tabela)
            )
        )
        return cur.fetchone()[0]


def conferir() -> int:
    cfg_api = carregar_config_api()
    cfg_pg = carregar_config_pg()
    objetos = carregar_objetos()
    cliente = ClienteCVDW(cfg_api)
    schema = cfg_pg.bronze_schema

    print(f"{'objeto':34}{'origem(API)':>13}{'bronze':>11}{'dif':>9}")
    print("-" * 67)
    soma_dif = 0
    with db.conectar(cfg_pg) as conn:
        for obj in objetos:
            total_api = cliente.total_registros_origem(obj.path)
            linhas = _contar(conn, schema, obj.nome_logico)
            linhas_txt = "(sem tab)" if linhas is None else f"{linhas}"
            if isinstance(total_api, int) and isinstance(linhas, int):
                dif = total_api - linhas
                soma_dif += abs(dif)
                marca = "" if dif == 0 else "  <--"
                print(f"{obj.nome_logico:34}{total_api:>13}{linhas:>11}{dif:>9}{marca}")
            else:
                api_txt = "(sem total)" if total_api is None else f"{total_api}"
                print(f"{obj.nome_logico:34}{api_txt:>13}{linhas_txt:>11}{'?':>9}")
    print("-" * 67)
    print(f"Soma das diferencas absolutas: {soma_dif}")
    return 0


if __name__ == "__main__":
    configurar_logging(False)
    # Silencia o log de cada GET para a tabela ficar limpa (mantém warnings/429).
    logging.getLogger("cvdw.api").setLevel(logging.WARNING)
    raise SystemExit(conferir())
