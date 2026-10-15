"""Mapeia as páginas do painel da MDnet: menu, links e endereços. Somente leitura (GET).

  python explorar_menu_mdnet.py [--paginas /caminho1 /caminho2 ...]

Entra no painel, baixa a página inicial e a do relatório de chamadas (ou as páginas
pedidas), salva o HTML em reconciliacao/painel_mdnet/ e imprime os links, as ações de
clique e os caminhos /app/ e /core/ citados no HTML e nos scripts do próprio painel. Serve
para achar relatórios que ainda não extraímos (URA, filas, ramais). Não grava nada no
banco nem no painel.

Rodar sempre com o login do analista: o script só faz GET de páginas que o navegador já
abre ao navegar no painel.
"""
from __future__ import annotations

import argparse
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

from config.settings import carregar_config_mdnet
from cvdw.log import configurar_logging, get_logger
from mdnet.api import ClienteMdnet, ErroMdnet

log = get_logger("explorar_menu_mdnet")

RAIZ = Path(__file__).resolve().parent
PASTA = RAIZ / "reconciliacao" / "painel_mdnet"

PAGINAS_PADRAO = (
    "/core/user_settings/user_dashboard.php",
    "/app/xml_cdr_report/xml_cdr_report.php",
)

_RE_CAMINHO = re.compile(r"""["'(=](/(?:app|core)/[A-Za-z0-9_./?=&%\-\[\]]+)""")
# Scripts de terceiros (jQuery, Bootstrap e afins) só atrasam: o menu do painel não mora neles.
_SCRIPT_DE_TERCEIRO = re.compile(r"/plugins/|jquery|bootstrap|modernizr|tether|pace|validate", re.I)
_MAX_SCRIPTS = 15
# Linhas que denunciam como uma tela busca dados e exporta CSV.
_RE_PISTA = re.compile(r"eCSV|model\.php|view\.php|charts\.php|fileDownload|\$\.ajax|\.post\(|url\s*:", re.I)
_MAX_PISTAS = 80


class _Coletor(HTMLParser):
    """Junta links, ações de clique e scripts de uma página."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[str, str]] = []
        self.acoes: list[tuple[str, str, str]] = []
        self.scripts: list[str] = []
        self._href: str | None = None
        self._texto: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = {k: v for k, v in attrs if v is not None}
        if tag == "a" and a.get("href"):
            self._href, self._texto = a["href"], []
        if tag == "script" and a.get("src"):
            self.scripts.append(a["src"])
        if tag == "form" and a.get("action"):
            self.acoes.append(("form", "action", a["action"]))
        for chave, valor in a.items():
            alvo = chave == "onclick" or (
                chave.startswith("data-") and any(p in chave for p in ("href", "url", "link", "target"))
            )
            if alvo:
                self.acoes.append((tag, chave, valor))

    def handle_data(self, data: str) -> None:
        if self._href is not None and data.strip():
            self._texto.append(data.strip())

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._href is not None:
            self.links.append((" ".join(self._texto), self._href))
            self._href = None


def mapear(html: str) -> _Coletor:
    coletor = _Coletor()
    coletor.feed(html)
    return coletor


def caminhos_citados(texto: str) -> set[str]:
    return set(_RE_CAMINHO.findall(texto))


def _nome_arquivo(caminho: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", caminho.strip("/")) or "raiz"


def _script_local(src: str, url_base: str) -> str | None:
    """Devolve o caminho do script se ele é do próprio painel e não é biblioteca."""
    alvo = urlparse(src)
    if alvo.netloc and alvo.netloc != urlparse(url_base).netloc:
        return None
    caminho = alvo.path if alvo.netloc else src.split("?")[0]
    if not caminho.startswith("/"):
        caminho = "/" + caminho.lstrip("./")
    if _SCRIPT_DE_TERCEIRO.search(caminho):
        return None
    return caminho + (f"?{alvo.query}" if alvo.query else "")


def main() -> int:
    parser = argparse.ArgumentParser(description="Mapeia o menu e os endereços do painel da MDnet.")
    parser.add_argument("--paginas", nargs="+", default=list(PAGINAS_PADRAO), metavar="CAMINHO",
                        help="Caminhos a baixar, começando por /. Padrão: inicial e relatório de chamadas.")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    args = parser.parse_args()
    configurar_logging(args.verbose)

    cfg = carregar_config_mdnet()
    cliente = ClienteMdnet(cfg)
    PASTA.mkdir(parents=True, exist_ok=True)

    todos_caminhos: set[str] = set()
    scripts: list[str] = []
    textos: dict[str, str] = {}  # nome do arquivo salvo -> conteúdo, para a busca de pistas

    for caminho in args.paginas:
        try:
            html = cliente.baixar_pagina(caminho)
        except ErroMdnet as exc:
            print(f"\n== {caminho}\n  FALHOU: {exc}")
            continue
        (PASTA / f"{_nome_arquivo(caminho)}.html").write_text(html, encoding="utf-8")
        textos[f"{_nome_arquivo(caminho)}.html"] = html
        c = mapear(html)
        print(f"\n== {caminho}  ({len(html)} caracteres, salvo em {PASTA.name}/)")

        vistos: set[tuple[str, str]] = set()
        print("  Links (texto -> destino):")
        for texto, href in c.links:
            if (texto, href) in vistos or href.startswith(("#", "javascript:void")):
                continue
            vistos.add((texto, href))
            print(f"    {texto or '(sem texto)':40s} -> {href}")
        if c.acoes:
            print("  Ações de clique e formulários:")
            for tag, chave, valor in dict.fromkeys(c.acoes):
                print(f"    <{tag}> {chave} = {valor[:110]}")

        todos_caminhos |= caminhos_citados(html)
        for src in c.scripts:
            local = _script_local(src, cfg.url_base)
            if local and local not in scripts:
                scripts.append(local)

    for src in scripts[:_MAX_SCRIPTS]:
        try:
            js = cliente.baixar_pagina(src)
        except ErroMdnet as exc:
            log.warning("Script %s não baixou: %s", src, exc)
            continue
        nome_js = f"js_{_nome_arquivo(src.split('?')[0])}"
        (PASTA / nome_js).write_text(js, encoding="utf-8")
        textos[nome_js] = js
        achados = caminhos_citados(js)
        if achados:
            print(f"\n== script {src}: cita {len(achados)} caminho(s)")
        todos_caminhos |= achados

    print("\n== Caminhos /app/ e /core/ citados nas páginas e nos scripts do painel:")
    for caminho in sorted(todos_caminhos):
        print(f"  {caminho}")

    # Onde o painel monta a consulta e a exportação: é isso que se reproduz no extrator.
    print("\n== Pistas de consulta e exportação (arquivo:linha: trecho):")
    mostradas = 0
    for nome, texto in textos.items():
        for numero, linha in enumerate(texto.splitlines(), start=1):
            if _RE_PISTA.search(linha) and len(linha.strip()) < 400:
                print(f"  {nome}:{numero}: {linha.strip()[:160]}")
                mostradas += 1
                if mostradas >= _MAX_PISTAS:
                    break
        if mostradas >= _MAX_PISTAS:
            print(f"  (cortado em {_MAX_PISTAS} linhas; o resto está nos arquivos salvos)")
            break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
