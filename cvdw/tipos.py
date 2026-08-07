"""Inferência de tipos (formatos BR), nomes de coluna e normalização de valores.
Usado por descoberta_schema.py, gerar_ddl_bronze.py e ingestao.py."""
from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from psycopg.types.json import Json


# Separador improvável nos dados, usado para concatenar valores no hash da linha.
_SEP_HASH = "␟"


def nome_coluna(chave: str) -> str:
    """Converte uma chave do JSON num identificador Postgres seguro e estável.

    Ex.: "Valor Contrato" -> "valor_contrato"; "idReserva" -> "idreserva".
    A conversão é determinística: a ingestão reaplica esta função para mapear
    cada chave da API à coluna correspondente do banco.
    """
    # Remove acentos (NFKD + descarte de combinantes).
    texto = unicodedata.normalize("NFKD", chave).encode("ascii", "ignore").decode()
    texto = texto.lower().strip()
    # Tudo que não é [a-z0-9] vira "_".
    texto = re.sub(r"[^a-z0-9]+", "_", texto).strip("_")
    if not texto:
        texto = "campo"
    # Identificador não pode começar com dígito.
    if texto[0].isdigit():
        texto = f"c_{texto}"
    return texto[:63]  # limite de identificador do Postgres


_RE_DATA_BR = re.compile(r"^\d{2}/\d{2}/\d{4}$")
_RE_DATAHORA_BR = re.compile(r"^\d{2}/\d{2}/\d{4}[ T]\d{2}:\d{2}(:\d{2})?$")
_RE_DATA_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_RE_DATAHORA_ISO = re.compile(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?")
# Número BR: 1.234.567,89 | 1234,89 | -12,5 | 1234
_RE_NUM_BR = re.compile(r"^-?\d{1,3}(\.\d{3})+(,\d+)?$|^-?\d+(,\d+)?$")
# Número simples (US): 1234 | 1234.56 | -0.5
_RE_NUM_US = re.compile(r"^-?\d+(\.\d+)?$")


def inferir_tipo(valor: Any) -> str:
    """Infere o tipo lógico de um único valor.

    Retorna um dos: nulo, booleano, inteiro, numero, data, datahora, texto,
    objeto, lista.
    """
    if valor is None:
        return "nulo"
    if isinstance(valor, bool):  # antes de int! (bool é subclasse de int)
        return "booleano"
    if isinstance(valor, int):
        return "inteiro"
    if isinstance(valor, float):
        return "numero"
    if isinstance(valor, dict):
        return "objeto"
    if isinstance(valor, list):
        return "lista"
    if isinstance(valor, str):
        return _inferir_tipo_texto(valor.strip())
    return "texto"


def _inferir_tipo_texto(t: str) -> str:
    """Infere o tipo de uma string (datas/números brasileiros vêm como texto)."""
    if t == "":
        return "nulo"  # string vazia conta como ausência (afeta nullability)
    if _RE_DATAHORA_BR.match(t) or _RE_DATAHORA_ISO.match(t):
        return "datahora"
    if _RE_DATA_BR.match(t) or _RE_DATA_ISO.match(t):
        return "data"
    if _RE_NUM_BR.match(t) or _RE_NUM_US.match(t):
        # Códigos com zero à esquerda (CEP, etc.) devem permanecer texto.
        nucleo = t.lstrip("-")
        if len(nucleo) > 1 and nucleo[0] == "0" and "," not in t and "." not in t:
            return "texto"
        return "numero"
    return "texto"


def consolidar_tipo(tipos: list[str]) -> str:
    """Consolida os tipos observados num campo ao longo da amostra.

    Em caso de mistura incompatível, cai para "texto" (escolha segura: a
    tipagem forte fica para a silver).
    """
    conjunto = set(tipos)
    conjunto.discard("nulo")
    if not conjunto:
        return "texto"  # só nulos/vazios na amostra
    if conjunto == {"inteiro"}:
        return "inteiro"
    if conjunto <= {"inteiro", "numero"}:
        return "numero"
    if conjunto == {"data"}:
        return "data"
    if conjunto <= {"data", "datahora"}:
        return "datahora"
    if len(conjunto) == 1:
        return next(iter(conjunto))
    return "texto"


def tipo_sql(tipo_logico: str) -> str:
    """Mapeia o tipo inferido para um tipo Postgres seguro para a bronze."""
    return {
        "datahora": "timestamptz",
        "data": "date",
        "numero": "numeric",
        "inteiro": "numeric",   # na bronze, todo número vira numeric (seguro)
        "booleano": "boolean",
        "objeto": "jsonb",
        "lista": "jsonb",
    }.get(tipo_logico, "text")  # texto/nulo/misto/desconhecido -> text


def bucket_pg(data_type: str) -> str:
    """Reduz o data_type do information_schema a um 'bucket' de normalização."""
    d = data_type.lower()
    if d.startswith("timestamp"):
        return "timestamptz"
    if d == "date":
        return "date"
    if d in ("numeric", "bigint", "integer", "smallint", "real", "double precision"):
        return "numeric"
    if d == "boolean":
        return "boolean"
    if d in ("jsonb", "json"):
        return "jsonb"
    return "text"


def parse_numero(valor: Any) -> Decimal | None:
    """Converte número em formato BR/US (ou numérico nativo) para Decimal."""
    if isinstance(valor, bool):
        return None
    if isinstance(valor, (int, float, Decimal)):
        try:
            return Decimal(str(valor))
        except InvalidOperation:
            return None
    if not isinstance(valor, str):
        return None
    t = valor.strip().replace("R$", "").replace("%", "").replace(" ", "")
    if t in ("", "-"):
        return None
    if "," in t:
        # Vírgula = separador decimal (BR); ponto = milhar.
        t = t.replace(".", "").replace(",", ".")
    elif t.count(".") > 1:
        # Vários pontos sem vírgula => pontos são separadores de milhar.
        t = t.replace(".", "")
    try:
        return Decimal(t)
    except InvalidOperation:
        return None


_FORMATOS_DATA = (
    "%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M", "%d/%m/%YT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M",
    "%Y-%m-%dT%H:%M", "%d/%m/%Y", "%Y-%m-%d",
)


def parse_datahora(valor: Any) -> datetime | None:
    """Converte data/datahora em formato BR ou ISO para datetime."""
    if isinstance(valor, datetime):
        return valor
    if not isinstance(valor, str):
        return None
    t = valor.strip()
    if t == "":
        return None
    for fmt in _FORMATOS_DATA:
        try:
            return datetime.strptime(t, fmt)
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(t)  # ISO com timezone, etc.
    except ValueError:
        return None


_VERDADEIRO = {"true", "1", "sim", "s", "t", "yes", "y"}
_FALSO = {"false", "0", "nao", "não", "n", "f", "no"}


def parse_booleano(valor: Any) -> bool | None:
    """Converte representações comuns de booleano (inclui sim/não)."""
    if isinstance(valor, bool):
        return valor
    s = str(valor).strip().lower()
    if s in _VERDADEIRO:
        return True
    if s in _FALSO:
        return False
    return None


def normalizar_para_sql(bruto: Any, bucket: str) -> Any:
    """Converte um valor cru da API para o tipo esperado pela coluna do banco.

    `bucket` vem de bucket_pg(data_type). Para jsonb usa o adaptador Json do
    psycopg (lida corretamente com dict/list/escalar -> jsonb).
    """
    if bruto is None:
        return None
    if bucket == "timestamptz":
        return parse_datahora(bruto)
    if bucket == "date":
        dt = parse_datahora(bruto)
        return dt.date() if dt else None
    if bucket == "numeric":
        return parse_numero(bruto)
    if bucket == "boolean":
        return parse_booleano(bruto)
    if bucket == "jsonb":
        return Json(bruto)
    # text: serializa estruturas; string vazia vira NULL (nullability fiel).
    if isinstance(bruto, (dict, list)):
        return json.dumps(bruto, ensure_ascii=False)
    s = str(bruto)
    return s if s != "" else None


def repr_para_hash(bruto: Any, bucket: str) -> str:
    """Representação canônica e estável de um valor, usada no hash da linha.

    Independe do adaptador do banco: garante que a mesma linha produza sempre o
    mesmo hash (idempotência do upsert por hash).
    """
    if bruto is None:
        return ""
    if bucket == "timestamptz":
        dt = parse_datahora(bruto)
        return dt.isoformat() if dt else ""
    if bucket == "date":
        dt = parse_datahora(bruto)
        return dt.date().isoformat() if dt else ""
    if bucket == "numeric":
        n = parse_numero(bruto)
        return format(n, "f") if n is not None else ""
    if bucket == "boolean":
        b = parse_booleano(bruto)
        return "" if b is None else ("1" if b else "0")
    if bucket == "jsonb" or isinstance(bruto, (dict, list)):
        return json.dumps(bruto, sort_keys=True, ensure_ascii=False, default=str)
    s = str(bruto)
    return s if s != "" else ""


def hash_linha(partes: list[str]) -> str:
    """Calcula o MD5 estável de uma linha a partir das representações canônicas."""
    bruto = _SEP_HASH.join(partes)
    return hashlib.md5(bruto.encode("utf-8")).hexdigest()
