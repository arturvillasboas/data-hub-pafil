"""Cliente HTTP da API CVDW: auth por headers, throttle + backoff em 429/5xx
(honra Retry-After) e paginação completa."""
from __future__ import annotations

import time
from collections import deque
from typing import Any, Iterator

import requests

from config.settings import ConfigAPI
from cvdw.log import get_logger

log = get_logger("cvdw.api")

# Tentativas para status recuperáveis (429 / 5xx) antes de desistir do objeto.
_MAX_TENTATIVAS = 5
# Bloqueio documentado da API após 429 (usado quando não há header Retry-After).
_ESPERA_429 = 60
# Status transitórios que valem um retry com backoff curto.
_STATUS_TRANSITORIO = (500, 502, 503, 504)


class ErroAPI(Exception):
    """Erro irrecuperável ao falar com a API CVDW (auth, rede, status ruim)."""


def extrair_registros(payload: Any) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Detecta a primeira lista de objetos no topo do JSON, sem assumir a chave.

    Retorna (registros, meta), onde `meta` são os campos escalares do topo
    (ex.: total_de_paginas, total_de_registros) úteis para a paginação.
    """
    if isinstance(payload, list):
        return [r for r in payload if isinstance(r, dict)], {}
    if not isinstance(payload, dict):
        return [], {}

    meta = {k: v for k, v in payload.items() if not isinstance(v, (list, dict))}

    # 1ª preferência: uma chave cujo valor seja uma lista não-vazia de objetos.
    for valor in payload.values():
        if isinstance(valor, list) and valor and all(isinstance(x, dict) for x in valor):
            return valor, meta
    # Fallback: alguma lista (possivelmente vazia) -> não há registros nesta página.
    for valor in payload.values():
        if isinstance(valor, list):
            return [], meta
    return [], meta


class ClienteCVDW:
    """Encapsula a sessão HTTP, o throttle e a paginação da API CVDW."""

    def __init__(self, cfg: ConfigAPI) -> None:
        self._cfg = cfg
        self._sessao = requests.Session()
        self._sessao.headers.update(cfg.headers())
        # Timestamps (monotônicos) das requisições recentes, para o throttle.
        self._marcas: deque[float] = deque()
        # Espaçamento mínimo entre requisições (anti-rajada): distribui as
        # max_req_por_minuto uniformemente ao longo dos 60s em vez de em pico.
        self._intervalo_min = 60.0 / max(1, cfg.max_req_por_minuto)
        self._ultima_req: float | None = None

    # --- throttle ----------------------------------------------------------
    def _aguardar_slot(self) -> None:
        """Respeita `max_req_por_minuto` (janela de 60s) E espaça as requisições
        uniformemente, evitando rajadas que estouram o limite da API."""
        agora = time.monotonic()
        while self._marcas and agora - self._marcas[0] >= 60:
            self._marcas.popleft()

        espera = 0.0
        # (a) teto da janela deslizante.
        if len(self._marcas) >= self._cfg.max_req_por_minuto:
            espera = 60 - (agora - self._marcas[0]) + 0.2
        # (b) espaçamento mínimo desde a última requisição (anti-rajada).
        if self._ultima_req is not None:
            falta = self._intervalo_min - (agora - self._ultima_req)
            espera = max(espera, falta)

        if espera > 0:
            log.debug("Throttle: aguardando %.1fs", espera)
            time.sleep(espera)

        marca = time.monotonic()
        self._marcas.append(marca)
        self._ultima_req = marca

    # --- requisição --------------------------------------------------------
    def _get(self, url: str, params: dict[str, Any]) -> dict[str, Any]:
        """Faz um GET com throttle e retry de 429/5xx (backoff, honra Retry-After)."""
        tentativa = 0
        while True:
            self._aguardar_slot()
            log.info("GET %s params=%s", url, params)
            resp = self._requisitar(url, params)

            # 429 ou 5xx transitório: espera e repete (até _MAX_TENTATIVAS).
            if resp.status_code == 429 or resp.status_code in _STATUS_TRANSITORIO:
                tentativa += 1
                if tentativa > _MAX_TENTATIVAS:
                    raise ErroAPI(
                        f"HTTP {resp.status_code} persistente em {url} após "
                        f"{_MAX_TENTATIVAS} tentativas: {resp.text[:200]}"
                    )
                if resp.status_code == 429:
                    espera = self._retry_after(resp)
                else:
                    espera = min(_ESPERA_429, 5 * tentativa)  # backoff curto
                log.warning(
                    "HTTP %d em %s — tentativa %d/%d, aguardando %ds e repetindo",
                    resp.status_code, url, tentativa, _MAX_TENTATIVAS, espera,
                )
                time.sleep(espera)
                # A espera longa "zera" a janela; recomeça o espaçamento limpo.
                self._marcas.clear()
                self._ultima_req = None
                continue

            if resp.status_code in (401, 403):
                raise ErroAPI(
                    f"HTTP {resp.status_code} (autenticação) em {url}. Verifique "
                    f"CVCRM_EMAIL/CVCRM_TOKEN e os nomes dos headers "
                    f"(CVCRM_HEADER_EMAIL/CVCRM_HEADER_TOKEN)."
                )
            if not resp.ok:
                raise ErroAPI(f"HTTP {resp.status_code} em {url}: {resp.text[:300]}")
            try:
                return resp.json()
            except ValueError as exc:
                raise ErroAPI(f"Resposta não-JSON em {url}: {resp.text[:300]}") from exc

    @staticmethod
    def _retry_after(resp: requests.Response) -> int:
        """Segundos a esperar após 429: usa o header Retry-After, senão o padrão."""
        cabecalho = resp.headers.get("Retry-After")
        if cabecalho:
            try:
                return max(1, int(float(cabecalho)))
            except ValueError:
                pass
        return _ESPERA_429

    def _requisitar(self, url: str, params: dict[str, Any]) -> requests.Response:
        """GET de baixo nível, convertendo erros de rede em ErroAPI."""
        try:
            return self._sessao.get(url, params=params, timeout=self._cfg.timeout)
        except requests.RequestException as exc:
            raise ErroAPI(f"Falha de rede em {url}: {exc}") from exc

    # --- amostra (descoberta) ---------------------------------------------
    def buscar_amostra(self, path: str, registros: int = 10) -> tuple[list[dict], str]:
        """Busca 1 página pequena de um objeto (usado na descoberta de schema)."""
        url = self._cfg.url_objeto(path)
        payload = self._get(url, {"pagina": 1, "registros_por_pagina": registros})
        regs, _ = extrair_registros(payload)
        return regs, url

    def total_registros_origem(self, path: str) -> int | None:
        """Total de registros que a API reporta no envelope (1 requisição leve).

        Lê `total_de_registros` sem paginar — útil para conferir a completude da
        carga (origem vs. bronze). Retorna None se o envelope não traz o total.
        """
        url = self._cfg.url_objeto(path)
        payload = self._get(url, {"pagina": 1, "registros_por_pagina": 1})
        _, meta = extrair_registros(payload)
        return _para_int(meta.get("total_de_registros"))

    # --- paginação (ingestão) ---------------------------------------------
    def paginar(
        self, path: str, a_partir_data_referencia: str | None = None
    ) -> Iterator[tuple[int, list[dict[str, Any]]]]:
        """Itera todas as páginas de um objeto, respeitando o rate limit.

        Para quando há `total_de_paginas` no meta e ela é atingida, ou quando
        uma página retorna menos registros que o tamanho de página.
        """
        url = self._cfg.url_objeto(path)
        pagina = 1
        while True:
            params: dict[str, Any] = {
                "pagina": pagina,
                "registros_por_pagina": self._cfg.registros_por_pagina,
            }
            if a_partir_data_referencia:
                params["a_partir_data_referencia"] = a_partir_data_referencia

            payload = self._get(url, params)
            registros, meta = extrair_registros(payload)
            yield pagina, registros

            total_paginas = _para_int(meta.get("total_de_paginas"))
            if total_paginas is not None:
                if pagina >= total_paginas:
                    break
            elif len(registros) < self._cfg.registros_por_pagina:
                break
            pagina += 1


def _para_int(valor: Any) -> int | None:
    """Converte para int quando possível; senão, None."""
    try:
        return int(valor)
    except (TypeError, ValueError):
        return None
