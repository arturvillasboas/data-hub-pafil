"""Configuração do pipeline, carregada de variáveis de ambiente (.env / secrets)."""
from __future__ import annotations

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


@dataclass(frozen=True)
class ConfigPostgres:
    """Parâmetros de conexão com o Postgres (Azure, via SSL)."""

    host: str
    port: int
    db: str
    user: str
    password: str
    sslmode: str
    bronze_schema: str

    def conninfo(self) -> str:
        """String de conexão libpq; sslmode garante o SSL exigido pelo Azure."""
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
            )
        )
    return objetos
