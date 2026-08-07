"""Gera sql/bronze/bronze.sql a partir do cvdw_schema.json: por objeto, a tabela de
estado atual + o _snapshot append-only, com metadados e índice único de upsert.

  python gerar_ddl_bronze.py [--schema schema/cvdw_schema.json] [--out sql/bronze/bronze.sql]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from cvdw.db import (
    COL_DADOS_BRUTOS,
    COL_EXTRACAO,
    COL_HASH,
    COL_PAGINA,
    COL_TECNICA,
    TABELA_CONTROLE,
)
from cvdw.log import configurar_logging, get_logger

log = get_logger("ddl")

RAIZ = Path(__file__).resolve().parent
SCHEMA_PADRAO = RAIZ / "schema" / "cvdw_schema.json"
SAIDA_PADRAO = RAIZ / "sql" / "bronze" / "bronze.sql"
SCHEMA_BRONZE = "bronze"


def _colunas_fonte(campos: list[dict]) -> list[tuple[str, str]]:
    """Extrai (coluna, tipo_sql) dos campos, deduplicando nomes colididos."""
    vistos: set[str] = set()
    colunas: list[tuple[str, str]] = []
    for campo in campos:
        nome = campo["coluna"]
        if nome in vistos:  # colisão de sanitização: sufixa para não quebrar o DDL
            sufixo = 2
            while f"{nome}_{sufixo}" in vistos:
                sufixo += 1
            nome = f"{nome}_{sufixo}"
        vistos.add(nome)
        colunas.append((nome, campo["tipo_sql"]))
    return colunas


def _ddl_objeto(nome: str, info: dict) -> str:
    """Monta o DDL (tabela atual + snapshot + índices) de um objeto."""
    colunas_fonte = _colunas_fonte(info["campos"])
    id_col = info.get("id_detectado")
    chave = id_col if id_col else COL_HASH

    # Objetos sem schema descoberto: guarda o registro inteiro em _dados_brutos.
    sem_schema = not colunas_fonte

    linhas: list[str] = [f"-- ===== {nome} ({info['path']}) =====",
                         f"CREATE TABLE IF NOT EXISTS {SCHEMA_BRONZE}.{nome} ("]
    corpo = [f"    {COL_TECNICA} bigint GENERATED ALWAYS AS IDENTITY"]
    for col, tipo in colunas_fonte:
        corpo.append(f"    {col} {tipo}")
    if sem_schema:
        corpo.append(f"    {COL_DADOS_BRUTOS} jsonb")
    corpo.append(f"    {COL_HASH} text NOT NULL")
    corpo.append(f"    {COL_EXTRACAO} timestamptz NOT NULL DEFAULT now()")
    corpo.append(f"    {COL_PAGINA} integer")
    corpo.append(f"    CONSTRAINT pk_{nome} PRIMARY KEY ({COL_TECNICA})")
    linhas.append(",\n".join(corpo))
    linhas.append(");")

    # Índice único = alvo do ON CONFLICT (id de negócio quando há; senão hash).
    linhas.append(
        f"CREATE UNIQUE INDEX IF NOT EXISTS ux_{nome}_chave "
        f"ON {SCHEMA_BRONZE}.{nome} ({chave});"
    )
    if id_col:  # índice por id explícito (já coberto pelo único acima, deixado claro)
        linhas.append(
            f"-- (índice por id de negócio garantido por ux_{nome}_chave em {id_col})"
        )

    # ---- Tabela de snapshot (mesmas colunas + _data_snapshot) ----
    linhas.append(f"CREATE TABLE IF NOT EXISTS {SCHEMA_BRONZE}.{nome}_snapshot (")
    corpo_snap = [
        "    _id_snapshot bigint GENERATED ALWAYS AS IDENTITY",
        "    _data_snapshot date NOT NULL DEFAULT CURRENT_DATE",
    ]
    for col, tipo in colunas_fonte:
        corpo_snap.append(f"    {col} {tipo}")
    if sem_schema:
        corpo_snap.append(f"    {COL_DADOS_BRUTOS} jsonb")
    corpo_snap.append(f"    {COL_HASH} text")
    corpo_snap.append(f"    {COL_EXTRACAO} timestamptz")
    corpo_snap.append(f"    {COL_PAGINA} integer")
    corpo_snap.append(f"    CONSTRAINT pk_{nome}_snapshot PRIMARY KEY (_id_snapshot)")
    linhas.append(",\n".join(corpo_snap))
    linhas.append(");")
    linhas.append(
        f"CREATE UNIQUE INDEX IF NOT EXISTS ux_{nome}_snapshot_dia "
        f"ON {SCHEMA_BRONZE}.{nome}_snapshot (_data_snapshot, {chave});"
    )
    linhas.append(
        f"CREATE INDEX IF NOT EXISTS ix_{nome}_snapshot_data "
        f"ON {SCHEMA_BRONZE}.{nome}_snapshot (_data_snapshot);"
    )
    linhas.append("")
    return "\n".join(linhas)


def gerar_ddl(schema: dict) -> str:
    """Gera o script SQL completo (schema + controle + todas as tabelas)."""
    partes: list[str] = [
        "-- DDL da camada bronze — GERADO por gerar_ddl_bronze.py. Não editar à mão.",
        f"-- Origem: descoberta de {len(schema['objetos'])} objeto(s) do CVDW.",
        "",
        f"CREATE SCHEMA IF NOT EXISTS {SCHEMA_BRONZE};",
        "",
        "-- Controle de carga incremental (última data de referência por objeto).",
        f"CREATE TABLE IF NOT EXISTS {SCHEMA_BRONZE}.{TABELA_CONTROLE} (",
        "    nome_logico            text PRIMARY KEY,",
        "    ultima_data_referencia timestamptz,",
        "    ultima_execucao        timestamptz,",
        "    ultimo_modo            text,",
        "    registros_ultima_carga bigint,",
        "    status                 text,",
        "    mensagem               text",
        ");",
        "",
    ]
    for nome, info in schema["objetos"].items():
        partes.append(_ddl_objeto(nome, info))
    return "\n".join(partes)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Gera o DDL da camada bronze.")
    parser.add_argument("--schema", type=Path, default=SCHEMA_PADRAO,
                        help="Caminho do cvdw_schema.json.")
    parser.add_argument("--out", type=Path, default=SAIDA_PADRAO,
                        help="Arquivo .sql de saída.")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    configurar_logging(args.verbose)

    if not args.schema.exists():
        log.error("Schema não encontrado: %s — rode descoberta_schema.py antes.",
                  args.schema)
        return 1

    with open(args.schema, "r", encoding="utf-8") as arquivo:
        schema: dict[str, Any] = json.load(arquivo)

    ddl = gerar_ddl(schema)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as arquivo:
        arquivo.write(ddl)

    log.info("DDL gerado em %s (%d objetos)", args.out, len(schema["objetos"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
