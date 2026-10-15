"""Baixa o CSV, a tabela e os cartões de um relatório do painel da MDnet. Somente leitura.

  python baixar_relatorio_mdnet.py --pasta xml_cdr_ivr --de 2026-09-01 --ate 2026-09-30
  python baixar_relatorio_mdnet.py --pasta xml_cdr_ivr --de 2026-09-01 --ate 2026-09-30 \\
      --campo IVR_MENU=4859e087-267a-4682-9b85-68dc8abfa60d

Faz o mesmo que a tela faz ao clicar em Pesquisar (view.php e charts.php) e em exportar
(model.php?file=eCSV), com os campos do formulário. Salva os três arquivos e imprime o
cabeçalho do CSV e o texto dos cartões, para ver as colunas de um relatório que ainda não
temos na bronze. Os campos padrão de cada relatório vêm do formulário da tela dele (lido do
HTML em 05/out/2026); `--campo NOME=VALOR` troca ou acrescenta um.

O CSV e o HTML trazem telefone de cliente. Ficam em reconciliacao/ (CSV) e em
reconciliacao/painel_mdnet/ (HTML), as duas já no .gitignore. Não grava nada no banco.
"""
from __future__ import annotations

import argparse
import re
from datetime import date, datetime, time
from pathlib import Path

from config.settings import carregar_config_mdnet
from cvdw.log import configurar_logging, get_logger
from mdnet.api import ClienteMdnet, ErroMdnet, _decodificar

log = get_logger("baixar_relatorio_mdnet")

RAIZ = Path(__file__).resolve().parent
PASTA_CSV = RAIZ / "reconciliacao"
PASTA_HTML = PASTA_CSV / "painel_mdnet"

# Campos do formulário de cada relatório, na ordem em que o jQuery os serializa. As datas
# entram à parte. IVR_MENU vazio é "todas as URAs".
CAMPOS_PADRAO: dict[str, list[tuple[str, str]]] = {
    "xml_cdr_ivr": [("CALLER_ID_NUMBER", ""), ("IVR_MENU", "")],
}
_FORMATO = "%Y-%m-%d %H:%M"


def _data(texto: str) -> date:
    try:
        return date.fromisoformat(texto)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{texto!r} não é uma data AAAA-MM-DD") from exc


def montar_filtros(
    pasta: str, de: date, ate: date, extras: list[str],
) -> list[tuple[str, str]]:
    """Campos do POST: os do relatório, com as datas no lugar certo e os --campo aplicados."""
    base = CAMPOS_PADRAO.get(pasta)
    if base is None and not extras:
        raise ErroMdnet(
            f"Não conheço os campos do relatório {pasta!r}. Passe-os com --campo NOME=VALOR "
            f"(os nomes estão no formulário da tela dele)."
        )
    campos = dict(base or [])
    for extra in extras:
        nome, separador, valor = extra.partition("=")
        if not separador or not nome:
            raise ErroMdnet(f"--campo {extra!r} não está no formato NOME=VALOR")
        campos[nome] = valor
    # Fim às 23:59, como a tela: o filtro do painel tem precisão de minuto.
    campos["DATA_INI"] = datetime.combine(de, time(0, 0)).strftime(_FORMATO)
    campos["DATA_END"] = datetime.combine(ate, time(23, 59)).strftime(_FORMATO)

    # A tela serializa nesta ordem: campos do relatório e depois as datas dentro do form. A ordem
    # não muda o resultado, mas deixa o POST parecido com o do navegador.
    ordem = [n for n, _ in (base or [])] + [n for n in campos if n not in dict(base or [])]
    ordem = [n for n in ordem if n not in ("DATA_INI", "DATA_END")]
    return [(n, campos[n]) for n in ordem] + [("DATA_INI", campos["DATA_INI"]),
                                              ("DATA_END", campos["DATA_END"])]


def texto_visivel(html: str, limite: int = 900) -> str:
    """Tira as tags e junta o texto, para ler os cartões sem abrir o arquivo."""
    sem_script = re.sub(r"(?is)<(script|style).*?</\1>", " ", html)
    texto = re.sub(r"(?s)<[^>]+>", " ", sem_script)
    return re.sub(r"\s+", " ", texto).strip()[:limite]


def main() -> int:
    parser = argparse.ArgumentParser(description="Baixa CSV, tabela e cartões de um relatório da MDnet.")
    parser.add_argument("--pasta", required=True, help="Pasta do relatório em /app/, ex.: xml_cdr_ivr")
    parser.add_argument("--de", type=_data, required=True, metavar="AAAA-MM-DD")
    parser.add_argument("--ate", type=_data, required=True, metavar="AAAA-MM-DD")
    parser.add_argument("--campo", action="append", default=[], metavar="NOME=VALOR",
                        help="Troca ou acrescenta um campo do formulário (pode repetir).")
    parser.add_argument("--pagina", default="xml_cdr.php",
                        help="Página do relatório, usada no Referer (padrão: xml_cdr.php).")
    parser.add_argument("--saida", type=Path, default=None,
                        help="Caminho do CSV (padrão: reconciliacao/<pasta>_<de>_<ate>.csv).")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    args = parser.parse_args()
    configurar_logging(args.verbose)

    filtros = montar_filtros(args.pasta, args.de, args.ate, args.campo)
    sufixo = f"{args.pasta}_{args.de:%Y%m%d}_{args.ate:%Y%m%d}"
    saida = args.saida or PASTA_CSV / f"{sufixo}.csv"
    PASTA_CSV.mkdir(parents=True, exist_ok=True)
    PASTA_HTML.mkdir(parents=True, exist_ok=True)

    cliente = ClienteMdnet(carregar_config_mdnet())
    print(f"\nRelatório {args.pasta}, de {args.de} a {args.ate}")
    print("Campos enviados:", ", ".join(f"{n}={v!r}" for n, v in filtros))

    csv_bruto = cliente.exportar_relatorio_bruto(args.pasta, filtros, args.pagina)
    saida.write_bytes(csv_bruto)
    texto = _decodificar(csv_bruto)
    linhas = [l for l in texto.splitlines() if l.strip()]
    print(f"\nCSV: {len(csv_bruto)} bytes, {max(len(linhas) - 1, 0)} linha(s) de dados -> {saida}")
    if linhas:
        print(f"Cabeçalho: {linhas[0]}")

    for arquivo in ("charts.php", "view.php"):
        try:
            html = cliente.consultar_relatorio(args.pasta, arquivo, filtros, args.pagina)
        except ErroMdnet as exc:
            print(f"\n{arquivo}: FALHOU ({exc})")
            continue
        destino = PASTA_HTML / f"{sufixo}.{arquivo.replace('.php', '')}.html"
        destino.write_text(html, encoding="utf-8")
        print(f"\n{arquivo}: {len(html)} caracteres -> {destino.name}")
        print(f"  texto: {texto_visivel(html)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
