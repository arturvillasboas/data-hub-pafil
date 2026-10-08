"""Ingestão do CDR da MDnet (DDA Telecom) -> bronze (Postgres). Irmão do ingerir_blip.py.

O painel não tem API, então a fonte é o CSV do relatório de chamadas (ver
mdnet/api.py). A carga anda dia a dia: um export por dia, upsert idempotente pela
chave (protocolo, início da chamada, ordem) e commit ao fim de cada dia. Uma falha no meio
não descarta o que já foi gravado, e rodar de novo só reescreve as mesmas linhas.

  python ingerir_mdnet.py --full [--criar-tabelas]       # desde MDNET_INICIO_HISTORICO
  python ingerir_mdnet.py --incremental                  # últimos MDNET_JANELA_DIAS dias
  python ingerir_mdnet.py --de 2026-03-01 [--ate 2026-03-31]   # reparo de um período
  python ingerir_mdnet.py --arquivo reconciliacao/cdr_mdnet_exemplo.csv   # CSV local
  python ingerir_mdnet.py --de 2026-03-01 --atualizar    # sobrescreve o que já existe

`--de` e `--arquivo` não mexem na marca de controle: carga parcial não pode adiantar
o incremental, ou os dias que ficaram de fora nunca mais seriam lidos.

Por padrão a linha que já existe é PRESERVADA, não sobrescrita. O painel devolve, para
~0,5% das chamadas, uma de duas pernas escolhida ao acaso a cada exportação (a do
ramal, como Saída Atendida, ou a do tronco, como Entrada Não Atendida), então
sobrescrever faria essas linhas oscilarem a cada incremental. `--atualizar` força a
sobrescrita, para quando se quer de propósito refazer uma coluna nova.

O acesso ao banco é o `cvdw.db` (só ganhou o parâmetro `atualizar` no bulk_upsert).
"""
from __future__ import annotations

import argparse
import hashlib
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Sequence

import psycopg
from psycopg import sql

from config.settings import (
    ConfigMdnet, carregar_config_mdnet, carregar_config_pg,
)
from cvdw import db
from cvdw.db import COL_DADOS_BRUTOS, COL_EXTRACAO, COL_HASH, COL_PAGINA, COL_TECNICA
from cvdw.log import configurar_logging, get_logger
from cvdw.tipos import parse_datahora
# montar_linha é genérica (registro + mapa de colunas -> valores na ordem do INSERT);
# reaproveitar evita uma cópia que um dia divergiria da do Blip.
from ingerir_blip import montar_linha
from mdnet.api import ClienteMdnet, ErroMdnet, janelas_diarias, parsear_csv
from mdnet.objetos import CDR, ObjetoMdnet

log = get_logger("ingerir_mdnet")

RAIZ = Path(__file__).resolve().parent
MDNET_SQL = RAIZ / "sql" / "bronze" / "mdnet.sql"

_META = {COL_TECNICA, COL_HASH, COL_EXTRACAO, COL_PAGINA, COL_DADOS_BRUTOS}

_CAMPO_PROTOCOLO = "Protocolo"
_CAMPO_INICIO = "Data Hora Início Chamada"

# Campos que entram no aviso de linha ignorada. Fora de propósito: Nome, Origem e
# Destino, que carregam telefone de cliente.
_CAMPOS_DIAGNOSTICO = (
    "Protocolo", "Estado", "Direção", "Tipo", "Ramal", "Data Hora Início Chamada",
    "Hora Fim", "Tempo Falado", "Motivo Desligamento", "Lado Desligamento",
)
_MAX_LINHAS_DIAGNOSTICO = 3


