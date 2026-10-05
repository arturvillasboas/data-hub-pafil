"""Cliente do painel web da MDnet (DDA Telecom) para extrair o CDR de chamadas.

Não existe API documentada. O que existe é o botão de CSV do relatório de
chamadas, e este módulo faz o mesmo que o navegador faz ao clicar nele:

1. `GET /` para receber o cookie de sessão (PHPSESSID);
2. `POST /core/user_settings/user_dashboard.php` com usuário e senha, que é o
   `action` do formulário de login;
3. `POST /app/xml_cdr_report/model.php?file=eCSV` com os filtros do relatório,
   que devolve o CSV.

A autenticação é só o cookie de sessão. Não há token de API nem CSRF no que foi
capturado do navegador, mas o painel pode mudar isso sem aviso. Se mudar, o
sintoma esperado é o `ErroMdnet` de "devolveu HTML em vez de CSV".

Uma armadilha do painel, tratada aqui: quando a sessão expira, o export NÃO volta
401. Volta HTTP 200 com a tela de login em HTML. Quem só olha o status leria o
HTML como CSV vazio e perderia o dia em silêncio.
"""
from __future__ import annotations

import csv
import io
import time
from datetime import date, datetime, time as hora, timedelta
from typing import Iterator

import requests

from config.settings import ConfigMdnet
from cvdw.log import get_logger
from mdnet.objetos import CDR

log = get_logger("mdnet.api")

URL_LOGIN = "/core/user_settings/user_dashboard.php"
URL_RELATORIO = "/app/xml_cdr_report/xml_cdr_report.php"
URL_EXPORTAR_CSV = "/app/xml_cdr_report/model.php?file=eCSV"

_MAX_TENTATIVAS = 4
_STATUS_TRANSITORIO = (429, 500, 502, 503, 504)
_FORMATO_FILTRO = "%Y-%m-%d %H:%M"

# Valores do filtro de Direção do painel (campo DIRECTION[], lista no POST). São os
# nomes do FreeSWITCH. Sem filtro o painel devolve UMA perna por ligação; com o
# filtro devolve as pernas daquela direção, inclusive as que o CSV sem filtro
# esconde (ver ingerir_mdnet_pernas.py). A correspondência com a coluna Direção do
# CSV é inbound = Entrada, outbound = Saída e internal = Interna, as três confirmadas em
# 05/out/2026. O valor de Interna NÃO é `local` (o padrão do FreeSWITCH): esse devolveu
# zero linhas em todos os dias. Achado com sondar_direcao_mdnet.py.
DIRECOES = ("inbound", "outbound", "internal")


class ErroMdnet(Exception):
    """Falha irrecuperável ao falar com o painel da MDnet."""


def _eh_html(corpo: bytes) -> bool:
    """O CSV começa por "Protocolo"; qualquer coisa que abra com "<" é página."""
    return corpo.lstrip(b"\xef\xbb\xbf \t\r\n").startswith(b"<")


def _tela_de_login(texto: str) -> bool:
    return 'id="form-login"' in texto or 'name="username"' in texto


def _decodificar(corpo: bytes) -> str:
    try:
        return corpo.decode("utf-8-sig")
    except UnicodeDecodeError:
        log.warning("CSV fora de UTF-8; lendo como cp1252")
        return corpo.decode("cp1252")


def parsear_csv(corpo: bytes) -> list[dict[str, str]]:
    """Converte o CSV do painel em lista de dicts (cabeçalho -> texto).

    Separador `;`, UTF-8 com BOM, aspas só nos campos que têm espaço. Falta de
    coluna esperada é erro (o painel mudou o layout e gravar assim criaria linhas
    com NULL no lugar de dado); coluna a mais vira só aviso, e o valor fica no
    JSON cru da bronze.
    """
    texto = _decodificar(corpo)
    if not texto.strip():
        return []

    leitor = csv.DictReader(io.StringIO(texto), delimiter=";")
    cabecalho = [(c or "").strip() for c in (leitor.fieldnames or [])]
    leitor.fieldnames = cabecalho

    faltando = [c for c in CDR.campos if c not in cabecalho]
    if faltando:
        raise ErroMdnet(
            f"O CSV não tem as colunas {faltando}. Cabeçalho recebido: {cabecalho}. "
            f"O painel mudou o layout: ajuste mdnet/objetos.py e sql/bronze/mdnet.sql."
        )
    novas = [c for c in cabecalho if c and c not in CDR.campos]
    if novas:
        log.warning("Colunas novas no CSV (guardadas só em _dados_brutos): %s",
                    ", ".join(novas))

    linhas: list[dict[str, str]] = []
    for linha in leitor:
        # Chave None = células a mais do que o cabeçalho; descarta.
        linhas.append({k: (v or "").strip() for k, v in linha.items() if k is not None})
    return linhas


def janelas_diarias(de: date, ate: date) -> Iterator[tuple[datetime, datetime]]:
    """Cede (início, fim) de cada dia entre `de` e `ate`, inclusive.

    O fim é 00:00 do dia seguinte, não 23:59. O filtro do painel tem precisão de
    minuto, e um fim às 23:59 poderia deixar de fora uma chamada às 23:59:30. A
    folga cria uma sobreposição de um instante entre dias vizinhos, que o upsert
    por (protocolo, início) deduplica.
    """
    dia = de
    while dia <= ate:
        inicio = datetime.combine(dia, hora.min)
        yield inicio, inicio + timedelta(days=1)
        dia += timedelta(days=1)


