"""Descoberta do que a API do Blip realmente devolve, antes de modelar a bronze.

Mesmo papel que a descoberta de schema teve no CVDW: em vez de escrever o DDL
a partir da documentação e descobrir as diferenças na primeira carga, este
script bate nos recursos candidatos com a chave real, mostra quais respondem,
e monta o inventário de campos de cada um (tipo, taxa de preenchimento e
exemplos). O DDL da bronze sai depois, em cima do que apareceu aqui.

A lista de sondas mistura recursos documentados e palpites. Os palpites estão
marcados como tal e custam uma requisição cada: quando um deles responde, ganhamos
uma fonte que a documentação pública não descreve; quando falha, o motivo vem
impresso e a sonda sai da lista. Nenhum dos dois casos interrompe a execução.

Uso:

    python explorar_blip.py --verificar        # a chave está certa? (2 requisições)
    python explorar_blip.py                    # roda todas as sondas
    python explorar_blip.py --amostra 200      # amostra maior por recurso
    python explorar_blip.py --dias 30          # janela dos tickets fechados
    python explorar_blip.py --recurso tickets  # só uma sonda, pelo nome

As amostras cruas ficam em relatorios/blip_amostras/, que o .gitignore já
cobre. Elas contêm telefone e identificador de cliente: é dado pessoal, não
sai da máquina nem vai para anexo de e-mail.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from blip.api import DESK, ClienteBlip, ErroBlip, montar_uri
from config.settings import RAIZ, carregar_config_blip
from cvdw.log import configurar_logging, get_logger

log = get_logger("explorar_blip")

PASTA_AMOSTRAS = RAIZ / "relatorios" / "blip_amostras"

# Situações de ticket já encerrado. O Blip separa quem encerrou (cliente,
# atendente ou inatividade), e para volumetria de atendimento os três contam
# como "fechado" — mas vale guardar a distinção na bronze, porque encerramento
# por inatividade costuma significar algo bem diferente na análise.
STATUS_FECHADOS = ("ClosedClient", "ClosedAttendant", "ClosedClientInactivity")


@dataclass
class Sonda:
    """Um recurso candidato da API, com o que esperamos aprender dele."""

    nome: str
    recurso: str
    to: str = DESK
    filtro: str | None = None
    documentado: bool = True
    nota: str = ""
    # Preenchido em tempo de execução quando o filtro depende de argumentos.
    filtro_dinamico: Any = field(default=None, repr=False)


def montar_sondas(dias: int) -> list[Sonda]:
    """Lista de sondas, com a janela de datas já aplicada nos filtros."""
    desde = (datetime.now(timezone.utc) - timedelta(days=dias)).strftime("%Y-%m-%dT%H:%M:%SZ")
    status_ou = " or ".join(f"status eq '{s}'" for s in STATUS_FECHADOS)

    return [
        Sonda(
            nome="tickets",
            recurso="/tickets",
            nota="Coleção base. Sem filtro, para ver o que a API considera padrão "
                 "(costuma trazer só os abertos/em espera).",
        ),
        Sonda(
            nome="tickets_fechados",
            recurso="/tickets",
            filtro=f"({status_ou})",
            nota="O grosso da volumetria mora aqui: ticket fechado é atendimento "
                 "concluído, com openDate e closeDate para calcular duração.",
        ),
        Sonda(
            nome="tickets_periodo",
            recurso="/tickets",
            filtro=f"storageDate ge datetimeoffset'{desde}'",
            nota=f"Janela de data (últimos {dias} dias). Confirmado em 09/set/2026 "
                 f"com um teste de data no futuro, que devolveu zero: o filtro é "
                 f"aplicado de verdade, então a carga diária pode ser incremental. "
                 f"Só esta sintaxe funciona; aspas simples, sem aspas e datetime'' "
                 f"são recusadas pela API.",
        ),
        Sonda(
            nome="teams",
            recurso="/teams",
            nota="Filas de atendimento. Vira dimensão.",
        ),
        Sonda(
            nome="attendants",
            recurso="/attendants",
            nota="Atendentes. Vira dimensão.",
        ),
        Sonda(
            nome="metrics_tickets",
            recurso="/metrics/tickets",
            documentado=False,
            nota="Palpite. A doc cita 'Get tickets metrics' sem dar a URI. Se "
                 "responder, é agregado pronto — útil para conferir os nossos "
                 "próprios números, não para substituir a bronze.",
        ),
        Sonda(
            nome="metrics_open_tickets",
            recurso="/metrics/open-tickets",
            documentado=False,
            nota="Palpite, mesmo caso do anterior.",
        ),
    ]


# --- inventário de campos ---------------------------------------------------
def _achatar(registro: dict[str, Any], prefixo: str = "", profundidade: int = 2) -> dict[str, Any]:
    """Achata o registro em caminhos pontuados, até `profundidade` níveis.

    Os tickets do Blip aninham coisas relevantes (a fila dentro de `team`, o
    canal dentro de `customerIdentity`), então um inventário só de primeiro
    nível esconderia justamente o que vira dimensão.
    """
    plano: dict[str, Any] = {}
    for chave, valor in registro.items():
        caminho = f"{prefixo}{chave}"
        if isinstance(valor, dict) and profundidade > 1:
            plano.update(_achatar(valor, prefixo=f"{caminho}.", profundidade=profundidade - 1))
        else:
            plano[caminho] = valor
    return plano


def _tipo_legivel(valor: Any) -> str:
    """Nome curto do tipo, do jeito que interessa para escolher a coluna."""
    if valor is None:
        return "null"
    if isinstance(valor, bool):
        return "bool"
    if isinstance(valor, int):
        return "int"
    if isinstance(valor, float):
        return "float"
    if isinstance(valor, list):
        return "list"
    if isinstance(valor, dict):
        return "dict"
    return "str"


def inventariar(registros: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Monta o inventário de campos observados na amostra."""
    if not registros:
        return []

    tipos: dict[str, set[str]] = {}
    preenchidos: dict[str, int] = {}
    exemplos: dict[str, list[str]] = {}

    for registro in registros:
        for campo, valor in _achatar(registro).items():
            tipos.setdefault(campo, set()).add(_tipo_legivel(valor))
            if valor not in (None, "", [], {}):
                preenchidos[campo] = preenchidos.get(campo, 0) + 1
                amostras = exemplos.setdefault(campo, [])
                if len(amostras) < 3:
                    texto = str(valor)
                    amostras.append(texto if len(texto) <= 60 else texto[:57] + "...")

    total = len(registros)
    linhas = []
    for campo in sorted(tipos):
        cheios = preenchidos.get(campo, 0)
        linhas.append({
            "campo": campo,
            "tipos": ", ".join(sorted(tipos[campo] - {"null"}) or {"null"}),
            "preenchidos": cheios,
            "pct": round(100 * cheios / total, 1),
            "exemplos": exemplos.get(campo, []),
        })
    return linhas