class _Destino:
    """Metadados da tabela bronze, lidos uma vez e usados em todos os dias."""

    def __init__(
        self, conn: psycopg.Connection, schema: str, obj: ObjetoMdnet, atualizar: bool,
        colunas_extra: Sequence[str] = (),
    ) -> None:
        self.schema = schema
        self.atualizar = atualizar
        self.tabela = obj.nome_logico
        if not db.tabela_existe(conn, schema, self.tabela):
            raise RuntimeError(
                f"Tabela {schema}.{self.tabela} não existe. Rode com --criar-tabelas "
                f"para aplicar {MDNET_SQL.name}."
            )

        colunas_db = db.colunas_tabela(conn, schema, self.tabela)
        self.coluna_para_chave = {c: k for k, c in obj.campos.items()}
        self.colunas_fonte = [
            (n, t) for n, t in colunas_db if n not in _META and n in self.coluna_para_chave
        ]
        faltando = set(obj.campos.values()) - {n for n, _ in self.colunas_fonte}
        if faltando:
            raise RuntimeError(
                f"{schema}.{self.tabela} não tem as colunas {sorted(faltando)}. O mapa "
                f"em mdnet/objetos.py e o {MDNET_SQL.name} estão fora de sincronia."
            )

        self.chave = db.chave_upsert(conn, schema, self.tabela)
        if not self.chave:
            raise RuntimeError(f"Índice único ux_{self.tabela}_chave não encontrado.")
        if "ordem" not in self.chave or "ordem" not in {n for n, _ in colunas_db}:
            raise RuntimeError(
                f"{schema}.{self.tabela} ainda está no schema antigo, sem a coluna "
                f"`ordem` na chave. Rode com --criar-tabelas para aplicar {MDNET_SQL.name}."
            )

        # Colunas que não vêm do CSV e entram depois de `ordem`, na ordem em que
        # `gravar` recebe os valores (hoje só filtro_direcao, nas pernas).
        ausentes = [c for c in colunas_extra if c not in {n for n, _ in colunas_db}]
        if ausentes:
            raise RuntimeError(
                f"{schema}.{self.tabela} não tem as colunas {ausentes}. Rode com "
                f"--criar-tabelas para aplicar {MDNET_SQL.name}."
            )
        self.colunas_insert = [n for n, _ in self.colunas_fonte] + [
            COL_DADOS_BRUTOS, COL_HASH, COL_EXTRACAO, COL_PAGINA, "ordem", *colunas_extra
        ]


def _protocolo_sintetico(reg: dict[str, str]) -> str:
    """Chave estável para a linha que o painel mandou sem protocolo.

    É um hash de todos os campos da linha, então reexportar o mesmo dia gera a mesma
    chave e o upsert continua idempotente. O prefixo SEM- deixa o valor inconfundível
    com um protocolo de verdade (que é só dígitos).
    """
    base = "|".join(f"{k}={reg[k]}" for k in sorted(reg))
    return "SEM-" + hashlib.md5(base.encode("utf-8")).hexdigest()[:16]


def _selecionar_validas(
    registros: Sequence[dict[str, str]],
) -> list[tuple[dict[str, str], str, int]]:
    """Escolhe as linhas a gravar e dá a cada uma a sua chave: (linha, protocolo, ordem).

    Três cuidados, por razões diferentes:

    - Linha sem início legível não tem chave de negócio e é ignorada com aviso.
    - Linha sem protocolo MAS com início é gravada com um protocolo sintético. Existe
      de verdade: tentativas de ligação automática de saída que o PABX derruba na
      hora (motivo MANDATORY_IE_MISSING, início igual ao fim) saem do painel sem
      protocolo. O painel as conta nos totais, então descartá-las faz o banco
      divergir dele. O `_dados_brutos` guarda a linha como veio, com protocolo vazio.
    - Protocolo e início iguais NÃO significam a mesma chamada. Na carga de out/2026
      apareceram 3 pares assim, com origem e destino diferentes: são chamadas
      distintas, e unificá-las perdia uma e ainda fazia a linha que sobrevivia mudar
      conforme a ordem do CSV daquele dia. Por isso as que colidem são ordenadas pelo
      conteúdo e numeradas 0, 1, ... (a coluna `ordem`), o que dá a mesma numeração a
      cada exportação. Também evita o erro do Postgres "cannot affect row a second
      time", que o ON CONFLICT DO UPDATE lança quando vê a mesma chave duas vezes no
      mesmo INSERT. A sobreposição de um instante entre dias vizinhos não entra nisso:
      cai em CSVs separados, e o upsert entre lotes resolve.
    """
    por_chave: dict[tuple[str, datetime], list[dict[str, str]]] = {}
    sem_chave = 0
    sinteticos = 0
    for reg in registros:
        protocolo = (reg.get(_CAMPO_PROTOCOLO) or "").strip()
        inicio = parse_datahora(reg.get(_CAMPO_INICIO))
        if inicio is not None and not protocolo:
            protocolo = _protocolo_sintetico(reg)
            sinteticos += 1
        if not protocolo or inicio is None:
            sem_chave += 1
            # Mostra a linha (sem origem/destino, que são telefone de cliente) para
            # dar para investigar o que o painel mandou. Só as primeiras de cada lote.
            if sem_chave <= _MAX_LINHAS_DIAGNOSTICO:
                log.warning("Linha ignorada: %s",
                            {c: reg.get(c, "") for c in _CAMPOS_DIAGNOSTICO})
            continue
        por_chave.setdefault((protocolo, inicio), []).append(reg)

    selecionadas: list[tuple[dict[str, str], str, int]] = []
    colididas = 0
    for (protocolo, inicio), grupo in por_chave.items():
        # Ordena pelo conteúdo, não pela posição no CSV: a posição muda a cada export.
        grupo.sort(key=lambda r: tuple(sorted(r.items())))
        if len(grupo) > 1:
            colididas += len(grupo) - 1
            if colididas <= _MAX_LINHAS_DIAGNOSTICO:
                # Só os NOMES dos campos que diferem (os valores podem ser telefone).
                diferem = sorted(c for c in grupo[0] if len({r.get(c) for r in grupo}) > 1)
                log.info("Protocolo %s e início %s repetidos em %d linha(s): %s",
                         protocolo, inicio, len(grupo),
                         f"campos diferentes: {diferem}" if diferem else "linhas idênticas")
        for ordem, reg in enumerate(grupo):
            selecionadas.append((reg, protocolo, ordem))

    if sem_chave:
        log.warning("%d linha(s) sem início legível foram ignoradas", sem_chave)
    if sinteticos:
        log.info("%d linha(s) sem protocolo gravadas com chave sintética (SEM-...)",
                 sinteticos)
    if colididas:
        log.info("%d linha(s) dividem protocolo e início com outra e receberam ordem > 0",
                 colididas)
    return selecionadas