class ClienteMdnet:
    """Sessão autenticada no painel, com pausa entre pedidos e retry."""

    def __init__(self, cfg: ConfigMdnet) -> None:
        self._cfg = cfg
        self._sessao = requests.Session()
        self._sessao.headers.update({"User-Agent": "pafil-data-platform/1.0 (extrator CDR)"})
        self._logado = False

    def login(self) -> None:
        """Abre a sessão. A senha nunca é logada nem entra em mensagem de erro."""
        base = self._cfg.url_base
        try:
            self._sessao.get(f"{base}/", timeout=self._cfg.timeout)
            resp = self._sessao.post(
                f"{base}{URL_LOGIN}",
                data={"username": self._cfg.usuario, "password": self._cfg.senha,
                      "path": ""},
                timeout=self._cfg.timeout,
            )
        except requests.RequestException as exc:
            raise ErroMdnet(f"Falha de rede no login em {base}: {exc}") from exc

        if not resp.ok:
            raise ErroMdnet(f"Login em {base}{URL_LOGIN} voltou HTTP {resp.status_code}.")
        if _tela_de_login(resp.text):
            raise ErroMdnet(
                "Login recusado: o painel devolveu a tela de login de novo. Confira "
                "MDNET_USUARIO e MDNET_SENHA, e se esse usuário abre o painel no navegador."
            )
        self._logado = True
        log.info("Login no painel MDnet OK (usuário %s)", self._cfg.usuario)

    def exportar_cdr(
        self, inicio: datetime, fim: datetime, direcao: str | None = None,
        validar: bool = True,
    ) -> list[dict[str, str]]:
        """Exporta o CDR do período [inicio, fim] e devolve as linhas do CSV.

        `direcao` (um de DIRECOES) liga o filtro de Direção do painel. Sem ele o
        formulário vai exatamente como o navegador manda, com DIRECTION vazio.
        """
        # `validar=False` existe só para a sonda de valores do filtro (sondar_direcao_mdnet.py).
        if validar and direcao is not None and direcao not in DIRECOES:
            raise ErroMdnet(f"Direção {direcao!r} desconhecida. Use uma de {DIRECOES}.")
        if not self._logado:
            self.login()

        base = self._cfg.url_base
        filtros = [
            ("DATA_INI", inicio.strftime(_FORMATO_FILTRO)),
            ("DATA_END", fim.strftime(_FORMATO_FILTRO)),
            ("CALLER_ID_NUMBER", ""),
            ("DESTINATION_NUMBER", ""),
            ("EXTENSION", ""),
            # Com filtro o navegador manda DIRECTION[]=outbound (lista); sem filtro,
            # DIRECTION= vazio. Capturado do painel em 05/out/2026.
            ("DIRECTION[]", direcao) if direcao else ("DIRECTION", ""),
            ("FINALIZATION", ""),
            ("TRANSFERRED", ""),
        ]
        cabecalhos = {"Referer": f"{base}{URL_RELATORIO}", "Origin": base}

        tentativa = 0
        relogou = False
        while True:
            time.sleep(self._cfg.pausa_segundos)
            try:
                resp = self._sessao.post(
                    f"{base}{URL_EXPORTAR_CSV}", data=filtros, headers=cabecalhos,
                    timeout=self._cfg.timeout,
                )
            except requests.RequestException as exc:
                tentativa += 1
                if tentativa > _MAX_TENTATIVAS:
                    raise ErroMdnet(f"Falha de rede no export: {exc}") from exc
                espera = min(60, 5 * tentativa)
                log.warning("Falha de rede (%s), tentativa %d/%d, aguardando %ds",
                            exc, tentativa, _MAX_TENTATIVAS, espera)
                time.sleep(espera)
                continue

            if resp.status_code in _STATUS_TRANSITORIO:
                tentativa += 1
                if tentativa > _MAX_TENTATIVAS:
                    raise ErroMdnet(
                        f"HTTP {resp.status_code} persistente no export após "
                        f"{_MAX_TENTATIVAS} tentativas."
                    )
                espera = min(60, 5 * tentativa)
                log.warning("HTTP %d no export, tentativa %d/%d, aguardando %ds",
                            resp.status_code, tentativa, _MAX_TENTATIVAS, espera)
                time.sleep(espera)
                continue

            if not resp.ok:
                raise ErroMdnet(f"HTTP {resp.status_code} no export: {resp.text[:200]}")

            if _eh_html(resp.content):
                if _tela_de_login(resp.text) and not relogou:
                    log.warning("Sessão expirou no meio da carga; entrando de novo")
                    relogou = True
                    self.login()
                    continue
                raise ErroMdnet(
                    "O painel devolveu HTML em vez de CSV (começo: "
                    f"{resp.text[:160]!r}). Ou a sessão não renovou, ou o painel "
                    "mudou o endpoint de exportação."
                )

            return parsear_csv(resp.content)
