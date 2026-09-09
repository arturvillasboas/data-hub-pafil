"""Cliente do protocolo de comandos do Blip.

Diferente do CVDW, aqui não existe um endpoint REST por objeto. Tudo passa por
um único `POST /commands`, e o que muda é o corpo do JSON: `to` diz qual
extensão responde (a de atendimento é `postmaster@desk.msging.net`), `uri` diz
qual recurso dentro dela, e `method` é sempre uma string em minúsculas
("get", "set", "delete"), não o verbo HTTP.

Duas armadilhas do protocolo, ambas tratadas aqui:

1. **O HTTP quase sempre volta 200, mesmo quando o comando falha.** O sucesso
   de verdade está em `status` dentro do corpo ("success" ou "failure"), com o
   motivo em `reason`. Confiar no `resp.ok` faria erro de permissão passar
   como resposta vazia, que é o jeito mais silencioso de perder dado.
2. **A paginação é por `$skip`/`$take` na própria URI**, não por parâmetros de
   query da requisição HTTP. O envelope devolve uma coleção com `total` e
   `items`.
"""
from __future__ import annotations

import time
import uuid
from collections import deque
from typing import Any, Iterator

import requests

from config.settings import ConfigBlip
from cvdw.log import get_logger

log = get_logger("blip.api")

# Extensão de atendimento (Blip Desk): tickets, filas e atendentes.
DESK = "postmaster@desk.msging.net"

_MAX_TENTATIVAS = 5
_STATUS_TRANSITORIO = (429, 500, 502, 503, 504)
# Teto de páginas por coleção. Só existe para transformar um erro de paginação
# (um endpoint que ignora $skip e devolve sempre a mesma página, por exemplo)
# num erro visível em vez de um laço infinito comendo rate limit.
_MAX_PAGINAS = 10_000


# Código do Blip para "o backend por trás da extensão respondeu erro". O código
# sozinho não diz se vale repetir: ele cobre tanto um 503 momentâneo quanto um
# 404 definitivo, e a diferença só aparece na descrição.
_CODIGO_ERRO_REMOTO = 2105
# Sinais, dentro da descrição, de que o problema é passageiro.
_SINAIS_TRANSITORIOS = ("500", "502", "503", "504", "429", "timeout", "timed out")


class ErroBlip(Exception):
    """Falha irrecuperável ao falar com a API do Blip (auth, rede, comando recusado)."""


def _falha_transitoria(motivo: dict[str, Any]) -> bool:
    """Diz se vale repetir um comando que voltou com `status: failure`.

    Esta função existe por causa de uma armadilha específica: quando o backend
    da extensão devolve 503, o Blip **não** propaga o 503. Ele responde HTTP 200
    com `status: failure` e o 503 escrito por extenso dentro da descrição. Uma
    camada de retry que olhe só o código HTTP não vê nada de errado, e uma carga
    de centenas de páginas morre na primeira instabilidade momentânea. Foi
    exatamente o que aconteceu na primeira carga real, na página 3 de ~520.

    O código 2105 sozinho não basta para repetir: ele também aparece quando o
    backend devolve 404, que vai continuar 404 por mais que se insista.
    """
    if motivo.get("code") != _CODIGO_ERRO_REMOTO:
        return False
    descricao = str(motivo.get("description") or "").lower()
    return any(sinal in descricao for sinal in _SINAIS_TRANSITORIOS)


def montar_uri(recurso: str, skip: int, take: int, filtro: str | None = None) -> str:
    """Monta a URI de uma coleção com paginação e, opcionalmente, `$filter`.

    O `$filter` usa sintaxe OData, em que aspas simples, parênteses e vírgulas
    fazem parte da expressão (`status eq 'ClosedAttendant'`) e são caracteres
    válidos numa query string — só o espaço não é. Por isso a codificação é
    cirúrgica: espaço vira %20 e o resto passa intacto. Um `quote()` genérico
    escaparia as aspas também e o Blip devolveria coleção vazia sem reclamar,
    que é o tipo de erro que só aparece semanas depois, num total que não bate.
    """
    partes = [f"$skip={skip}", f"$take={take}"]
    if filtro:
        partes.append(f"$filter={filtro.replace(' ', '%20')}")
    separador = "&" if "?" in recurso else "?"
    return f"{recurso}{separador}{'&'.join(partes)}"


