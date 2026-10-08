"""Descobre qual valor do filtro de Direção do painel devolve as chamadas Interna. Só leitura.

  python sondar_direcao_mdnet.py [--de 2026-09-29] [--ate 2026-09-30]

Exporta o mesmo período uma vez por candidato e mostra quantas linhas voltaram e quais
valores a coluna Direção tem nelas. O valor `local` já se sabe que devolve zero. Não grava
nada no banco e não imprime telefone.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import date

from config.settings import carregar_config_mdnet
from cvdw.log import configurar_logging, get_logger
from mdnet.api import ClienteMdnet, ErroMdnet, janelas_diarias

log = get_logger("sondar_direcao_mdnet")

# Palavras que um painel baseado em FusionPBX/FreeSWITCH, ou o próprio rótulo da tela,
# poderia usar para ligação entre ramais.
CANDIDATOS = (
    "local", "internal", "interna", "Interna", "intern", "interno", "inner", "internal_call",
    "Local", "LOCAL", "inbound", "outbound",
)


def _data(texto: str) -> date:
    try:
        return date.fromisoformat(texto)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{texto!r} não é uma data AAAA-MM-DD") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description="Sonda os valores do filtro de Direção.")
    parser.add_argument("--de", type=_data, default=date(2026, 9, 29), metavar="AAAA-MM-DD")
    parser.add_argument("--ate", type=_data, default=date(2026, 9, 30), metavar="AAAA-MM-DD")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    args = parser.parse_args()
    configurar_logging(args.verbose)

    cliente = ClienteMdnet(carregar_config_mdnet())
    print(f"\nPeríodo {args.de} a {args.ate}. Linhas devolvidas por valor do filtro:\n")
    print(f"  {'valor':16s} {'linhas':>7s}   Direção nas linhas")
    print(f"  {'-' * 16} {'-' * 7}   {'-' * 30}")

    # Sem filtro, para ter a referência do que o período contém.
    linhas = []
    for inicio, fim in janelas_diarias(args.de, args.ate):
        linhas += cliente.exportar_cdr(inicio, fim)
    contagem = Counter(r.get("Direção", "") for r in linhas)
    print(f"  {'(sem filtro)':16s} {len(linhas):7d}   {dict(contagem)}")

    for valor in CANDIDATOS:
        linhas = []
        try:
            for inicio, fim in janelas_diarias(args.de, args.ate):
                linhas += cliente.exportar_cdr(inicio, fim, direcao=valor, validar=False)
        except ErroMdnet as exc:
            print(f"  {valor:16s} {'erro':>7s}   {str(exc)[:70]}")
            continue
        contagem = Counter(r.get("Direção", "") for r in linhas)
        print(f"  {valor:16s} {len(linhas):7d}   {dict(contagem)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
