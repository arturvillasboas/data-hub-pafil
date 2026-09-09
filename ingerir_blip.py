"""Ingestão Blip -> bronze (Postgres). Irmão do ingestao.py, mesma mecânica.

Por objeto: pagina a API de comandos, faz upsert idempotente pela chave de
negócio, atualiza o snapshot do dia quando o objeto pede, e registra a marca de
controle. Falha num objeto não derruba os demais.

  python ingerir_blip.py --full [--criar-tabelas]
  python ingerir_blip.py --incremental [--objetos blip_tickets]

O acesso ao banco é o `cvdw.db` sem alteração nenhuma: apesar do nome do
pacote, não há nada de CVDW ali dentro, é upsert e catálogo do Postgres.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Sequence

import psycopg
from psycopg.types.json import Json

from blip.api import ClienteBlip
from blip.objetos import OBJETOS, ObjetoBlip, por_nome
from config.settings import ConfigBlip, carregar_config_blip, carregar_config_pg
from cvdw import db
from cvdw.db import COL_DADOS_BRUTOS, COL_EXTRACAO, COL_HASH, COL_PAGINA, COL_TECNICA
from cvdw.log import configurar_logging, get_logger
from cvdw.tipos import bucket_pg, hash_linha, normalizar_para_sql, repr_para_hash

log = get_logger("ingerir_blip")

RAIZ = Path(__file__).resolve().parent
BLIP_SQL = RAIZ / "sql" / "bronze" / "blip.sql"

_META = {COL_TECNICA, COL_HASH, COL_EXTRACAO, COL_PAGINA, COL_DADOS_BRUTOS}

# De quantas em quantas páginas a carga faz commit parcial (ver comentário no
# laço de ingerir_objeto).
_PAGINAS_POR_COMMIT = 10


def montar_linha(
    registro: dict[str, Any],
    colunas_fonte: Sequence[tuple[str, str]],
    coluna_para_chave: dict[str, str],
    data_extracao: datetime,
    pagina: int,
) -> list[Any]:
    """Constrói a lista de valores de um registro, na ordem das colunas."""
    valores: list[Any] = []
    partes_hash: list[str] = []
    for nome, data_type in colunas_fonte:
        bruto = registro.get(coluna_para_chave[nome])
        bucket = bucket_pg(data_type)
        valores.append(normalizar_para_sql(bruto, bucket))
        partes_hash.append(repr_para_hash(bruto, bucket))

    # O JSON cru entra sempre: a amostra da descoberta não cobre a base inteira,
    # e um campo que apareça depois fica preservado aqui até virar coluna.
    valores.append(Json(registro))
    partes_hash.append(repr_para_hash(registro, "jsonb"))

    valores.extend([hash_linha(partes_hash), data_extracao, pagina])
    return valores


def _filtro_incremental(
    conn: psycopg.Connection,
    cfg: ConfigBlip,
    schema: str,
    obj: ObjetoBlip,
    modo: str,
) -> str | None:
    """Monta o `$filter` da janela incremental, ou None para ler tudo.

    A janela é larga de propósito. O campo que a API deixa filtrar é o
    `storageDate`, que marca a CRIAÇÃO do ticket e não se move quando ele muda
    de situação (medido na descoberta: storage_date < open_date < close_date no
    mesmo ticket). Uma janela curta traria só os tickets criados desde a última
    execução, e um ticket aberto ontem e fechado hoje ficaria gravado para
    sempre como aberto. Reler os últimos `janela_dias` resolve isso, ao custo de
    reprocessar alguns milhares de linhas que o upsert deduplica.
    """
    if modo != "incremental" or not obj.campo_janela:
        return None

    ultima = db.ler_data_referencia(conn, schema, obj.nome_logico)
    if not ultima:
        log.info("[%s] sem marca anterior — carga completa neste objeto",
                 obj.nome_logico)
        return None

    inicio = ultima - timedelta(days=cfg.janela_dias)
    # A API só aceita esta sintaxe. Aspas simples, sem aspas e datetime'...'
    # são recusadas com "no processor available" (testado em 09/set/2026).
    marca = inicio.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log.info("[%s] incremental desde %s (%d dias de folga)",
             obj.nome_logico, marca, cfg.janela_dias)
    return f"{obj.campo_janela} ge datetimeoffset'{marca}'"


def _avisar_drift(obj: ObjetoBlip, registro: dict[str, Any]) -> None:
    """Avisa se a API trouxe campos que o mapa não conhece.

    Não é erro: o `_dados_brutos` guarda o valor de qualquer jeito. É um convite
    a acrescentar a coluna quando o campo novo interessar.
    """
    novas = set(registro) - set(obj.campos)
    if novas:
        log.warning("[%s] campos novos na API (guardados só em %s): %s",
                    obj.nome_logico, COL_DADOS_BRUTOS, ", ".join(sorted(novas)))


def ingerir_objeto(
    conn: psycopg.Connection,
    cliente: ClienteBlip,
    cfg: ConfigBlip,
    schema: str,
    obj: ObjetoBlip,
    modo: str,
    inicio_execucao: datetime,
) -> int:
    """Ingere um objeto inteiro (paginação + upsert + snapshot + controle)."""
    tabela = obj.nome_logico
    if not db.tabela_existe(conn, schema, tabela):
        raise RuntimeError(
            f"Tabela {schema}.{tabela} não existe. Rode com --criar-tabelas "
            f"para aplicar {BLIP_SQL.name}."
        )

    colunas_db = db.colunas_tabela(conn, schema, tabela)
    coluna_para_chave = {coluna: chave for chave, coluna in obj.campos.items()}
    colunas_fonte = [
        (n, t) for n, t in colunas_db if n not in _META and n in coluna_para_chave
    ]

    faltando = set(obj.campos.values()) - {n for n, _ in colunas_fonte}
    if faltando:
        raise RuntimeError(
            f"{schema}.{tabela} não tem as colunas {sorted(faltando)}. O mapa em "
            f"blip/objetos.py e o {BLIP_SQL.name} estão fora de sincronia."
        )

    chave = db.chave_upsert(conn, schema, tabela)
    if not chave:
        raise RuntimeError(f"Índice único ux_{tabela}_chave não encontrado.")

    colunas_insert = [n for n, _ in colunas_fonte] + [
        COL_DADOS_BRUTOS, COL_HASH, COL_EXTRACAO, COL_PAGINA
    ]

    filtro = _filtro_incremental(conn, cfg, schema, obj, modo)
    data_extracao = datetime.now(timezone.utc)
    total = 0
    drift_avisado = False

    for skip, registros in cliente.paginar(obj.recurso, filtro=filtro):
        if not registros:
            continue
        if not drift_avisado:
            _avisar_drift(obj, registros[0])
            drift_avisado = True

        pagina = skip // max(1, cfg.take) + 1
        linhas = [
            montar_linha(reg, colunas_fonte, coluna_para_chave, data_extracao, pagina)
            for reg in registros
        ]
        db.bulk_upsert(conn, schema, tabela, colunas_insert, linhas, chave)
        total += len(registros)
        log.info("[%s] página %d (skip=%d): %d registros (acumulado %d)",
                 tabela, pagina, skip, len(registros), total)

        # Commit parcial. A carga cheia de tickets são centenas de páginas, e
        # sem isso uma falha na página 400 descarta as 399 anteriores junto com
        # os minutos que elas custaram. Como o upsert é idempotente, o que já
        # está gravado não atrapalha a próxima execução. A marca de controle
        # continua saindo só no fim: carga parcial não pode adiantar o
        # incremental, ou o que faltou nunca mais seria lido.
        if pagina % _PAGINAS_POR_COMMIT == 0:
            conn.commit()
            log.debug("[%s] commit parcial em %d registros", tabela, total)

    qtd_snap = 0
    if obj.snapshot:
        colunas_copia = [n for n, _ in colunas_db if n != COL_TECNICA]
        qtd_snap = db.atualizar_snapshot(conn, schema, tabela, colunas_copia)

    db.registrar_controle(conn, schema, tabela, inicio_execucao, modo, total, "OK", None)
    conn.commit()

    if obj.snapshot:
        log.info("[%s] OK: %d registros; snapshot do dia com %d linhas",
                 tabela, total, qtd_snap)
    else:
        log.info("[%s] OK: %d registros", tabela, total)
    return total


def executar(modo: str, alvo: set[str] | None, criar_tabelas: bool) -> int:
    """Executa a ingestão dos objetos selecionados. Retorna o exit code."""
    cfg = carregar_config_blip()
    cfg_pg = carregar_config_pg()
    objetos = por_nome(alvo) if alvo else list(OBJETOS)
    if alvo and not objetos:
        log.error("Nenhum objeto chamado %s. Conhecidos: %s",
                  sorted(alvo), ", ".join(o.nome_logico for o in OBJETOS))
        return 2

    cliente = ClienteBlip(cfg)
    schema = cfg_pg.bronze_schema
    inicio_execucao = datetime.now(timezone.utc)
    resultados: list[tuple[str, str, int, str | None]] = []

    with db.conectar(cfg_pg) as conn:
        db.garantir_schema_e_controle(conn, schema)
        if criar_tabelas:
            if not BLIP_SQL.exists():
                log.error("%s não encontrado", BLIP_SQL)
                return 1
            db.aplicar_ddl(conn, str(BLIP_SQL))

        log.info("Ingestão Blip modo=%s | bot=%s | %d objeto(s) | schema=%s",
                 modo, cfg.identificador, len(objetos), schema)

        for obj in objetos:
            try:
                n = ingerir_objeto(conn, cliente, cfg, schema, obj, modo,
                                   inicio_execucao)
                resultados.append((obj.nome_logico, "OK", n, None))
            except Exception as exc:  # noqa: BLE001 — isola falhas por objeto
                conn.rollback()
                log.exception("[%s] FALHOU", obj.nome_logico)
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

    log.info("=" * 64)
    log.info("RESUMO Blip (modo=%s): %d OK (%d registros), %d falha(s)",
             modo, len(ok), sum(r[2] for r in ok), len(erros))
    for nome, _, n, _msg in ok:
        log.info("  OK   %-24s %d registros", nome, n)
    for nome, _, _n, msg in erros:
        log.error("  ERRO %-24s %s", nome, (msg or "")[:160])
    log.info("=" * 64)
    return 1 if erros else 0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ingestão Blip -> bronze (Postgres).")
    grupo = parser.add_mutually_exclusive_group(required=True)
    grupo.add_argument("--full", action="store_true",
                       help="Carga completa (lê a coleção inteira).")
    grupo.add_argument("--incremental", action="store_true",
                       help="Carga incremental (janela de BLIP_JANELA_DIAS).")
    parser.add_argument("--objetos", type=str, default=None,
                        help="Lista separada por vírgula (ex.: blip_tickets).")
    parser.add_argument("--criar-tabelas", action="store_true",
                        help="Aplica sql/bronze/blip.sql antes de ingerir.")
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
