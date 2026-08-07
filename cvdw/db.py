"""Acesso ao PostgreSQL: conexão, introspecção, bulk upsert, snapshot e controle.
A ingestão é dirigida pelo catálogo do banco (information_schema + ux_<tabela>_chave)."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime
from typing import Any, Iterator, Sequence

import psycopg
from psycopg import sql

from config.settings import ConfigPostgres
from cvdw.log import get_logger

log = get_logger("cvdw.db")

# Colunas de metadados geridas pela ingestão (não vêm da API).
COL_HASH = "_hash_linha"
COL_EXTRACAO = "_data_extracao"
COL_PAGINA = "_pagina"
COL_TECNICA = "_id_tecnico"
COL_DADOS_BRUTOS = "_dados_brutos"  # usada só p/ objetos sem schema descoberto
TABELA_CONTROLE = "_ingestao_controle"

# Limite de parâmetros por statement no Postgres é 65535; deixamos folga.
_MAX_PARAMS = 60000


@contextmanager
def conectar(cfg: ConfigPostgres) -> Iterator[psycopg.Connection]:
    """Abre uma conexão (transacional) e garante o fechamento."""
    conn = psycopg.connect(cfg.conninfo(), autocommit=False)
    try:
        yield conn
    finally:
        conn.close()


def garantir_schema_e_controle(conn: psycopg.Connection, schema: str) -> None:
    """Cria o schema bronze e a tabela de controle, se ainda não existirem."""
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(schema))
        )
        cur.execute(
            sql.SQL(
                """
                CREATE TABLE IF NOT EXISTS {sch}.{tab} (
                    nome_logico            text PRIMARY KEY,
                    ultima_data_referencia timestamptz,
                    ultima_execucao        timestamptz,
                    ultimo_modo            text,
                    registros_ultima_carga bigint,
                    status                 text,
                    mensagem               text
                )
                """
            ).format(sch=sql.Identifier(schema), tab=sql.Identifier(TABELA_CONTROLE))
        )
    conn.commit()


def aplicar_ddl(conn: psycopg.Connection, caminho_sql: str) -> None:
    """Executa o arquivo bronze.sql inteiro (CREATE ... IF NOT EXISTS)."""
    # utf-8-sig: tolera BOM (o bronze.sql gerado pode vir com marca de ordem de
    # byte, que como "utf-8" puro chegaria ao Postgres e quebraria o parse).
    with open(caminho_sql, "r", encoding="utf-8-sig") as arquivo:
        ddl = arquivo.read()
    with conn.cursor() as cur:
        cur.execute(ddl)  # múltiplos statements sem parâmetros: ok no psycopg3
    conn.commit()
    log.info("DDL aplicado a partir de %s", caminho_sql)


def tabela_existe(conn: psycopg.Connection, schema: str, tabela: str) -> bool:
    """Indica se a tabela existe no schema informado."""
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass(%s)", (f"{schema}.{tabela}",))
        return cur.fetchone()[0] is not None


def colunas_tabela(
    conn: psycopg.Connection, schema: str, tabela: str
) -> list[tuple[str, str]]:
    """Lista (nome, data_type) das colunas, na ordem física da tabela."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
            """,
            (schema, tabela),
        )
        return [(r[0], r[1]) for r in cur.fetchall()]


def chave_upsert(conn: psycopg.Connection, schema: str, tabela: str) -> list[str]:
    """Retorna as colunas do índice único `ux_<tabela>_chave` (alvo do ON CONFLICT)."""
    nome_indice = f"ux_{tabela}_chave"
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_class      c  ON c.oid  = i.indrelid
            JOIN pg_namespace  n  ON n.oid  = c.relnamespace
            JOIN pg_class      ic ON ic.oid = i.indexrelid
            JOIN pg_attribute  a  ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
            WHERE n.nspname = %s AND c.relname = %s
              AND i.indisunique AND ic.relname = %s
            ORDER BY array_position(i.indkey, a.attnum)
            """,
            (schema, tabela, nome_indice),
        )
        return [r[0] for r in cur.fetchall()]


