"""Ingestão CVDW -> bronze (Postgres). Por objeto: pagina a API, upsert idempotente,
snapshot do dia e marca de controle. Falha num objeto não derruba os demais.

  python ingestao.py --full [--criar-tabelas]
  python ingestao.py --incremental [--objetos reservas,leads]
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Sequence

import psycopg

from config.settings import (
    ConfigAPI,
    ConfigPostgres,
    Objeto,
    carregar_config_api,
    carregar_config_pg,
    carregar_objetos,
)
from cvdw import db
from cvdw.api import ClienteCVDW
from cvdw.db import (
    COL_DADOS_BRUTOS,
    COL_EXTRACAO,
    COL_HASH,
    COL_PAGINA,
    COL_TECNICA,
)
from cvdw.log import configurar_logging, get_logger
from cvdw.tipos import bucket_pg, hash_linha, nome_coluna, normalizar_para_sql, repr_para_hash

log = get_logger("ingestao")

RAIZ = Path(__file__).resolve().parent
BRONZE_SQL = RAIZ / "sql" / "bronze" / "bronze.sql"

# Colunas de metadados que não vêm da API.
_META = {COL_TECNICA, COL_HASH, COL_EXTRACAO, COL_PAGINA, COL_DADOS_BRUTOS}


def montar_linha(
    registro: dict[str, Any],
    colunas_fonte: Sequence[tuple[str, str]],
    tem_dados_brutos: bool,
    data_extracao: datetime,
    pagina: int,
) -> tuple[list[Any], str]:
    """Constrói (valores_para_insert, hash) de um registro.

    Mapeia cada coluna do banco à chave da API via nome_coluna() — chaves extras
    da API (drift) são ignoradas; colunas ausentes no registro viram NULL.
    """
    from psycopg.types.json import Json  # import local: só usado aqui

    mapeado = {nome_coluna(k): v for k, v in registro.items()}

    valores: list[Any] = []
    partes_hash: list[str] = []
    for nome, data_type in colunas_fonte:
        bruto = mapeado.get(nome)
        bucket = bucket_pg(data_type)
        valores.append(normalizar_para_sql(bruto, bucket))
        partes_hash.append(repr_para_hash(bruto, bucket))

    if tem_dados_brutos:
        valores.append(Json(registro))
        partes_hash.append(repr_para_hash(registro, "jsonb"))

    h = hash_linha(partes_hash)
    # Ordem final = fonte (+ dados_brutos) + _hash_linha + _data_extracao + _pagina
    valores.extend([h, data_extracao, pagina])
    return valores, h


def _colunas_insert(
    colunas_fonte: Sequence[tuple[str, str]], tem_dados_brutos: bool
) -> list[str]:
    """Lista de colunas, na ordem usada por montar_linha()."""
    nomes = [c for c, _ in colunas_fonte]
    if tem_dados_brutos:
        nomes.append(COL_DADOS_BRUTOS)
    nomes.extend([COL_HASH, COL_EXTRACAO, COL_PAGINA])
    return nomes


def ingerir_objeto(
    conn: psycopg.Connection,
    cliente: ClienteCVDW,
    cfg_api: ConfigAPI,
    schema: str,
    obj: Objeto,
    modo: str,
    inicio_execucao: datetime,
) -> int:
    """Ingere um objeto inteiro (paginação + upsert + snapshot + controle)."""
    tabela = obj.nome_logico
    if not db.tabela_existe(conn, schema, tabela):
        raise RuntimeError(
            f"Tabela {schema}.{tabela} não existe. Gere e aplique sql/bronze/bronze.sql "
            f"(ou rode com --criar-tabelas)."
        )

    colunas_db = db.colunas_tabela(conn, schema, tabela)
    colunas_fonte = [(n, t) for n, t in colunas_db if n not in _META]
    tem_dados_brutos = any(n == COL_DADOS_BRUTOS for n, _ in colunas_db)
    chave = db.chave_upsert(conn, schema, tabela)
    if not chave:
        raise RuntimeError(
            f"Índice único ux_{tabela}_chave não encontrado em {schema}.{tabela}."
        )

    colunas_insert = _colunas_insert(colunas_fonte, tem_dados_brutos)

    # Data de referência (modo incremental).
    a_partir = _data_referencia_incremental(conn, cfg_api, schema, tabela, modo)
    if modo == "incremental" and a_partir:
        log.info("[%s] incremental a_partir_data_referencia=%s", tabela, a_partir)

    data_extracao = datetime.now(timezone.utc)
    total = 0
    drift_avisado = False

    for pagina, registros in cliente.paginar(obj.path, a_partir):
        if not registros:
            continue
        if not drift_avisado:
            drift_avisado = _avisar_drift(tabela, registros[0], colunas_fonte,
                                          tem_dados_brutos)
        linhas = [
            montar_linha(reg, colunas_fonte, tem_dados_brutos, data_extracao, pagina)[0]
            for reg in registros
        ]
        db.bulk_upsert(conn, schema, tabela, colunas_insert, linhas, chave)
        total += len(registros)
        log.info("[%s] página %d: %d registros (acumulado %d)",
                 tabela, pagina, len(registros), total)

    # Snapshot do dia: copia o estado atual (todas as colunas exceto a técnica).
    colunas_copia = [n for n, _ in colunas_db if n != COL_TECNICA]
    qtd_snap = db.atualizar_snapshot(conn, schema, tabela, colunas_copia)

    # Marca para o próximo incremental = início desta execução (alta-marca).
    db.registrar_controle(conn, schema, tabela, inicio_execucao, modo, total, "OK", None)
    conn.commit()

    log.info("[%s] OK: %d registros ingeridos; snapshot do dia com %d linhas",
             tabela, total, qtd_snap)
    return total


def _data_referencia_incremental(
    conn: psycopg.Connection,
    cfg_api: ConfigAPI,
    schema: str,
    tabela: str,
    modo: str,
) -> str | None:
    """Calcula o valor de a_partir_data_referencia para o modo incremental."""
    if modo != "incremental":
        return None
    ultima = db.ler_data_referencia(conn, schema, tabela)
    if not ultima:
        log.info("[%s] sem marca anterior — fazendo carga completa neste objeto", tabela)
        return None
    # Subtrai a margem de segurança (cobre fuso/atraso; sobreposição é deduplicada).
    inicio = ultima - timedelta(hours=cfg_api.buffer_incremental_horas)
    # A API CVDW só aceita a DATA (YYYY-MM-DD); qualquer formato com hora dá HTTP 400.
    # A granularidade de dia é suficiente — a sobreposição é deduplicada no upsert.
    return inicio.strftime("%Y-%m-%d")


def _avisar_drift(
    tabela: str,
    registro: dict[str, Any],
    colunas_fonte: Sequence[tuple[str, str]],
    tem_dados_brutos: bool,
) -> bool:
    """Avisa (uma vez) se a API trouxe chaves que não existem como coluna."""
    if tem_dados_brutos:
        return True
    conhecidas = {c for c, _ in colunas_fonte}
    novas = {nome_coluna(k) for k in registro.keys()} - conhecidas
    if novas:
        log.warning("[%s] drift de schema: chaves sem coluna serão ignoradas: %s",
                    tabela, ", ".join(sorted(novas)))
    return True


def executar(modo: str, alvo: set[str] | None, criar_tabelas: bool) -> int:
    """Executa a ingestão de todos os objetos selecionados. Retorna o exit code."""
    cfg_api = carregar_config_api()
    cfg_pg = carregar_config_pg()
    objetos = carregar_objetos()
    if alvo:
        objetos = [o for o in objetos if o.nome_logico in alvo]

    cliente = ClienteCVDW(cfg_api)
    schema = cfg_pg.bronze_schema
    inicio_execucao = datetime.now(timezone.utc)
    resultados: list[tuple[str, str, int, str | None]] = []

    with db.conectar(cfg_pg) as conn:
        db.garantir_schema_e_controle(conn, schema)
        if criar_tabelas:
            if not BRONZE_SQL.exists():
                log.error("bronze.sql não encontrado em %s — rode gerar_ddl_bronze.py",
                          BRONZE_SQL)
                return 1
            db.aplicar_ddl(conn, str(BRONZE_SQL))

        log.info("Ingestão modo=%s | %d objeto(s) | schema=%s",
                 modo, len(objetos), schema)

        for obj in objetos:
            try:
                n = ingerir_objeto(conn, cliente, cfg_api, schema, obj, modo,
                                   inicio_execucao)
                resultados.append((obj.nome_logico, "OK", n, None))
            except Exception as exc:  # noqa: BLE001 — isola falhas por objeto
                conn.rollback()  # desfaz o que tiver começado para este objeto
                log.exception("[%s] FALHOU", obj.nome_logico)
                # Registra a falha em transação própria (não some no rollback).
                try:
                    db.registrar_falha_controle(conn, schema, obj.nome_logico, modo,
                                                str(exc))
                except Exception:  # noqa: BLE001
                    log.error("[%s] não foi possível registrar a falha no controle",
                              obj.nome_logico)
                resultados.append((obj.nome_logico, "ERRO", 0, str(exc)))

    return _imprimir_resumo(modo, resultados)


def _imprimir_resumo(
    modo: str, resultados: list[tuple[str, str, int, str | None]]
) -> int:
    """Imprime o resumo final e devolve 1 se houve qualquer falha."""
    ok = [r for r in resultados if r[1] == "OK"]
    erros = [r for r in resultados if r[1] == "ERRO"]
    total_reg = sum(r[2] for r in ok)

    log.info("=" * 64)
    log.info("RESUMO (modo=%s): %d OK (%d registros), %d falha(s)",
             modo, len(ok), total_reg, len(erros))
    for nome, _, n, _msg in ok:
        log.info("  OK   %-32s %d registros", nome, n)
    for nome, _, _n, msg in erros:
        log.error("  ERRO %-32s %s", nome, (msg or "")[:160])
    log.info("=" * 64)
    return 1 if erros else 0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ingestão CVDW -> bronze (Postgres).")
    grupo = parser.add_mutually_exclusive_group(required=True)
    grupo.add_argument("--full", action="store_true", help="Carga inicial completa.")
    grupo.add_argument("--incremental", action="store_true",
                       help="Carga incremental (delta desde a última execução).")
    parser.add_argument("--objetos", type=str, default=None,
                        help="Lista separada por vírgula para limitar a ingestão.")
    parser.add_argument("--criar-tabelas", action="store_true",
                        help="Aplica sql/bronze/bronze.sql antes de ingerir.")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    configurar_logging(args.verbose)
    modo = "full" if args.full else "incremental"
    alvo = {n.strip() for n in args.objetos.split(",")} if args.objetos else None
    return executar(modo, alvo, args.criar_tabelas)


if __name__ == "__main__":
    raise SystemExit(main())
