"""Compara duas exportações do mesmo período do painel da MDnet, linha a linha.

  python diagnosticar_cdr_mdnet.py --de 2026-03-17 --ate 2026-04-15 [--espera 600]

Responde a uma pergunta só: a mesma chamada sai igual em duas exportações? Se não
sai, a classificação (Direção, Estado) do painel não é estável, e qualquer número
construído em cima dela muda de uma carga para outra.

Faz a rodada 1 do período inteiro, espera `--espera` segundos (0 por padrão), faz a
rodada 2 e compara pela chave de negócio. Não usa o banco, só o login do painel
(MDNET_* no .env). Imprime nomes de campos e, para os campos que não são telefone,
os valores. Origem, destino e nome nunca aparecem.
"""
from __future__ import annotations

import argparse
import time
from collections import Counter
from datetime import date, datetime
from typing import Any

from config.settings import carregar_config_mdnet
from cvdw.log import configurar_logging, get_logger
from cvdw.tipos import parse_datahora
from ingerir_mdnet import _CAMPO_INICIO, _selecionar_validas
from mdnet.api import DIRECOES, ClienteMdnet, janelas_diarias

log = get_logger("diagnosticar_cdr_mdnet")

Chave = tuple[str, datetime, int]

# Campos cujo valor pode ser mostrado. Os demais só aparecem pelo nome.
_CAMPOS_SEGUROS = (
    "Estado", "Direção", "Tipo", "Ramal", "Hora Fim", "Tempo Falado",
    "TIPO TRANSFERÊNCIA", "Motivo Desligamento", "Lado Desligamento",
)


def exportar_periodo(
    cliente: ClienteMdnet, de: date, ate: date, direcao: str | None = None,
) -> dict[Chave, dict[str, str]]:
    """Exporta o período dia a dia e indexa as linhas pela chave de negócio."""
    saida: dict[Chave, dict[str, str]] = {}
    for inicio, fim in janelas_diarias(de, ate):
        linhas = cliente.exportar_cdr(inicio, fim, direcao=direcao)
        for reg, protocolo, ordem in _selecionar_validas(linhas):
            saida[(protocolo, parse_datahora(reg[_CAMPO_INICIO]), ordem)] = reg
    return saida


def comparar(
    a: dict[Chave, dict[str, str]], b: dict[Chave, dict[str, str]]
) -> dict[str, Any]:
    """Compara duas rodadas. Devolve só contagens e as diferenças campo a campo."""
    so_a = sorted(set(a) - set(b))
    so_b = sorted(set(b) - set(a))
    diferentes: list[tuple[Chave, dict[str, tuple[str, str]]]] = []
    por_campo: Counter[str] = Counter()
    transicoes: dict[str, Counter[tuple[str, str]]] = {"Direção": Counter(), "Estado": Counter()}

    for chave in sorted(set(a) & set(b)):
        ra, rb = a[chave], b[chave]
        difs = {c: (ra.get(c, ""), rb.get(c, ""))
                for c in sorted(set(ra) | set(rb)) if ra.get(c, "") != rb.get(c, "")}
        if not difs:
            continue
        diferentes.append((chave, difs))
        for campo, par in difs.items():
            por_campo[campo] += 1
            if campo in transicoes:
                transicoes[campo][par] += 1

    return {"so_a": so_a, "so_b": so_b, "diferentes": diferentes,
            "por_campo": por_campo, "transicoes": transicoes}


def imprimir(a: dict, b: dict, r: dict[str, Any], max_exemplos: int) -> None:
    print(f"\nRodada 1: {len(a)} linha(s). Rodada 2: {len(b)} linha(s).")
    print(f"Só na rodada 1: {len(r['so_a'])}. Só na rodada 2: {len(r['so_b'])}.")
    print(f"Linhas em comum com algum campo diferente: {len(r['diferentes'])}")

    if r["por_campo"]:
        print("\nCampos que mudaram (quantas linhas):")
        for campo, n in r["por_campo"].most_common():
            print(f"  {campo}: {n}")
    for campo, contagem in r["transicoes"].items():
        if contagem:
            print(f"\nMudanças de {campo} (rodada 1 -> rodada 2):")
            for (de, para), n in contagem.most_common():
                print(f"  {de or '(vazio)'} -> {para or '(vazio)'}: {n}")

    if r["diferentes"]:
        print(f"\nPrimeiras {min(max_exemplos, len(r['diferentes']))} linhas diferentes:")
        for (protocolo, inicio, ordem), difs in r["diferentes"][:max_exemplos]:
            partes = [f"{c}: {va or '(vazio)'} -> {vb or '(vazio)'}" if c in _CAMPOS_SEGUROS
                      else f"{c}: mudou" for c, (va, vb) in difs.items()]
            print(f"  {protocolo} {inicio} ordem={ordem} | " + "; ".join(partes))

    if not (r["so_a"] or r["so_b"] or r["diferentes"]):
        print("\nAs duas rodadas são idênticas: o CDR do painel é estável neste intervalo.")


def _data(texto: str) -> date:
    try:
        return date.fromisoformat(texto)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{texto!r} não é uma data AAAA-MM-DD") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description="Compara duas exportações do CDR da MDnet.")
    parser.add_argument("--de", type=_data, required=True, metavar="AAAA-MM-DD")
    parser.add_argument("--ate", type=_data, required=True, metavar="AAAA-MM-DD")
    parser.add_argument("--espera", type=int, default=0, metavar="SEGUNDOS",
                        help="Pausa entre a rodada 1 e a 2 (padrão 0).")
    parser.add_argument("--max-exemplos", type=int, default=15)
    parser.add_argument("--direcao", choices=DIRECOES, default=None,
                        help="Compara exportações filtradas por esta direção (padrão: sem filtro).")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    args = parser.parse_args()
    configurar_logging(args.verbose)

    cliente = ClienteMdnet(carregar_config_mdnet())
    log.info("Rodada 1: exportando %s a %s", args.de, args.ate)
    a = exportar_periodo(cliente, args.de, args.ate, args.direcao)
    if args.espera:
        log.info("Aguardando %d s antes da rodada 2", args.espera)
        time.sleep(args.espera)
    log.info("Rodada 2: exportando %s a %s", args.de, args.ate)
    b = exportar_periodo(cliente, args.de, args.ate, args.direcao)

    imprimir(a, b, comparar(a, b), args.max_exemplos)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
