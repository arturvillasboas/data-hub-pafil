"""Objetos da MDnet a ingerir na bronze, com o de-para cabeçalho do CSV -> coluna.

Hoje existe um só: o CDR (registro de chamadas) do relatório `xml_cdr_report` do
painel. Ele sai como CSV de 15 colunas, e o mapa explícito faz o mesmo papel que
no Blip: documenta a fonte, dá nome estável às colunas e transforma coluna nova
do painel em aviso, em vez de dado que ninguém percebeu que passou a existir.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ObjetoMdnet:
    """Um relatório do painel e como ele aterrissa na bronze."""

    nome_logico: str        # nome da tabela em bronze
    campos: dict[str, str]  # cabeçalho do CSV -> coluna da bronze


CDR = ObjetoMdnet(
    nome_logico="mdnet_cdr",
    campos={
        # Os cabeçalhos são idênticos aos do arquivo, inclusive a caixa alta de
        # "TIPO TRANSFERÊNCIA" e "TRANSFERIDO DE/PARA", que o painel mistura com
        # a caixa mista das demais. Não normalizar: o nome tem de bater com o CSV.
        "Protocolo": "protocolo",
        "Estado": "estado",
        "Direção": "direcao",
        "Tipo": "tipo",
        "Nome": "nome",
        "Origem": "origem",
        "Destino": "destino",
        "Ramal": "ramal",
        "Data Hora Início Chamada": "data_hora_inicio",
        "Hora Fim": "hora_fim",
        "Tempo Falado": "tempo_falado",
        "TIPO TRANSFERÊNCIA": "tipo_transferencia",
        "TRANSFERIDO DE/PARA": "transferido_de_para",
        "Motivo Desligamento": "motivo_desligamento",
        "Lado Desligamento": "lado_desligamento",
    },
)

# As pernas vêm do MESMO relatório, filtrado por direção. Mesmas colunas, outra tabela
# (ver sql/bronze/mdnet.sql): a bronze.mdnet_cdr guarda uma linha por ligação, como o
# painel mostra, e esta guarda cada perna que o filtro devolve.
CDR_PERNAS = ObjetoMdnet(nome_logico="mdnet_cdr_pernas", campos=CDR.campos)

OBJETOS: tuple[ObjetoMdnet, ...] = (CDR, CDR_PERNAS)