class ClienteBlip:
    """Encapsula a sessão HTTP, o throttle, o retry e a paginação do Blip."""

    def __init__(self, cfg: ConfigBlip) -> None:
        self._cfg = cfg
        self._sessao = requests.Session()
        self._sessao.headers.update(cfg.headers())
        self._marcas: deque[float] = deque()
        self._intervalo_min = 60.0 / max(1, cfg.max_req_por_minuto)
        self._ultima_req: float | None = None

    # --- throttle ----------------------------------------------------------
    def _aguardar_slot(self) -> None:
        """Respeita o teto por minuto e espaça as requisições, evitando rajada."""
        agora = time.monotonic()
        while self._marcas and agora - self._marcas[0] >= 60:
            self._marcas.popleft()

        espera = 0.0
        if len(self._marcas) >= self._cfg.max_req_por_minuto:
            espera = 60 - (agora - self._marcas[0]) + 0.2
        if self._ultima_req is not None:
            espera = max(espera, self._intervalo_min - (agora - self._ultima_req))

        if espera > 0:
            log.debug("Throttle: aguardando %.1fs", espera)
            time.sleep(espera)

        marca = time.monotonic()
        self._marcas.append(marca)
        self._ultima_req = marca

    # --- comando -----------------------------------------------------------
    def comando(
        self,
        uri: str,
        to: str | None = DESK,
        method: str = "get",
        resource: Any = None,
    ) -> Any:
        """Executa um comando e devolve o `resource` da resposta.

        `to=None` omite o destinatário, e nesse caso quem responde é o próprio
        bot da chave (é assim que se lê `/account`, por exemplo). Com `to`
        preenchido, quem responde é a extensão endereçada.

        Levanta ErroBlip quando o corpo vem com `status != "success"`, para que
        uma recusa da extensão nunca seja confundida com coleção vazia.
        """
        corpo: dict[str, Any] = {
            "id": str(uuid.uuid4()),
            "method": method,
            "uri": uri,
        }
        if to:
            corpo["to"] = to
        if resource is not None:
            corpo["resource"] = resource

        tentativa = 0
        while True:
            payload = self._postar_com_retry(corpo)
            if payload.get("status") == "success":
                return payload.get("resource")

            motivo = payload.get("reason") or {}
            if not _falha_transitoria(motivo) or tentativa >= _MAX_TENTATIVAS:
                raise ErroBlip(
                    f"Comando recusado ({to} {method} {uri}): "
                    f"status={payload.get('status')} code={motivo.get('code')} "
                    f"{motivo.get('description')}"
                )

            tentativa += 1
            espera = min(60, 5 * tentativa)
            log.warning(
                "Falha transitória (code=%s: %s) — tentativa %d/%d, "
                "aguardando %ds e repetindo",
                motivo.get("code"), motivo.get("description"),
                tentativa, _MAX_TENTATIVAS, espera,
            )
            time.sleep(espera)
            # Id novo a cada tentativa: o id do comando serve para correlacionar
            # requisição e resposta, então reaproveitá-lo confundiria o rastro.
            corpo["id"] = str(uuid.uuid4())

    def _postar_com_retry(self, corpo: dict[str, Any]) -> dict[str, Any]:
        """POST no /commands com throttle e retry de 429/5xx."""
        url = self._cfg.url_commands
        tentativa = 0
        while True:
            self._aguardar_slot()
            log.info("POST %s to=%s uri=%s", url, corpo.get("to", "(o próprio bot)"), corpo["uri"])
            try:
                resp = self._sessao.post(url, json=corpo, timeout=self._cfg.timeout)
            except requests.RequestException as exc:
                raise ErroBlip(f"Falha de rede em {url}: {exc}") from exc

            if resp.status_code in _STATUS_TRANSITORIO:
                tentativa += 1
                if tentativa > _MAX_TENTATIVAS:
                    raise ErroBlip(
                        f"HTTP {resp.status_code} persistente em {url} após "
                        f"{_MAX_TENTATIVAS} tentativas: {resp.text[:200]}"
                    )
                espera = self._retry_after(resp, tentativa)
                log.warning(
                    "HTTP %d — tentativa %d/%d, aguardando %ds e repetindo",
                    resp.status_code, tentativa, _MAX_TENTATIVAS, espera,
                )
                time.sleep(espera)
                self._marcas.clear()
                self._ultima_req = None
                continue

            if resp.status_code in (401, 403):
                raise ErroBlip(self._explicar_401(resp, url))
            if not resp.ok:
                raise ErroBlip(f"HTTP {resp.status_code} em {url}: {resp.text[:300]}")
            try:
                return resp.json()
            except ValueError as exc:
                raise ErroBlip(f"Resposta não-JSON em {url}: {resp.text[:300]}") from exc

    @staticmethod
    def _explicar_401(resp: requests.Response, url: str) -> str:
        """Traduz a recusa de autenticação do Blip no que fazer a respeito.

        O Blip distingue, na `description`, dois problemas bem diferentes que
        chegam os dois como 401, e saber qual é economiza muito tempo:

        - "authentication failed": o header foi lido e a identidade existe, mas
          o segredo está errado. O formato da credencial está certo; o valor não.
        - "invalid authorization header" / "invalid session identity": o header
          nem foi entendido, ou o bot não existe. Aqui o problema é a montagem
          ou o identificador, não o segredo.
        """
        try:
            descricao = str((resp.json() or {}).get("description") or "")
        except ValueError:
            descricao = resp.text[:120]

        baixa = descricao.lower()
        if "authentication failed" in baixa:
            diagnostico = (
                "O identificador foi reconhecido e o formato do header está "
                "correto, mas a chave não confere. O valor de BLIP_CHAVE não é a "
                "access key deste bot: pegue no portal, na tela de Conexões, o "
                "valor do cabeçalho Authorization (longo, terminando em '==') e "
                "use ele sozinho, sem BLIP_IDENTIFICADOR."
            )
        elif "identity" in baixa:
            diagnostico = (
                "O bot desta identidade não foi encontrado. Confira "
                "BLIP_IDENTIFICADOR contra o subdomínio da URL de comandos."
            )
        else:
            diagnostico = (
                "O header não foi entendido. BLIP_CHAVE precisa ser a chave "
                "composta (base64 de 'identificador:accesskey'), ou a access key "
                "crua acompanhada de BLIP_IDENTIFICADOR."
            )
        return f"HTTP {resp.status_code} em {url}: {descricao or 'sem descrição'}. {diagnostico}"

    @staticmethod
    def _retry_after(resp: requests.Response, tentativa: int) -> int:
        """Segundos de espera: honra Retry-After quando existe, senão backoff."""
        cabecalho = resp.headers.get("Retry-After")
        if cabecalho:
            try:
                return max(1, int(float(cabecalho)))
            except ValueError:
                pass
        return min(60, 5 * tentativa)

    # --- paginação ---------------------------------------------------------
    def paginar(
        self,
        recurso: str,
        to: str = DESK,
        filtro: str | None = None,
        take: int | None = None,
    ) -> Iterator[tuple[int, list[dict[str, Any]]]]:
        """Itera uma coleção inteira, cedendo (skip, itens) por página.

        A única condição de parada é a página vir menor que `take`.

        **Não use o campo `total` do envelope para parar.** Apesar do nome, ele
        não é o tamanho da coleção: é a contagem de itens da página. Medido
        contra a API em 09/set/2026, `total` devolveu 1, 5 e 100 para `$take`
        de 1, 5 e 100, na mesma coleção de ~52 mil tickets. Uma parada por
        `lidos >= total` dispara já na primeira página e a carga fica
        silenciosamente truncada nos 100 registros mais recentes, sem erro
        nenhum. Foi exatamente o que aconteceu na primeira descoberta.
        """
        take = take or self._cfg.take
        skip = 0
        for _ in range(_MAX_PAGINAS):
            uri = montar_uri(recurso, skip=skip, take=take, filtro=filtro)
            colecao = self.comando(uri, to=to) or {}
            itens = [i for i in (colecao.get("items") or []) if isinstance(i, dict)]
            yield skip, itens

            if len(itens) < take:
                return
            skip += take
        raise ErroBlip(
            f"Paginação de {recurso} passou de {_MAX_PAGINAS} páginas sem terminar. "
            f"Provável endpoint ignorando $skip — confira a URI antes de insistir."
        )

    def coletar(
        self,
        recurso: str,
        to: str = DESK,
        filtro: str | None = None,
        limite: int | None = None,
    ) -> list[dict[str, Any]]:
        """Materializa uma coleção inteira (ou os `limite` primeiros itens)."""
        acumulado: list[dict[str, Any]] = []
        for _, itens in self.paginar(recurso, to=to, filtro=filtro):
            acumulado.extend(itens)
            if limite is not None and len(acumulado) >= limite:
                return acumulado[:limite]
        return acumulado
