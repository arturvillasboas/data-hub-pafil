"""Configuração central de logging estruturado para todos os scripts."""
from __future__ import annotations

import logging
import sys

# Formato com timestamp, nível, módulo e mensagem — fácil de ler no cron/Actions.
_FORMATO = "%(asctime)s | %(levelname)-7s | %(name)-14s | %(message)s"
_DATA = "%Y-%m-%d %H:%M:%S"


def configurar_logging(verbose: bool = False) -> None:
    """Configura o logging raiz. Chamar uma vez no início de cada entrypoint."""
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format=_FORMATO,
        datefmt=_DATA,
        stream=sys.stdout,
    )
    # requests/urllib3 são barulhentos em DEBUG; mantém em WARNING.
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def get_logger(nome: str) -> logging.Logger:
    """Atalho para obter um logger nomeado."""
    return logging.getLogger(nome)