# --- execução ---------------------------------------------------------------
def rodar_sonda(cliente: ClienteBlip, sonda: Sonda, amostra: int) -> dict[str, Any]:
    """Executa uma sonda e devolve o resultado, sem deixar erro escapar.

    Uma sonda que falha é informação, não interrupção: o motivo entra no
    relatório e as outras seguem.
    """
    try:
        registros = cliente.coletar(sonda.recurso, to=sonda.to, filtro=sonda.filtro, limite=amostra)
    except ErroBlip as exc:
        log.warning("Sonda %s falhou: %s", sonda.nome, exc)
        return {"sonda": sonda, "ok": False, "erro": str(exc), "registros": []}

    log.info("Sonda %s: %d registro(s) na amostra", sonda.nome, len(registros))
    return {"sonda": sonda, "ok": True, "erro": None, "registros": registros}


def salvar_amostra(nome: str, registros: list[dict[str, Any]]) -> Path | None:
    """Grava a amostra crua para inspeção manual. Nada é gravado se veio vazia."""
    if not registros:
        return None
    PASTA_AMOSTRAS.mkdir(parents=True, exist_ok=True)
    destino = PASTA_AMOSTRAS / f"{nome}.json"
    with open(destino, "w", encoding="utf-8") as arquivo:
        json.dump(registros, arquivo, ensure_ascii=False, indent=2, default=str)
    return destino


def imprimir_relatorio(resultados: list[dict[str, Any]]) -> None:
    """Relatório de tela: o que respondeu, o que não, e os campos de cada um."""
    print()
    print("=" * 78)
    print("RESUMO DAS SONDAS")
    print("=" * 78)
    for res in resultados:
        sonda: Sonda = res["sonda"]
        marca = "OK " if res["ok"] else "FALHOU"
        origem = "documentado" if sonda.documentado else "palpite"
        print(f"\n[{marca}] {sonda.nome}  ({origem})")
        print(f"        recurso: {sonda.recurso}")
        if sonda.filtro:
            print(f"        filtro : {sonda.filtro}")
        if res["ok"]:
            print(f"        amostra: {len(res['registros'])} registro(s)")
        else:
            print(f"        motivo : {res['erro']}")
        if sonda.nota:
            print(f"        nota   : {sonda.nota}")

    print()
    print("=" * 78)
    print("INVENTÁRIO DE CAMPOS")
    print("=" * 78)
    for res in resultados:
        if not res["ok"] or not res["registros"]:
            continue
        sonda: Sonda = res["sonda"]
        linhas = inventariar(res["registros"])
        print(f"\n--- {sonda.nome} ({len(res['registros'])} registros) ---")
        print(f"{'campo':<42} {'tipo':<12} {'preench.':>9}  exemplos")
        for linha in linhas:
            exemplos = " | ".join(linha["exemplos"])
            print(
                f"{linha['campo']:<42} {linha['tipos']:<12} "
                f"{linha['pct']:>7}%  {exemplos}"
            )


