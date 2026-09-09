"""Configuração do pipeline, carregada de variáveis de ambiente (.env / secrets)."""
from __future__ import annotations

import base64
import binascii
import os
from dataclasses import dataclass
from pathlib import Path

import yaml
from dotenv import load_dotenv

# Raiz do projeto = pasta-pai de config/.
RAIZ = Path(__file__).resolve().parent.parent

# Carrega o .env da raiz, se existir (em CI as variáveis já vêm do ambiente).
load_dotenv(RAIZ / ".env")


@dataclass(frozen=True)
class ConfigAPI:
    """Parâmetros de acesso e comportamento da API CVDW."""

    subdominio: str
    email: str
    token: str
    header_email: str
    header_token: str
    max_req_por_minuto: int
    registros_por_pagina: int
    timeout: int
    buffer_incremental_horas: int

    @property
    def base_url(self) -> str:
        return f"https://{self.subdominio}.cvcrm.com.br/api/v1/cvdw"

    def url_objeto(self, path: str) -> str:
        """Monta a URL completa de um objeto a partir do seu path."""
        return f"{self.base_url}/{path.strip('/')}"

    def headers(self) -> dict[str, str]:
        """Headers de autenticação (nomes configuráveis) + Accept JSON."""
        return {
            self.header_email: self.email,
            self.header_token: self.token,
            "Accept": "application/json",
        }


def chave_sem_prefixo(chave: str) -> str:
    """Devolve só o base64 da chave do Blip, sem nenhum prefixo "Key ".

    O portal exibe a chave já prefixada ("Key eyJ..."), e o .env também sugere a
    linha com o prefixo, então é normal ela ser colada por cima e virar
    "Key Key eyJ...". Como o prefixo duplicado devolve um 401 idêntico ao de
    chave errada, o tempo perdido diagnosticando isso é enorme para um problema
    tão bobo. Tirar todos os prefixos repetidos aqui elimina o caso.
    """
    limpa = chave.strip()
    while limpa[:4].lower() == "key ":
        limpa = limpa[4:].strip()
    return limpa


@dataclass(frozen=True)
class ConfigBlip:
    """Parâmetros de acesso à API de comandos do Blip (dados de atendimento)."""

    identificador: str  # identificador do bot Router (subdomínio do msging.net)
    access_key: str     # access key crua, já sem base64 e sem prefixo
    max_req_por_minuto: int
    take: int           # itens por página ($take)
    timeout: int
    # Quantos dias para trás o modo incremental relê. Precisa ser generoso
    # porque a janela é recortada por `storageDate`, que é o momento de CRIAÇÃO
    # do ticket e não se move quando ele é atualizado: um ticket aberto na
    # segunda e fechado na quarta só é relido se a janela ainda o alcançar.
    janela_dias: int

    @property
    def url_commands(self) -> str:
        return f"https://{self.identificador}.http.msging.net/commands"

    def headers(self) -> dict[str, str]:
        """Header de autenticação do Blip.

        O que o Blip espera não é a access key sozinha: é
        `Key base64("identificador:accesskey")`. Guardar as duas partes
        separadas e compor aqui deixa a montagem num lugar só, e permite que o
        .env receba tanto a chave já composta quanto as duas metades.
        """
        composta = base64.b64encode(
            f"{self.identificador}:{self.access_key}".encode("utf-8")
        ).decode("ascii")
        return {
            "Authorization": f"Key {composta}",
            "Content-Type": "application/json",
        }


@dataclass(frozen=True)
class ConfigPostgres:
    """Parâmetros de conexão com o Postgres (local via 5433, produção via túnel)."""

    host: str
    port: int
    db: str
    user: str
    password: str
    sslmode: str
    bronze_schema: str

    def conninfo(self) -> str:
        """String de conexão libpq. sslmode=disable só é aceitável em localhost."""
        return (
            f"host={self.host} port={self.port} dbname={self.db} "
            f"user={self.user} password={self.password} sslmode={self.sslmode}"
        )


@dataclass(frozen=True)
class Objeto:
    """Definição de um objeto a ingerir (linha do config/objetos.yml)."""

    nome_logico: str
    path: str
    id: str | None  # "auto", nome do campo, ou None (força hash)
    # Ignora a janela do incremental e recarrega o objeto inteiro em toda
    # execução. É para os objetos cujo `data_referencia` na API não se move
    # quando um campo isolado é editado — nesses, uma correção feita depois da
    # última movimentação nunca voltaria a ser lida (ver R26 em REGRAS_NEGOCIO.md).
    sempre_full: bool = False


def _obrigatoria(nome: str) -> str:
    """Lê uma variável de ambiente obrigatória ou falha com mensagem clara."""
    valor = os.getenv(nome)
    if not valor:
        raise RuntimeError(f"Variável de ambiente obrigatória ausente: {nome}")
    return valor


