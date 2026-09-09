"""Objetos do Blip a ingerir na bronze, com o de-para campo da API -> coluna.

No CVDW o mapa de colunas é descoberto automaticamente, porque são centenas de
campos por objeto e eles mudam. Aqui são três objetos pequenos e estáveis, e o
mapa explícito paga por si: ele documenta a fonte, dá nomes legíveis às colunas
(`sequential_id` em vez de `sequentialid`) e transforma campo novo da API em
aviso de drift, em vez de coluna que ninguém percebeu que faltava.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ObjetoBlip:
    """Um recurso do Blip e como ele aterrissa na bronze."""

    nome_logico: str                 # nome da tabela em bronze
    recurso: str                     # URI do recurso (ex.: /tickets)
    campos: dict[str, str]           # chave da API -> coluna da bronze
    # Campo de data usado para recortar a janela do modo incremental. Quando é
    # None, o objeto é sempre lido por inteiro (o caso das dimensões pequenas).
    campo_janela: str | None = None
    # Mantém um snapshot diário. Só vale para objetos cujo estado atual
    # sobrescreve o anterior sem deixar rastro (ver comentário no blip.sql).
    snapshot: bool = False


TICKETS = ObjetoBlip(
    nome_logico="blip_tickets",
    recurso="/tickets",
    campo_janela="storageDate",
    campos={
        "sequentialId": "sequential_id",
        "parentSequentialId": "parent_sequential_id",
        "id": "id",
        "externalId": "external_id",
        "ownerIdentity": "owner_identity",
        "customerIdentity": "customer_identity",
        "customerDomain": "customer_domain",
        "agentIdentity": "agent_identity",
        "closedBy": "closed_by",
        "team": "team",
        "status": "status",
        "closed": "closed",
        "priority": "priority",
        "rating": "rating",
        "unreadMessages": "unread_messages",
        "storageDate": "storage_date",
        "openDate": "open_date",
        "closeDate": "close_date",
        "firstResponseDate": "first_response_date",
        "statusDate": "status_date",
        "averageAgentResponseTime": "average_agent_response_time",
        "distributionType": "distribution_type",
        "isAutomaticDistribution": "is_automatic_distribution",
        "provider": "provider",
        # Maiúscula no começo mesmo: é assim que a API devolve, diferente de
        # todos os outros campos. Não "corrigir" para camelCase, ou o valor para
        # de ser lido e a coluna passa a vir NULL em silêncio.
        "CampaignId": "campaign_id",
        "tags": "tags",
    },
)

TEAMS = ObjetoBlip(
    nome_logico="blip_teams",
    recurso="/teams",
    snapshot=True,
    campos={
        "name": "name",
        "agentsOnline": "agents_online",
    },
)

ATTENDANTS = ObjetoBlip(
    nome_logico="blip_attendants",
    recurso="/attendants",
    snapshot=True,
    campos={
        "identity": "identity",
        "email": "email",
        "fullName": "full_name",
        "isEnabled": "is_enabled",
        "status": "status",
        "teams": "teams",
    },
)

# Ordem de carga: as dimensões primeiro, que são baratas e falham rápido se a
# credencial estiver errada, e só depois os tickets, que são a carga longa.
OBJETOS: tuple[ObjetoBlip, ...] = (TEAMS, ATTENDANTS, TICKETS)


def por_nome(nomes: set[str]) -> list[ObjetoBlip]:
    """Filtra os objetos pelos nomes lógicos pedidos na linha de comando."""
    return [o for o in OBJETOS if o.nome_logico in nomes]
