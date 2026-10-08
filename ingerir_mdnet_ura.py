"""Ingestão do relatório de URA da MDnet -> bronze.mdnet_ura. Irmão do ingerir_mdnet.py.

O relatório (/app/xml_cdr_ivr/) tem uma linha por PASSAGEM por um menu da URA: quem ligou,
o menu, o dígito e para onde a URA mandou. Este script baixa o mesmo CSV do botão de exportar
da tela, dia a dia, e guarda cada passagem.

  python ingerir_mdnet_ura.py --full [--criar-tabelas]
  python ingerir_mdnet_ura.py --incremental
  python ingerir_mdnet_ura.py --de 2026-09-01 [--ate 2026-09-30]

Mesma mecânica das outras cargas da MDnet: um export por dia, commit ao fim de cada dia,
upsert pela chave (ura, data, hora, origem, ordem), e por padrão a linha que já existe é
preservada (`--atualizar` sobrescreve). A marca de controle é própria (mdnet_ura), e `--de`
não mexe nela.
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone
from typing import Any, Sequence

import psycopg
from psycopg import sql

from config.settings import ConfigMdnet, carregar_config_mdnet, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger
from cvdw.tipos import parse_datahora
from ingerir_blip import montar_linha
from ingerir_mdnet import MDNET_SQL, _Destino, _data, _periodo
from mdnet.api import ClienteMdnet, ErroMdnet, janelas_diarias, parsear_csv
from mdnet.objetos import URA

log = get_logger("ingerir_mdnet_ura")

NOME = URA.nome_logico
PASTA_RELATORIO = "xml_cdr_ivr"
_FORMATO_FILTRO = "%Y-%m-%d %H:%M"


def filtros_do_dia(inicio: datetime, fim: datetime) -> list[tuple[str, str]]:
    """Campos do formulário da tela de URA, como o jQuery os serializa (IVR_MENU vazio = todas)."""
    return [
        ("CALLER_ID_NUMBER", ""),
        ("IVR_MENU", ""),
        ("DATA_INI", inicio.strftime(_FORMATO_FILTRO)),
        ("DATA_END", fim.strftime(_FORMATO_FILTRO)),
    ]


def selecionar(registros: Sequence[dict[str, str]]) -> list[tuple[dict[str, str], int]]:
    """Dá a cada linha do CSV o seu desempate: (linha, ordem).

    A chave de negócio é (ura, data, hora, origem). Duas linhas com a mesma chave são
    numeradas 0, 1, ... depois de ordenadas pelo conteúdo, para que a numeração não dependa da
    ordem do CSV daquele dia (que muda a cada exportação) e para que nenhuma se perca. Linha
    sem URA, data ou hora não tem chave e é ignorada com aviso.
    """
    grupos: dict[tuple[str, date, str, str], list[dict[str, str]]] = {}
    ignoradas = 0
    for reg in registros:
        ura = (reg.get("URA") or "").strip()
        dia = parse_datahora(reg.get("Data"))
        hora = (reg.get("Hora") or "").strip()
        if not ura or dia is None or not hora:
            ignoradas += 1
            if ignoradas <= 3:
                log.warning("Linha de URA ignorada (sem URA, data ou hora): URA=%r Data=%r Hora=%r",
                            reg.get("URA"), reg.get("Data"), reg.get("Hora"))
            continue
        grupos.setdefault((ura, dia.date(), hora, (reg.get("Origem") or "").strip()), []).append(reg)

    selecionadas: list[tuple[dict[str, str], int]] = []
    for grupo in grupos.values():
        grupo.sort(key=lambda r: tuple(sorted(r.items())))
        selecionadas.extend((reg, ordem) for ordem, reg in enumerate(grupo))
    if ignoradas:
        log.warning("%d linha(s) de URA sem chave foram ignoradas", ignoradas)
    return selecionadas


def gravar(
    conn: psycopg.Connection, destino: _Destino, registros: Sequence[dict[str, str]],
    data_extracao: datetime, pagina: int,
) -> int:
    """Grava um lote de linhas da URA. Devolve quantas entraram no banco (as novas, sem --atualizar)."""
    validas = selecionar(registros)
    if not validas:
        return 0
    pos_origem = [n for n, _ in destino.colunas_fonte].index("origem")
    linhas: list[list[Any]] = []
    for reg, ordem in validas:
        linha = montar_linha(reg, destino.colunas_fonte, destino.coluna_para_chave,
                             data_extracao, pagina)
        if linha[pos_origem] is None:  # '' vira NULL na montagem; a coluna da chave é NOT NULL
            linha[pos_origem] = ""
        linha.append(ordem)
        linhas.append(linha)
    return db.bulk_upsert(conn, destino.schema, destino.tabela, destino.colunas_insert,
                          linhas, destino.chave, atualizar=destino.atualizar)


def _contar_por_ura(conn: psycopg.Connection, schema: str, de: date, ate: date) -> dict[str, int]:
    consulta = sql.SQL(
        "SELECT ura, count(*) FROM {sch}.{tab} WHERE data >= %s AND data <= %s GROUP BY 1 ORDER BY 1"
    ).format(sch=sql.Identifier(schema), tab=sql.Identifier(NOME))
    with conn.cursor() as cur:
        cur.execute(consulta, (de, ate))
        return {linha[0]: int(linha[1]) for linha in cur.fetchall()}


def _ingerir_periodo(
    conn: psycopg.Connection, cfg: ConfigMdnet, destino: _Destino, de: date, ate: date,
) -> tuple[int, int]:
    """Exporta e grava o período. Devolve (novas, lidas)."""
    cliente = ClienteMdnet(cfg)
    data_extracao = datetime.now(timezone.utc)
    novas = lidas = 0
    janelas = list(janelas_diarias(de, ate))
    log.info("[%s] exportando %d dia(s), de %s a %s", NOME, len(janelas), de, ate)

    for numero, (inicio, fim) in enumerate(janelas, start=1):
        corpo = cliente.exportar_relatorio_bruto(PASTA_RELATORIO, filtros_do_dia(inicio, fim))
        registros = parsear_csv(corpo, URA.campos)
        gravadas = gravar(conn, destino, registros, data_extracao, pagina=numero)
        novas += gravadas
        lidas += len(registros)
        conn.commit()  # commit por dia, como nas outras cargas
        log.info("[%s] %s: %d linha(s) no CSV, %d novas (acumulado %d)",
                 NOME, inicio.date(), len(registros), gravadas, novas)
    return novas, lidas


def executar(
    modo: str, de: date | None, ate: date | None, criar_tabelas: bool, atualizar: bool,
) -> int:
    cfg_pg = carregar_config_pg()
    schema = cfg_pg.bronze_schema
    inicio_execucao = datetime.now(timezone.utc)
    marca = de is None  # período manual não anda a marca

    with db.conectar(cfg_pg) as conn:
        db.garantir_schema_e_controle(conn, schema)
        if criar_tabelas:
            db.aplicar_ddl(conn, str(MDNET_SQL))

        try:
            destino = _Destino(conn, schema, URA, atualizar)
            cfg = carregar_config_mdnet()
            inicio, fim = _periodo(conn, cfg, schema, modo, de, ate, nome_logico=NOME)
            novas, lidas = _ingerir_periodo(conn, cfg, destino, inicio, fim)

            if marca:
                db.registrar_controle(conn, schema, NOME, inicio_execucao, modo, novas, "OK", None)
                conn.commit()
            else:
                log.info("Período manual: a marca de controle NÃO foi alterada")

            no_banco = _contar_por_ura(conn, schema, inicio, fim)
            log.info("=" * 64)
            log.info("RESUMO URA MDnet (modo=%s), de %s a %s: %d lidas do painel, %d novas",
                     modo, inicio, fim, lidas, novas)
            for ura, n in no_banco.items():
                log.info("  %-18s %6d no banco", ura, n)
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
    parser = argparse.ArgumentParser(description="Ingestão do relatório de URA da MDnet -> bronze.")
    parser.add_argument("--full", action="store_true",
                        help="Carga completa, desde MDNET_INICIO_HISTORICO.")
    parser.add_argument("--incremental", action="store_true",
                        help="Carga incremental (janela de MDNET_JANELA_DIAS).")
    parser.add_argument("--de", type=_data, default=None, metavar="AAAA-MM-DD",
                        help="Reexporta a partir desta data (não altera a marca de controle).")
    parser.add_argument("--ate", type=_data, default=None, metavar="AAAA-MM-DD",
                        help="Fim do período de --de. Padrão: hoje.")
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
    return args


def main() -> int:
    args = _parse_args()
    configurar_logging(args.verbose)
    modo = "full" if args.full else "incremental" if args.incremental else "manual"
    return executar(modo, args.de, args.ate, args.criar_tabelas, args.atualizar)


if __name__ == "__main__":
    raise SystemExit(main())
