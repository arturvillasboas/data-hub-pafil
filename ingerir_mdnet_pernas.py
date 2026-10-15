"""Ingestão das PERNAS do CDR da MDnet -> bronze.mdnet_cdr_pernas. Complementa o ingerir_mdnet.py.

O CSV sem filtro do painel traz uma perna por ligação e esconde as outras (ver o
comentário da tabela em sql/bronze/mdnet.sql). Este script exporta o mesmo relatório
filtrado por direção (inbound, outbound e internal), dia a dia, e guarda cada perna que
o painel devolve, com o filtro que a trouxe.

  python ingerir_mdnet_pernas.py --full [--criar-tabelas]
  python ingerir_mdnet_pernas.py --incremental
  python ingerir_mdnet_pernas.py --de 2026-03-01 [--ate 2026-03-31] [--direcoes outbound]

Mesma mecânica do ingerir_mdnet.py: um export por dia e por filtro, commit ao fim de
cada dia, upsert pela chave (protocolo, início, filtro, ordem), e por padrão a linha que
já existe é preservada (`--atualizar` sobrescreve). A marca de controle é própria
(mdnet_cdr_pernas), então o incremental das pernas anda separado do das ligações.
`--de` não mexe na marca.
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone

import psycopg
from psycopg import sql

from config.settings import ConfigMdnet, carregar_config_mdnet, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger
from ingerir_mdnet import MDNET_SQL, _Destino, _data, _periodo, gravar
from mdnet.api import DIRECOES, ClienteMdnet, ErroMdnet, janelas_diarias
from mdnet.objetos import CDR_PERNAS

log = get_logger("ingerir_mdnet_pernas")

NOME = CDR_PERNAS.nome_logico


def _contar_por_filtro(conn: psycopg.Connection, schema: str, de: date, ate: date) -> dict[str, int]:
    """Linhas da tabela no período, por filtro, para conferir com os cartões do painel."""
    consulta = sql.SQL(
        "SELECT filtro_direcao, count(*) FROM {sch}.{tab} "
        "WHERE data_hora_inicio >= %s AND data_hora_inicio < %s GROUP BY 1 ORDER BY 1"
    ).format(sch=sql.Identifier(schema), tab=sql.Identifier(NOME))
    with conn.cursor() as cur:
        cur.execute(
            consulta,
            (datetime.combine(de, datetime.min.time()),
             datetime.combine(ate + timedelta(days=1), datetime.min.time())),
        )
        return {linha[0]: int(linha[1]) for linha in cur.fetchall()}


def _ingerir_periodo(
    conn: psycopg.Connection, cfg: ConfigMdnet, destino: _Destino,
    de: date, ate: date, direcoes: list[str],
) -> tuple[dict[str, int], dict[str, int]]:
    """Exporta e grava o período. Devolve (novas por filtro, lidas por filtro)."""
    cliente = ClienteMdnet(cfg)
    data_extracao = datetime.now(timezone.utc)
    novas = {d: 0 for d in direcoes}
    lidas = {d: 0 for d in direcoes}
    janelas = list(janelas_diarias(de, ate))
    log.info("[%s] exportando %d dia(s) x %d filtro(s), de %s a %s",
             NOME, len(janelas), len(direcoes), de, ate)

    for numero, (inicio, fim) in enumerate(janelas, start=1):
        partes = []
        for direcao in direcoes:
            registros = cliente.exportar_cdr(inicio, fim, direcao=direcao)
            gravadas = gravar(conn, destino, registros, data_extracao, pagina=numero,
                              extras=(direcao,))
            novas[direcao] += gravadas
            lidas[direcao] += len(registros)
            partes.append(f"{direcao} {len(registros)}/{gravadas}")
        # Commit por dia, como no ingerir_mdnet.py.
        conn.commit()
        log.info("[%s] %s: linhas no CSV/novas: %s", NOME, inicio.date(), " | ".join(partes))
    return novas, lidas


def executar(
    modo: str, de: date | None, ate: date | None, direcoes: list[str],
    criar_tabelas: bool, atualizar: bool,
) -> int:
    cfg_pg = carregar_config_pg()
    schema = cfg_pg.bronze_schema
    inicio_execucao = datetime.now(timezone.utc)
    marca = de is None  # período manual não anda a marca (ver docstring)

    with db.conectar(cfg_pg) as conn:
        db.garantir_schema_e_controle(conn, schema)
        if criar_tabelas:
            db.aplicar_ddl(conn, str(MDNET_SQL))

        try:
            destino = _Destino(conn, schema, CDR_PERNAS, atualizar,
                               colunas_extra=("filtro_direcao",))
            cfg = carregar_config_mdnet()
            inicio, fim = _periodo(conn, cfg, schema, modo, de, ate, nome_logico=NOME)
            novas, lidas = _ingerir_periodo(conn, cfg, destino, inicio, fim, direcoes)

            if marca:
                db.registrar_controle(conn, schema, NOME, inicio_execucao, modo,
                                      sum(novas.values()), "OK", None)
                conn.commit()
            else:
                log.info("Período manual: a marca de controle NÃO foi alterada")

            no_banco = _contar_por_filtro(conn, schema, inicio, fim)
            log.info("=" * 64)
            log.info("RESUMO pernas MDnet (modo=%s), de %s a %s", modo, inicio, fim)
            for d in direcoes:
                log.info("  %-9s %6d lidas do painel, %6d novas, %6d no banco",
                         d, lidas[d], novas[d], no_banco.get(d, 0))
            log.info("=" * 64)
            return 0
        except (ErroMdnet, RuntimeError, psycopg.Error) as exc:
            conn.rollback()
            log.exception("[%s] FALHOU", NOME)
            if marca:
                try:
                    db.registrar_falha_controle(conn, schema, NOME, modo, str(exc))
                    conn.commit()
                except Exception:  # noqa: BLE001
                    log.error("[%s] não foi possível registrar a falha no controle", NOME)
            return 1


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ingestão das pernas do CDR da MDnet -> bronze.")
    parser.add_argument("--full", action="store_true",
                        help="Carga completa, desde MDNET_INICIO_HISTORICO.")
    parser.add_argument("--incremental", action="store_true",
                        help="Carga incremental (janela de MDNET_JANELA_DIAS).")
    parser.add_argument("--de", type=_data, default=None, metavar="AAAA-MM-DD",
                        help="Reexporta a partir desta data (não altera a marca de controle).")
    parser.add_argument("--ate", type=_data, default=None, metavar="AAAA-MM-DD",
                        help="Fim do período de --de. Padrão: hoje.")
    parser.add_argument("--direcoes", default=",".join(DIRECOES),
                        help=f"Filtros a exportar, separados por vírgula (padrão: {','.join(DIRECOES)}).")
    parser.add_argument("--criar-tabelas", action="store_true",
                        help="Aplica sql/bronze/mdnet.sql antes de ingerir.")
    parser.add_argument("--atualizar", action="store_true",
                        help="Sobrescreve as linhas que já existem (padrão: preserva).")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    args = parser.parse_args()

    if sum([args.full, args.incremental, args.de is not None]) != 1:
        parser.error("escolha exatamente um entre --full, --incremental e --de")
    if args.ate and not args.de:
        parser.error("--ate só faz sentido junto com --de")
    args.direcoes = [d.strip() for d in args.direcoes.split(",") if d.strip()]
    invalidas = [d for d in args.direcoes if d not in DIRECOES]
    if invalidas or not args.direcoes:
        parser.error(f"--direcoes aceita só {', '.join(DIRECOES)} (recebi {invalidas or 'nada'})")
    return args


def main() -> int:
    args = _parse_args()
    configurar_logging(args.verbose)
    modo = "full" if args.full else "incremental" if args.incremental else "manual"
    return executar(modo, args.de, args.ate, args.direcoes, args.criar_tabelas, args.atualizar)


if __name__ == "__main__":
    raise SystemExit(main())