def verificar(cliente: ClienteBlip, cfg) -> int:
    """Confere, em duas requisições, se a chave é a certa antes de sondar nada.

    As duas perguntas são diferentes e falham por motivos diferentes, por isso
    valem separadas:

    1. `/account` fala com o próprio bot da chave. Se isso falha, a chave está
       errada ou incompleta, e nada mais vai funcionar.
    2. `/tickets` fala com a extensão de atendimento. Se o passo 1 passou e
       este falha, a chave é válida mas é de um bot filho: a extensão de
       atendimento responde pelo Router do contrato, não por bot individual.
       É o erro mais provável de quem está pegando a chave pela primeira vez.
    """
    print()
    print(f"Bot derivado da chave : {cfg.identificador}")
    print(f"Endpoint              : {cfg.url_commands}")
    print()

    try:
        conta = cliente.comando("/account", to=None) or {}
    except ErroBlip as exc:
        print("[FALHOU] Identidade do bot (/account)")
        print(f"         {exc}")
        return 1

    nome = conta.get("fullName") or conta.get("name") or "(sem nome)"
    print(f"[OK]     Identidade do bot: {nome}")
    for campo in ("email", "phoneNumber", "city"):
        if conta.get(campo):
            print(f"         {campo}: {conta[campo]}")

    try:
        colecao = cliente.comando(montar_uri("/tickets", skip=0, take=1)) or {}
    except ErroBlip as exc:
        print("[FALHOU] Extensão de atendimento (/tickets)")
        print(f"         {exc}")
        print()
        print("A chave é válida, mas este bot não responde pela extensão de")
        print("atendimento. Quase sempre significa que ela é de um bot filho e não")
        print("do Router do contrato. Volte ao portal e pegue a chave do Router.")
        return 1

    total = colecao.get("total")
    itens = colecao.get("items") or []
    print(f"[OK]     Extensão de atendimento respondeu ({len(itens)} ticket na amostra)")
    if isinstance(total, int):
        print(f"         total anunciado pela coleção: {total}")

    print()
    print("Chave correta. Pode rodar a descoberta completa:")
    print("    python explorar_blip.py --amostra 200 --dias 30")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--amostra", type=int, default=100,
                        help="Máximo de registros por recurso (padrão: 100).")
    parser.add_argument("--dias", type=int, default=7,
                        help="Janela de dias da sonda por período (padrão: 7).")
    parser.add_argument("--recurso", help="Roda só a sonda com este nome.")
    parser.add_argument("--verificar", action="store_true",
                        help="Só confere se a chave é a certa (2 requisições) e sai.")
    parser.add_argument("--verbose", action="store_true", help="Log em DEBUG.")
    args = parser.parse_args()

    configurar_logging(args.verbose)
    cfg = carregar_config_blip()
    log.info("Bot: %s", cfg.identificador)

    if args.verificar:
        return verificar(ClienteBlip(cfg), cfg)

    sondas = montar_sondas(args.dias)
    if args.recurso:
        sondas = [s for s in sondas if s.nome == args.recurso]
        if not sondas:
            log.error("Nenhuma sonda chamada %r. Nomes: %s",
                      args.recurso, ", ".join(s.nome for s in montar_sondas(args.dias)))
            return 2

    cliente = ClienteBlip(cfg)
    resultados = [rodar_sonda(cliente, sonda, args.amostra) for sonda in sondas]

    # As mensagens de um ticket são a fonte de "volume de mensagens por
    # atendimento". A URI depende de um id real, então só dá para sondar depois
    # de ter um ticket em mãos.
    ticket_exemplo = next(
        (r["registros"][0] for r in resultados
         if r["ok"] and r["registros"] and r["sonda"].recurso == "/tickets"),
        None,
    )
    if ticket_exemplo and ticket_exemplo.get("id"):
        sonda_msgs = Sonda(
            nome="mensagens_do_ticket",
            recurso=f"/tickets/{ticket_exemplo['id']}/messages",
            documentado=False,
            nota="Palpite de URI. Se responder, é a fonte de volume de mensagens "
                 "por atendimento (e de tempo de primeira resposta, se não vier "
                 "pronto no ticket).",
        )
        resultados.append(rodar_sonda(cliente, sonda_msgs, args.amostra))

    for res in resultados:
        destino = salvar_amostra(res["sonda"].nome, res["registros"])
        if destino:
            log.info("Amostra salva em %s", destino)

    imprimir_relatorio(resultados)

    respondidas = [r for r in resultados if r["ok"] and r["registros"]]
    print()
    print(f"{len(respondidas)} de {len(resultados)} sondas trouxeram dados.")
    print(f"Amostras cruas em: {PASTA_AMOSTRAS}")
    print("Elas têm dado pessoal (telefone, identificador de cliente). A pasta já")
    print("está no .gitignore; não anexe esses arquivos em e-mail nem chat.")
    return 0 if respondidas else 1


if __name__ == "__main__":
    raise SystemExit(main())