def bulk_upsert(
    conn: psycopg.Connection,
    schema: str,
    tabela: str,
    colunas: Sequence[str],
    linhas: Sequence[Sequence[Any]],
    chave_conflito: Sequence[str],
) -> int:
    """Insere/atualiza várias linhas de uma vez (ON CONFLICT por `chave_conflito`).

    Faz lotes que respeitam o limite de parâmetros do Postgres. Nada de inserir
    linha a linha.
    """
    if not linhas:
        return 0

    set_cols = [c for c in colunas if c not in chave_conflito]
    if set_cols:
        sets = sql.SQL(", ").join(
            sql.SQL("{c} = EXCLUDED.{c}").format(c=sql.Identifier(c)) for c in set_cols
        )
        acao = sql.SQL("DO UPDATE SET {}").format(sets)
    else:
        acao = sql.SQL("DO NOTHING")

    cols_ident = sql.SQL(", ").join(map(sql.Identifier, colunas))
    chave_ident = sql.SQL(", ").join(map(sql.Identifier, chave_conflito))
    placeholders_linha = sql.SQL("({})").format(
        sql.SQL(", ").join(sql.Placeholder() for _ in colunas)
    )

    lote = max(1, _MAX_PARAMS // max(1, len(colunas)))
    afetadas = 0
    with conn.cursor() as cur:
        for inicio in range(0, len(linhas), lote):
            bloco = linhas[inicio : inicio + lote]
            valores = sql.SQL(", ").join(placeholders_linha for _ in bloco)
            consulta = sql.SQL(
                "INSERT INTO {sch}.{tab} ({cols}) VALUES {vals} "
                "ON CONFLICT ({chave}) {acao}"
            ).format(
                sch=sql.Identifier(schema),
                tab=sql.Identifier(tabela),
                cols=cols_ident,
                vals=valores,
                chave=chave_ident,
                acao=acao,
            )
            params: list[Any] = []
            for linha in bloco:
                params.extend(linha)
            cur.execute(consulta, params)
            afetadas += cur.rowcount
    return afetadas


def atualizar_snapshot(
    conn: psycopg.Connection, schema: str, tabela: str, colunas_copia: Sequence[str]
) -> int:
    """Regrava o snapshot do dia: apaga o de hoje e copia o estado atual da tabela.

    Idempotente: rodar de novo no mesmo dia substitui o snapshot do dia, sem
    duplicar. Append-only entre dias.
    """
    snap = f"{tabela}_snapshot"
    cols = sql.SQL(", ").join(map(sql.Identifier, colunas_copia))
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL("DELETE FROM {sch}.{snap} WHERE _data_snapshot = CURRENT_DATE").format(
                sch=sql.Identifier(schema), snap=sql.Identifier(snap)
            )
        )
        cur.execute(
            sql.SQL(
                "INSERT INTO {sch}.{snap} (_data_snapshot, {cols}) "
                "SELECT CURRENT_DATE, {cols} FROM {sch}.{tab}"
            ).format(
                sch=sql.Identifier(schema),
                snap=sql.Identifier(snap),
                tab=sql.Identifier(tabela),
                cols=cols,
            )
        )
        return cur.rowcount


def ler_data_referencia(
    conn: psycopg.Connection, schema: str, nome_logico: str
) -> datetime | None:
    """Lê a última data de referência registrada para o objeto (modo incremental)."""
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                "SELECT ultima_data_referencia FROM {sch}.{tab} WHERE nome_logico = %s"
            ).format(sch=sql.Identifier(schema), tab=sql.Identifier(TABELA_CONTROLE)),
            (nome_logico,),
        )
        linha = cur.fetchone()
        return linha[0] if linha else None


def registrar_controle(
    conn: psycopg.Connection,
    schema: str,
    nome_logico: str,
    data_referencia: datetime,
    modo: str,
    registros: int,
    status: str,
    mensagem: str | None,
) -> None:
    """Registra (upsert) o resultado da ingestão do objeto na tabela de controle."""
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
                INSERT INTO {sch}.{tab}
                    (nome_logico, ultima_data_referencia, ultima_execucao,
                     ultimo_modo, registros_ultima_carga, status, mensagem)
                VALUES (%s, %s, now(), %s, %s, %s, %s)
                ON CONFLICT (nome_logico) DO UPDATE SET
                    ultima_data_referencia = EXCLUDED.ultima_data_referencia,
                    ultima_execucao        = EXCLUDED.ultima_execucao,
                    ultimo_modo            = EXCLUDED.ultimo_modo,
                    registros_ultima_carga = EXCLUDED.registros_ultima_carga,
                    status                 = EXCLUDED.status,
                    mensagem               = EXCLUDED.mensagem
                """
            ).format(sch=sql.Identifier(schema), tab=sql.Identifier(TABELA_CONTROLE)),
            (nome_logico, data_referencia, modo, registros, status, mensagem),
        )


def registrar_falha_controle(
    conn: psycopg.Connection, schema: str, nome_logico: str, modo: str, mensagem: str
) -> None:
    """Marca apenas o status de falha sem mexer na última data de referência.

    Usa transação própria para não ser desfeita pelo rollback do objeto.
    """
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
                INSERT INTO {sch}.{tab}
                    (nome_logico, ultima_execucao, ultimo_modo, status, mensagem)
                VALUES (%s, now(), %s, 'ERRO', %s)
                ON CONFLICT (nome_logico) DO UPDATE SET
                    ultima_execucao = EXCLUDED.ultima_execucao,
                    ultimo_modo     = EXCLUDED.ultimo_modo,
                    status          = 'ERRO',
                    mensagem        = EXCLUDED.mensagem
                """
            ).format(sch=sql.Identifier(schema), tab=sql.Identifier(TABELA_CONTROLE)),
            (nome_logico, modo, mensagem[:500]),
        )
    conn.commit()