def gravar(
    conn: psycopg.Connection,
    destino: _Destino,
    registros: Sequence[dict[str, str]],
    data_extracao: datetime,
    pagina: int,
    extras: Sequence[Any] = (),
) -> int:
    """Grava um lote de linhas do CSV. Devolve quantas linhas entraram no banco.

    `extras` são os valores de `colunas_extra` do destino, iguais para o lote todo.

    Sem `--atualizar` conta só as novas: a que já existia fica como estava.
    """
    validas = _selecionar_validas(registros)
    if not validas:
        return 0

    pos_protocolo = [n for n, _ in destino.colunas_fonte].index("protocolo")
    linhas: list[list[Any]] = []
    for reg, protocolo, ordem in validas:
        linha = montar_linha(reg, destino.colunas_fonte, destino.coluna_para_chave,
                             data_extracao, pagina)
        # O hash e o JSON cru já saíram da linha como veio; só a coluna ganha a chave.
        linha[pos_protocolo] = protocolo
        linha.append(ordem)
        linha.extend(extras)
        linhas.append(linha)
    return db.bulk_upsert(conn, destino.schema, destino.tabela, destino.colunas_insert,
                          linhas, destino.chave, atualizar=destino.atualizar)


def _periodo(
    conn: psycopg.Connection, cfg: ConfigMdnet, schema: str, modo: str,
    de: date | None, ate: date | None, nome_logico: str = CDR.nome_logico,
) -> tuple[date, date]:
    """Decide o intervalo de dias a exportar. A marca de controle é a de `nome_logico`."""
    hoje = date.today()
    if de:
        return de, ate or hoje
    if modo == "incremental":
        ultima = db.ler_data_referencia(conn, schema, nome_logico)
        if ultima:
            inicio = (ultima - timedelta(days=cfg.janela_dias)).date()
            log.info("[%s] incremental desde %s (%d dias de folga)",
                     nome_logico, inicio, cfg.janela_dias)
            return inicio, hoje
        log.info("[%s] sem marca anterior, carga completa", nome_logico)
    return cfg.inicio_historico, hoje


def _contar_periodo(conn: psycopg.Connection, schema: str, de: date, ate: date) -> int:
    """Conta no banco as linhas do período, para conferir com o total do painel."""
    consulta = sql.SQL(
        "SELECT count(*) FROM {sch}.{tab} "
        "WHERE data_hora_inicio >= %s AND data_hora_inicio < %s"
    ).format(sch=sql.Identifier(schema), tab=sql.Identifier(CDR.nome_logico))
    with conn.cursor() as cur:
        cur.execute(
            consulta,
            (datetime.combine(de, datetime.min.time()),
             datetime.combine(ate + timedelta(days=1), datetime.min.time())),
        )
        return int(cur.fetchone()[0])


def _ingerir_arquivo(conn: psycopg.Connection, destino: _Destino, caminho: Path) -> int:
    """Carrega um CSV local, sem tocar no painel nem na marca de controle."""
    registros = parsear_csv(caminho.read_bytes())
    total = gravar(conn, destino, registros, datetime.now(timezone.utc), pagina=1)
    conn.commit()
    log.info("[%s] %s: %d linha(s) lidas, %d novas",
             CDR.nome_logico, caminho.name, len(registros), total)
    return total


def _ingerir_periodo(
    conn: psycopg.Connection, cfg: ConfigMdnet, destino: _Destino, de: date, ate: date,
) -> tuple[int, int]:
    """Exporta e grava o período. Devolve (linhas gravadas, linhas lidas do CSV)."""
    cliente = ClienteMdnet(cfg)
    data_extracao = datetime.now(timezone.utc)
    total = 0
    lidas = 0
    janelas = list(janelas_diarias(de, ate))
    log.info("[%s] exportando %d dia(s), de %s a %s", CDR.nome_logico, len(janelas), de, ate)

    for numero, (inicio, fim) in enumerate(janelas, start=1):
        registros = cliente.exportar_cdr(inicio, fim)
        gravadas = gravar(conn, destino, registros, data_extracao, pagina=numero)
        total += gravadas
        lidas += len(registros)
        # Commit por dia: ver o docstring do módulo.
        conn.commit()
        log.info("[%s] %s: %d linha(s) no CSV, %d novas (acumulado %d)",
                 CDR.nome_logico, inicio.date(), len(registros), gravadas, total)
    return total, lidas