def carregar_config_api() -> ConfigAPI:
    """Monta a ConfigAPI a partir do ambiente."""
    registros = int(os.getenv("CVDW_REGISTROS_POR_PAGINA", "500"))
    return ConfigAPI(
        subdominio=_obrigatoria("CVCRM_SUBDOMINIO"),
        email=_obrigatoria("CVCRM_EMAIL"),
        token=_obrigatoria("CVCRM_TOKEN"),
        header_email=os.getenv("CVCRM_HEADER_EMAIL", "email"),
        header_token=os.getenv("CVCRM_HEADER_TOKEN", "token"),
        max_req_por_minuto=int(os.getenv("CVDW_MAX_REQ_POR_MINUTO", "18")),
        registros_por_pagina=min(registros, 500),  # API limita a 500
        timeout=int(os.getenv("CVDW_TIMEOUT", "60")),
        buffer_incremental_horas=int(os.getenv("CVDW_BUFFER_INCREMENTAL_HORAS", "24")),
    )


def _partes_da_chave_composta(chave: str) -> tuple[str, str] | None:
    """Separa "identificador" e "accesskey" de uma chave já composta.

    A chave que o portal mostra no cabeçalho Authorization é o base64 de
    "identificador:accesskey", então as duas metades viajam dentro dela.
    Devolve None quando o valor não tem esse formato, que é o caso de quem
    copiou a access key crua de outra tela.
    """
    try:
        texto = base64.b64decode(chave_sem_prefixo(chave), validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
    identificador, separador, access_key = texto.partition(":")
    if not (separador and identificador and access_key):
        return None
    return identificador, access_key


def carregar_config_blip() -> ConfigBlip:
    """Monta a ConfigBlip a partir do ambiente.

    `BLIP_CHAVE` aceita as duas formas em que a credencial aparece no portal:

    - a **chave composta**, copiada do cabeçalho Authorization, que é o base64
      de "identificador:accesskey" e já carrega o nome do bot dentro dela;
    - a **access key crua** (costuma ser um UUID), que sozinha não autentica.
      Nesse caso `BLIP_IDENTIFICADOR` passa a ser obrigatório, e ele é o
      subdomínio da URL de comandos (`https://<isto>.http.msging.net/commands`).

    Aceitar as duas evita o trabalho de montar o base64 à mão, que é onde se
    erra silenciosamente: um base64 mal montado dá o mesmo 401 de chave errada.
    """
    chave = _obrigatoria("BLIP_CHAVE")
    identificador_env = (os.getenv("BLIP_IDENTIFICADOR") or "").strip() or None
    partes = _partes_da_chave_composta(chave)

    if partes:
        identificador, access_key = partes
        # Um identificador explícito que contradiz o embutido na chave é sempre
        # engano (chave de um bot, nome de outro). Falhar aqui é melhor do que
        # escolher um dos dois e devolver 401 sem explicar de onde ele veio.
        if identificador_env and identificador_env != identificador:
            raise RuntimeError(
                f"BLIP_IDENTIFICADOR ({identificador_env}) não bate com o "
                f"identificador embutido em BLIP_CHAVE ({identificador}). "
                f"Apague a variável para usar o da chave, ou corrija a chave."
            )
    else:
        if not identificador_env:
            raise RuntimeError(
                "BLIP_CHAVE não está no formato composto (base64 de "
                "'identificador:accesskey'), então parece ser a access key crua. "
                "Nesse caso defina também BLIP_IDENTIFICADOR no .env, com o "
                "subdomínio da URL de comandos: em "
                "https://SEU-BOT.http.msging.net/commands, é o SEU-BOT."
            )
        identificador, access_key = identificador_env, chave_sem_prefixo(chave)

    return ConfigBlip(
        identificador=identificador,
        access_key=access_key,
        max_req_por_minuto=int(os.getenv("BLIP_MAX_REQ_POR_MINUTO", "60")),
        # O Blip aceita $take maior, mas 100 é o tamanho que a documentação usa
        # nos exemplos e o que se vê estável na prática em coleções grandes.
        take=int(os.getenv("BLIP_TAKE", "100")),
        timeout=int(os.getenv("BLIP_TIMEOUT", "60")),
        janela_dias=int(os.getenv("BLIP_JANELA_DIAS", "7")),
    )


def carregar_config_pg() -> ConfigPostgres:
    """Monta a ConfigPostgres a partir do ambiente."""
    return ConfigPostgres(
        host=_obrigatoria("PG_HOST"),
        port=int(os.getenv("PG_PORT", "5432")),
        db=_obrigatoria("PG_DB"),
        user=_obrigatoria("PG_USER"),
        password=_obrigatoria("PG_PASSWORD"),
        sslmode=os.getenv("PG_SSLMODE", "require"),
        bronze_schema=os.getenv("BRONZE_SCHEMA", "bronze"),
    )


def carregar_objetos(caminho: Path | None = None) -> list[Objeto]:
    """Lê a lista de objetos do YAML de configuração."""
    caminho = caminho or (RAIZ / "config" / "objetos.yml")
    with open(caminho, "r", encoding="utf-8") as arquivo:
        dados = yaml.safe_load(arquivo)

    objetos: list[Objeto] = []
    for item in dados.get("objetos", []):
        objetos.append(
            Objeto(
                nome_logico=item["nome_logico"],
                path=item["path"],
                # ausência da chave => "auto"; valor None explícito => força hash.
                id=item.get("id", "auto"),
                sempre_full=bool(item.get("sempre_full", False)),
            )
        )
    return objetos