def executar(
    modo: str, de: date | None, ate: date | None, arquivo: Path | None,
    criar_tabelas: bool, atualizar: bool = False,
) -> int:
    """Executa a ingestão. Retorna o exit code."""
    cfg_pg = carregar_config_pg()
    schema = cfg_pg.bronze_schema
    inicio_execucao = datetime.now(timezone.utc)
    # Só carga completa ou incremental anda a marca de controle (ver docstring).
    marca = arquivo is None and de is None

    with db.conectar(cfg_pg) as conn:
        db.garantir_schema_e_controle(conn, schema)
        if criar_tabelas:
            if not MDNET_SQL.exists():
                log.error("%s não encontrado", MDNET_SQL)
                return 1
            db.aplicar_ddl(conn, str(MDNET_SQL))

        try:
            destino = _Destino(conn, schema, CDR, atualizar)

            if arquivo is not None:
                total = _ingerir_arquivo(conn, destino, arquivo)
                log.info("Carga de arquivo concluída: %d linha(s)", total)
                return 0

            cfg = carregar_config_mdnet()
            inicio, fim = _periodo(conn, cfg, schema, modo, de, ate)
            total, lidas = _ingerir_periodo(conn, cfg, destino, inicio, fim)

            if marca:
                db.registrar_controle(conn, schema, CDR.nome_logico, inicio_execucao,
                                      modo, total, "OK", None)
                conn.commit()
            else:
                log.info("Período manual: a marca de controle NÃO foi alterada")

            no_banco = _contar_periodo(conn, schema, inicio, fim)
            log.info("=" * 64)
            log.info("RESUMO MDnet (modo=%s): %d linha(s) lidas do painel, %d novas",
                     modo, lidas, total)
            log.info("  No banco, de %s a %s: %d linha(s). Compare com o total do painel.",
                     inicio, fim, no_banco)
            log.info("=" * 64)
            return 0
        except (ErroMdnet, RuntimeError, psycopg.Error) as exc:
            conn.rollback()
            log.exception("[%s] FALHOU", CDR.nome_logico)
            if marca:
                try:
                    db.registrar_falha_controle(conn, schema, CDR.nome_logico, modo, str(exc))
                    conn.commit()
                except Exception:  # noqa: BLE001
                    log.error("[%s] não foi possível registrar a falha no controle",
                              CDR.nome_logico)
            return 1


def _data(texto: str) -> date:
    try:
        return date.fromisoformat(texto)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{texto!r} não é uma data AAAA-MM-DD") from exc


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ingestão do CDR da MDnet -> bronze (Postgres).")
    parser.add_argument("--full", action="store_true",
                        help="Carga completa, desde MDNET_INICIO_HISTORICO.")
    parser.add_argument("--incremental", action="store_true",
                        help="Carga incremental (janela de MDNET_JANELA_DIAS).")
    parser.add_argument("--de", type=_data, default=None, metavar="AAAA-MM-DD",
                        help="Reexporta a partir desta data (não altera a marca de controle).")
    parser.add_argument("--ate", type=_data, default=None, metavar="AAAA-MM-DD",
                        help="Fim do período de --de. Padrão: hoje.")
    parser.add_argument("--arquivo", type=Path, default=None,
                        help="Carrega um CSV local em vez de ir ao painel.")
    parser.add_argument("--criar-tabelas", action="store_true",
                        help="Aplica sql/bronze/mdnet.sql antes de ingerir.")
    parser.add_argument("--atualizar", action="store_true",
                        help="Sobrescreve as linhas que já existem (padrão: preserva).")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    args = parser.parse_args()

    escolhas = [args.full, args.incremental, args.de is not None, args.arquivo is not None]
    if sum(escolhas) != 1:
        parser.error("escolha exatamente um entre --full, --incremental, --de e --arquivo")
    if args.ate and not args.de:
        parser.error("--ate só faz sentido junto com --de")
    if args.arquivo and not args.arquivo.is_file():
        parser.error(f"arquivo não encontrado: {args.arquivo}")
    return args


def main() -> int:
    args = _parse_args()
    configurar_logging(args.verbose)
    modo = "full" if args.full else "incremental" if args.incremental else "manual"
    return executar(modo, args.de, args.ate, args.arquivo, args.criar_tabelas,
                    args.atualizar)


if __name__ == "__main__":
    raise SystemExit(main())
