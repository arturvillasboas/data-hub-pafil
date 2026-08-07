"""Popula os seeds silver.dpara_* a partir do JSON base64+DEFLATE embutido no Power
Query legado (_bi_ref/M_Empreendimentos.md) e, opcionalmente, de planilhas .xlsx.

  python popular_seeds.py [--gerentes depara_gerentes.xlsx] [--xlsm "Vendas Consolidadas.xlsm"]
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import zlib
from pathlib import Path

from config.settings import RAIZ, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("popular_seeds")

MD_LEGADO = RAIZ.parent / "_bi_ref" / "M_Empreendimentos.md"

# expr no markdown -> como carregar no seed.
#   json_cols : ordem das colunas em cada linha decodificada
#   tabela    : tabela alvo em silver
#   linha     : função (dict json_col->valor) -> dict (col_seed -> valor) p/ INSERT
MAPEAMENTOS = [
    dict(
        expr="dpara_ativo_receptivo",
        tabela="dpara_ativo_receptivo",
        json_cols=["canal", "lead_ou_prospect"],
        linha=lambda r: {"canal": r["canal"], "lead_ou_prospect": r["lead_ou_prospect"]},
    ),
    dict(
        expr="dpara_qualificacao_lead",
        tabela="dpara_qualificacao_lead",
        json_cols=["situacao", "qualificado"],
        linha=lambda r: {"situacao": r["situacao"], "qualificado": r["qualificado"]},
    ),
    dict(
        expr="dpara_ordem_etapa",
        tabela="dpara_ordem_etapa",
        json_cols=["etapa", "ordem"],
        linha=lambda r: {"etapa": r["etapa"],
                         "ordem": int(float(r["ordem"])) if r["ordem"] not in (None, "") else None},
    ),
    # DP-01 (gerente): removido daqui em 21/jul/2026 — o JSON legado só tinha 12/22
    # gerentes; a seed dpara_gerente_contexto vem exclusivamente do xlsx (carregar_gerentes).
    # Não há mais fallback JSON p/ esta seed.
    dict(
        # DP-02: canal/mídia (versão out24). vigência fixa.
        expr="dpara_canal_midia_out24",
        tabela="dpara_canal_midia",
        json_cols=["concat", "canal", "midia"],
        linha=lambda r: {"concat": r["concat"], "canal": r["canal"], "midia": r["midia"],
                         "vigencia_de": "2024-10-01"},
    ),
]


def _secoes(md: str) -> dict[str, str]:
    """Quebra o markdown em {nome_expr: texto} pelos cabeçalhos '### EXPR/TABELA nome'."""
    secoes: dict[str, str] = {}
    atual = None
    buffer: list[str] = []
    for linha in md.splitlines():
        m = re.match(r"^###\s+(?:EXPR|TABELA)\s+(.+?)\s*$", linha)
        if m:
            if atual:
                secoes[atual] = "\n".join(buffer)
            atual = m.group(1)
            buffer = []
        elif atual:
            buffer.append(linha)
    if atual:
        secoes[atual] = "\n".join(buffer)
    return secoes


def _decodificar(texto_secao: str) -> list[list]:
    """Extrai o 1º Binary.FromText e devolve as linhas JSON (lista de listas)."""
    m = re.search(r'Binary\.FromText\("([^"]+)"', texto_secao)
    if not m:
        raise ValueError("nenhum Binary.FromText na seção")
    raw = zlib.decompress(base64.b64decode(m.group(1)), -15)  # -15 = raw DEFLATE
    return json.loads(raw)


def carregar(conn, mapa: dict) -> int:
    secoes = carregar.secoes  # type: ignore[attr-defined]
    if mapa["expr"] not in secoes:
        log.warning("  expr %s não encontrada no markdown — pulando.", mapa["expr"])
        return 0
    linhas_json = _decodificar(secoes[mapa["expr"]])

    registros: list[dict] = []
    for valores in linhas_json:
        r = dict(zip(mapa["json_cols"], valores))
        registros.append(mapa["linha"](r))
    if not registros:
        return 0

    colunas = list(registros[0].keys())
    tabela = mapa["tabela"]
    from psycopg import sql

    placeholders = sql.SQL(", ").join(sql.Placeholder() for _ in colunas)
    consulta = sql.SQL(
        "INSERT INTO silver.{tab} ({cols}) VALUES ({ph}) ON CONFLICT DO NOTHING"
    ).format(
        tab=sql.Identifier(tabela),
        cols=sql.SQL(", ").join(map(sql.Identifier, colunas)),
        ph=placeholders,
    )
    with conn.cursor() as cur:
        cur.execute(sql.SQL("TRUNCATE silver.{}").format(sql.Identifier(tabela)))
        inseridos = 0
        for reg in registros:
            cur.execute(consulta, [reg[c] for c in colunas])
            inseridos += cur.rowcount
    log.info("  silver.%-22s <- %3d linhas (de %d no JSON)", tabela, inseridos, len(linhas_json))
    return inseridos


def carregar_depara_produtos(conn, xlsm: Path) -> int:
    """Carrega o de-para de empreendimento da aba DE_PARA_PRODUTOS (Vendas Consolidadas.xlsm).

    Colunas B/C/D: Produto (nome CRM) -> Produto_Depara (conformado) -> EP (espaço de negócios).
    """
    import openpyxl  # dependência opcional, só p/ ler o .xlsm
    from psycopg import sql

    wb = openpyxl.load_workbook(xlsm, read_only=True, data_only=True)
    ws = wb["DE_PARA_PRODUTOS"]
    linhas = list(ws.iter_rows(values_only=True))
    hdr_idx = next(i for i, r in enumerate(linhas) if r and "Produto" in r and "Produto_Depara" in r)
    hdr = linhas[hdr_idx]
    jo, jc, je = hdr.index("Produto"), hdr.index("Produto_Depara"), hdr.index("EP")

    registros = []
    vistos = set()
    for r in linhas[hdr_idx + 1:]:
        origem = (r[jo] or "").strip() if r[jo] else ""
        if not origem or origem in vistos:
            continue
        vistos.add(origem)
        registros.append((origem,
                          (r[jc] or "").strip() if r[jc] else None,
                          (r[je] or "").strip() if r[je] else None))

    with conn.cursor() as cur:
        cur.execute("TRUNCATE silver.dpara_empreendimento")
        for origem, conf, ep in registros:
            cur.execute(
                sql.SQL("INSERT INTO silver.dpara_empreendimento (nome_origem, nome_conformado, ep) "
                        "VALUES (%s, %s, %s) ON CONFLICT (nome_origem) DO NOTHING"),
                (origem, conf, ep),
            )
    log.info("  silver.%-22s <- %3d linhas (aba DE_PARA_PRODUTOS)", "dpara_empreendimento", len(registros))
    return len(registros)


def carregar_gerentes(conn, xlsx: Path) -> int:
    """Carrega os 2 de-paras de classificação do depara_gerentes.xlsx (fonte autoritativa).

    Aba "contexto"    -> silver.dpara_gerente_contexto   (classifica a RESERVA, pela
        chave crua "Gerente Responsavel" do CVCRM): Gerente Responsável | Gerente
        Apelido | Share | House/Parcerias | Regional.
    Aba "imobiliaria" -> silver.dpara_imobiliaria_house  (classifica LEADS e
        PRÉ-CADASTROS, pelo escritório do corretor vindo do headcount):
        Imobiliária | Share | House/Parcerias | Regional.

    Nenhuma das duas é fonte de EQUIPE do corretor — isso vem do headcount
    (ver carregar_headcount_corretores).
    """
    import openpyxl
    from psycopg import sql

    wb = openpyxl.load_workbook(xlsx, read_only=True, data_only=True)

    ws_c = wb["contexto"]
    linhas_c = list(ws_c.iter_rows(values_only=True))
    hdr_idx = next(i for i, r in enumerate(linhas_c)
                   if r and any(c == "Gerente Responsável" for c in r if c))
    hdr = list(linhas_c[hdr_idx])
    j_resp, j_apc = hdr.index("Gerente Responsável"), hdr.index("Gerente Apelido")
    j_share, j_hp, j_reg = hdr.index("Share"), hdr.index("House/Parcerias"), hdr.index("Regional")

    contextos, vistos_c = [], set()
    for r in linhas_c[hdr_idx + 1:]:
        resp = (r[j_resp] or "").strip() if r[j_resp] else ""
        if not resp or resp in vistos_c:
            continue
        vistos_c.add(resp)
        contextos.append((
            resp,
            (r[j_apc] or "").strip() if r[j_apc] else None,
            (r[j_share] or "").strip() if r[j_share] else None,
            (r[j_hp] or "").strip() if r[j_hp] else None,
            (r[j_reg] or "").strip() if r[j_reg] else None,
        ))

    # --- aba "imobiliaria": escritório -> Share/House/Regional (leads + pré-cadastros)
    ws_i = wb["imobiliaria"]
    linhas_i = list(ws_i.iter_rows(values_only=True))
    hdr_idx = next(i for i, r in enumerate(linhas_i)
                   if r and any(c == "Imobiliária" for c in r if c))
    hdr = list(linhas_i[hdr_idx])
    j_imob, j_sh = hdr.index("Imobiliária"), hdr.index("Share")
    j_hp, j_reg = hdr.index("House/Parcerias"), hdr.index("Regional")

    imobs, vistos_i = [], set()
    for r in linhas_i[hdr_idx + 1:]:
        imob = (r[j_imob] or "").strip() if r[j_imob] else ""
        if not imob or imob.lower() in vistos_i:
            continue
        vistos_i.add(imob.lower())
        imobs.append((
            imob,
            (r[j_sh] or "").strip() if r[j_sh] else None,
            (r[j_hp] or "").strip() if r[j_hp] else None,
            (r[j_reg] or "").strip() if r[j_reg] else None,
        ))

    with conn.cursor() as cur:
        cur.execute("TRUNCATE silver.dpara_gerente_contexto")
        for resp, ap_, sh, hp, reg in contextos:
            cur.execute(
                sql.SQL("INSERT INTO silver.dpara_gerente_contexto "
                        "(gerente_responsavel, gerente_apelido, share, house_parcerias, regional) "
                        "VALUES (%s,%s,%s,%s,%s) ON CONFLICT (gerente_responsavel) DO NOTHING"),
                (resp, ap_, sh, hp, reg),
            )
        cur.execute("TRUNCATE silver.dpara_imobiliaria_house")
        for imob, sh, hp, reg in imobs:
            cur.execute(
                sql.SQL("INSERT INTO silver.dpara_imobiliaria_house "
                        "(imobiliaria, share, house_parcerias, regional) "
                        "VALUES (%s,%s,%s,%s) ON CONFLICT (imobiliaria) DO NOTHING"),
                (imob, sh, hp, reg),
            )
    log.info("  silver.%-24s <- %3d linhas (aba contexto, autoritativo)", "dpara_gerente_contexto", len(contextos))
    log.info("  silver.%-24s <- %3d linhas (aba imobiliaria, autoritativo)", "dpara_imobiliaria_house", len(imobs))
    return len(contextos) + len(imobs)


def carregar_headcount_corretores(conn, xlsx: Path) -> int:
    """Carrega silver.dpara_corretor_headcount da planilha manual do backoffice
    (Base Corretores Pafil, aba "Base Pafil") — fonte autoritativa de Gerente/
    Supervisor por corretor. Só carrega os corretores com "Ativo/Inativo" = Ativo
    (o pedido do dev: "usar o nome do corretor como chave, referenciando corretores
    ativos da tabela de headcount" — o resto da planilha é histórico de desligados).
    """
    import openpyxl
    from psycopg import sql

    wb = openpyxl.load_workbook(xlsx, read_only=True, data_only=True)
    ws = wb["Base Pafil"]
    linhas = list(ws.iter_rows(values_only=True))
    hdr_idx = next(i for i, r in enumerate(linhas) if r and any(c == "Nome" for c in r if c) and any(c == "Gerente" for c in r if c))
    hdr = list(linhas[hdr_idx])
    j_house, j_nome, j_apelido = hdr.index("House"), hdr.index("Nome"), hdr.index("Apelido")
    j_imob, j_ger, j_sup = hdr.index("Imobiliaria"), hdr.index("Gerente"), hdr.index("Supervisor")
    j_ativo = hdr.index("Ativo/Inativo")

    regs, vistos = [], set()
    for r in linhas[hdr_idx + 1:]:
        nome = (r[j_nome] or "").strip() if r[j_nome] else ""
        ativo = (r[j_ativo] or "").strip().lower() if r[j_ativo] else ""
        if not nome or ativo != "ativo" or nome.lower() in vistos:
            continue
        vistos.add(nome.lower())
        regs.append((
            nome,
            (r[j_apelido] or "").strip() if r[j_apelido] else None,
            (r[j_imob] or "").strip() if r[j_imob] else None,
            (r[j_house] or "").strip() if r[j_house] else None,
            (r[j_ger] or "").strip() if r[j_ger] else None,
            (r[j_sup] or "").strip() if r[j_sup] else None,
        ))

    with conn.cursor() as cur:
        cur.execute("TRUNCATE silver.dpara_corretor_headcount")
        for nome, apelido, imob, house, ger, sup in regs:
            cur.execute(
                sql.SQL("INSERT INTO silver.dpara_corretor_headcount "
                        "(corretor, apelido, imobiliaria, house, gerente, supervisor) "
                        "VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT (corretor) DO NOTHING"),
                (nome, apelido, imob, house, ger, sup),
            )
    log.info("  silver.%-24s <- %3d linhas (aba Base Pafil, só Ativos)", "dpara_corretor_headcount", len(regs))
    return len(regs)


def _bloco_apoio(linhas: list, hdr_idx: int, ancora: str, offsets: dict[str, int]) -> list[dict]:
    """Extrai um "bloco" de de-para da aba Apoio (vários de-paras lado a lado).

    ancora  = nome de coluna ÚNICO no header que identifica o bloco;
    offsets = {nome_campo: deslocamento relativo à âncora} (pode ser negativo).
    """
    hdr = list(linhas[hdr_idx])
    j0 = hdr.index(ancora)
    regs = []
    for r in linhas[hdr_idx + 1:]:
        reg = {}
        for campo, off in offsets.items():
            v = r[j0 + off] if j0 + off < len(r) else None
            reg[campo] = str(v).strip() if v is not None and str(v).strip() != "" else None
        regs.append(reg)
    return regs


def carregar_leads_apoio(conn, xlsm: Path, secoes: dict[str, str]) -> int:
    """Recarrega os 4 de-paras de lead da aba Apoio do Base de Leads.xlsm (fonte VIVA).

    A aba Apoio é o painel que o analista já mantém hoje; cada de-para é um bloco de
    colunas lado a lado (header na mesma linha):
      - Situação/Qualificado?            -> silver.dpara_qualificacao_lead  (MQL)
      - Canal_Mídia/Canal/Mídia          -> silver.dpara_canal_midia        (origem+mídia)
      - Canal/Lead ou Prospect           -> silver.dpara_ativo_receptivo
      - CONCAT/CANAL/MÍDIA/ORIGEM DA...  -> silver.dpara_canal_midia_dc     (chave UTM, canal 2.0)
    Complemento canal/mídia: concats do JSON out/24 ausentes no xlsm entram marcados
    (leads antigos perderiam o match sem a união).
    """
    import openpyxl
    from psycopg import sql

    wb = openpyxl.load_workbook(xlsm, read_only=True, data_only=True)
    ws = wb["Apoio"]
    linhas = list(ws.iter_rows(values_only=True))
    hdr_idx = next(i for i, r in enumerate(linhas) if r and any(c == "Canal_Mídia" for c in r if c))
    origem_txt = f"SharePoint: {xlsm.name} (aba Apoio)"
    total = 0

    with conn.cursor() as cur:
        # --- qualificação (MQL): Situação -> Qualificado? --------------------
        regs = [r for r in _bloco_apoio(linhas, hdr_idx, "Qualificado?", {"situacao": -1, "qualificado": 0})
                if r["situacao"]]
        vistos: set[str] = set()
        cur.execute("TRUNCATE silver.dpara_qualificacao_lead")
        for r in regs:
            if r["situacao"].lower() in vistos:
                continue
            vistos.add(r["situacao"].lower())
            cur.execute("INSERT INTO silver.dpara_qualificacao_lead (situacao, qualificado, _origem) "
                        "VALUES (%s,%s,%s) ON CONFLICT DO NOTHING",
                        (r["situacao"], r["qualificado"], origem_txt))
        log.info("  silver.%-24s <- %3d linhas (aba Apoio, vivo)", "dpara_qualificacao_lead", len(vistos))
        total += len(vistos)

        # --- ativo/receptivo: Canal -> Lead ou Prospect ----------------------
        regs = [r for r in _bloco_apoio(linhas, hdr_idx, "Lead ou Prospect", {"canal": -1, "lead_ou_prospect": 0})
                if r["canal"]]
        vistos = set()
        cur.execute("TRUNCATE silver.dpara_ativo_receptivo")
        for r in regs:
            if r["canal"].lower() in vistos:
                continue
            vistos.add(r["canal"].lower())
            cur.execute("INSERT INTO silver.dpara_ativo_receptivo (canal, lead_ou_prospect, _origem) "
                        "VALUES (%s,%s,%s) ON CONFLICT DO NOTHING",
                        (r["canal"], r["lead_ou_prospect"], origem_txt))
        log.info("  silver.%-24s <- %3d linhas (aba Apoio, vivo)", "dpara_ativo_receptivo", len(vistos))
        total += len(vistos)

        # --- canal/mídia por origem+mídia (vocabulário out24, vivo) ----------
        regs = [r for r in _bloco_apoio(linhas, hdr_idx, "Canal_Mídia", {"concat": 0, "canal": 1, "midia": 3})
                if r["concat"]]
        vistos = set()
        cur.execute("TRUNCATE silver.dpara_canal_midia")
        for r in regs:
            if r["concat"].lower() in vistos:
                continue
            vistos.add(r["concat"].lower())
            cur.execute("INSERT INTO silver.dpara_canal_midia (concat, canal, midia, vigencia_de, _origem) "
                        "VALUES (%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                        (r["concat"], r["canal"], r["midia"], "2024-10-01", origem_txt))
        n_xlsm = len(vistos)
        n_json = 0
        if "dpara_canal_midia_out24" in secoes:  # complemento: foto out/24 do M legado
            for concat, canal, midia in _decodificar(secoes["dpara_canal_midia_out24"]):
                concat = (concat or "").strip()
                if not concat or concat.lower() in vistos:
                    continue
                vistos.add(concat.lower())
                cur.execute("INSERT INTO silver.dpara_canal_midia (concat, canal, midia, vigencia_de, _origem) "
                            "VALUES (%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                            (concat, canal, midia, "2024-10-01",
                             "JSON out24 (complemento — AUSENTE no xlsm; migrar p/ o Excel)"))
                n_json += 1
        log.info("  silver.%-24s <- %3d linhas (%d aba Apoio + %d herdadas do JSON out24)",
                 "dpara_canal_midia", n_xlsm + n_json, n_xlsm, n_json)
        total += n_xlsm + n_json

        # --- canal/mídia D.C (chave UTM — decide o canal 2.0 pós-out/24) -----
        regs = [r for r in _bloco_apoio(linhas, hdr_idx, "CONCAT",
                                        {"concat": 0, "canal": 1, "midia": 2, "trafego": 3})
                if r["concat"]]
        vistos = set()
        cur.execute("TRUNCATE silver.dpara_canal_midia_dc")
        for r in regs:
            if r["concat"].lower() in vistos:
                continue
            vistos.add(r["concat"].lower())
            cur.execute("INSERT INTO silver.dpara_canal_midia_dc (concat, canal, midia, trafego, _origem) "
                        "VALUES (%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                        (r["concat"], r["canal"], r["midia"], r["trafego"], origem_txt))
        log.info("  silver.%-24s <- %3d linhas (aba Apoio, vivo)", "dpara_canal_midia_dc", len(vistos))
        total += len(vistos)

    return total


def carregar_etapa_precadastro(conn, xlsm: Path) -> int:
    """Carrega silver.dpara_etapa_precadastro (DP-05) da aba Apoio do Base - Crédito.xlsm.

    Mesmo padrão de bloco lado-a-lado do Base de Leads.xlsm: colunas
    "Etapa WKF" | "Etapa precadastro BI" | "Etapa precadastro BI Detalhada"
    (a situação crua do CVCRM -> etapa do funil de crédito do BI).
    """
    import openpyxl
    from psycopg import sql

    wb = openpyxl.load_workbook(xlsm, read_only=True, data_only=True)
    ws = wb["Apoio"]
    linhas = list(ws.iter_rows(values_only=True))
    hdr_idx = next(i for i, r in enumerate(linhas) if r and any(c == "Etapa precadastro BI" for c in r if c))
    origem_txt = f"SharePoint: {xlsm.name} (aba Apoio)"

    regs = [r for r in _bloco_apoio(
                linhas, hdr_idx, "Etapa precadastro BI",
                {"etapa_wkf": -1, "etapa_bi": 0, "etapa_bi_detalhada": 1})
            if r["etapa_wkf"]]

    vistos: set[str] = set()
    with conn.cursor() as cur:
        cur.execute("TRUNCATE silver.dpara_etapa_precadastro")
        for r in regs:
            chave = r["etapa_wkf"].lower()
            if chave in vistos:
                continue
            vistos.add(chave)
            cur.execute(
                sql.SQL("INSERT INTO silver.dpara_etapa_precadastro "
                        "(etapa_wkf, etapa_bi, etapa_bi_detalhada, _origem) "
                        "VALUES (%s,%s,%s,%s) ON CONFLICT DO NOTHING"),
                (r["etapa_wkf"], r["etapa_bi"], r["etapa_bi_detalhada"], origem_txt),
            )
    log.info("  silver.%-24s <- %3d linhas (aba Apoio)", "dpara_etapa_precadastro", len(vistos))
    return len(vistos)


def carregar_precadastro_credito_manual(conn, xlsx: Path) -> int:
    """Carrega silver.precadastros_credito_manual do export "Relatório Web" do
    CVCRM (relatorios_precadastro.xlsx, aba Sheet1). NÃO é de-para — 1 linha
    por pré-cadastro (chave = Id), só as 2 colunas que a API CVDW não traz:
    "Aprovação de crédito" e "Encaminhado ao CCA" (a maioria fica NULL, é
    esperado — cobre só os pré-cadastros tocados pelo time de crédito).
    """
    import openpyxl
    from psycopg import sql

    wb = openpyxl.load_workbook(xlsx, read_only=True, data_only=True)
    ws = wb["Sheet1"]
    linhas = ws.iter_rows(values_only=True)
    hdr = list(next(linhas))
    j_id = hdr.index("Id")
    j_apr = hdr.index("Aprovação de crédito")
    j_cca = hdr.index("Encaminhado ao CCA")
    origem_txt = f"SharePoint: {xlsx.name} (aba Sheet1)"

    regs = []
    vistos: set[int] = set()
    for r in linhas:
        id_pc = r[j_id]
        if id_pc is None or id_pc in vistos:
            continue
        vistos.add(id_pc)
        apr = (r[j_apr] or "").strip() if r[j_apr] else None
        cca = (r[j_cca] or "").strip() if r[j_cca] else None
        regs.append((int(id_pc), apr, cca))

    with conn.cursor() as cur:
        cur.execute("TRUNCATE silver.precadastros_credito_manual")
        for id_pc, apr, cca in regs:
            cur.execute(
                sql.SQL("INSERT INTO silver.precadastros_credito_manual "
                        "(id_precadastro, aprovacao_credito, encaminhado_cca, _origem) "
                        "VALUES (%s,%s,%s,%s) ON CONFLICT DO NOTHING"),
                (id_pc, apr, cca, origem_txt),
            )
    log.info("  silver.%-24s <- %3d linhas (aba Sheet1)", "precadastros_credito_manual", len(regs))
    return len(regs)


def main() -> int:
    ap = argparse.ArgumentParser(description="Popula seeds de-para (JSON legado + opcional xlsm).")
    ap.add_argument("--xlsm", help="caminho de Vendas Consolidadas.xlsm (carrega DE_PARA_PRODUTOS)")
    ap.add_argument("--gerentes", help="caminho de depara_gerentes.xlsx (recarrega "
                                       "dpara_gerente_contexto). Default: variável DEPARA_GERENTES_XLSX do .env")
    ap.add_argument("--headcount-corretores", help="caminho de Base Corretores Pafil.xlsx (recarrega "
                                       "dpara_corretor_headcount, só Ativos). Default: HEADCOUNT_CORRETORES_XLSX do .env")
    ap.add_argument("--leads-apoio", help="caminho de Base de Leads.xlsm (aba Apoio: recarrega os 4 "
                                          "de-paras de lead vivos). Default: DEPARA_LEADS_XLSM do .env")
    ap.add_argument("--etapa-precadastro", help="caminho de Base - Crédito.xlsm (aba Apoio: recarrega "
                                          "dpara_etapa_precadastro, DP-05). Default: ETAPA_PRECADASTRO_XLSM do .env")
    ap.add_argument("--credito-manual", help="caminho de relatorios_precadastro.xlsx (recarrega "
                                          "precadastros_credito_manual: Aprovação de crédito/Encaminhado ao CCA). "
                                          "Default: PRECADASTRO_CREDITO_XLSX do .env")
    args = ap.parse_args()

    # Fonte autoritativa dos gerentes: arg explícito ou o xlsx sincronizado (via .env).
    gerentes_path = args.gerentes or os.getenv("DEPARA_GERENTES_XLSX")
    headcount_path = args.headcount_corretores or os.getenv("HEADCOUNT_CORRETORES_XLSX")
    leads_apoio_path = args.leads_apoio or os.getenv("DEPARA_LEADS_XLSM")
    etapa_precadastro_path = args.etapa_precadastro or os.getenv("ETAPA_PRECADASTRO_XLSM")
    credito_manual_path = args.credito_manual or os.getenv("PRECADASTRO_CREDITO_XLSX")

    configurar_logging(False)
    if not MD_LEGADO.exists():
        log.error("Markdown legado não encontrado: %s", MD_LEGADO)
        return 2

    md = MD_LEGADO.read_text(encoding="utf-8")
    carregar.secoes = _secoes(md)  # type: ignore[attr-defined]

    cfg = carregar_config_pg()
    total = 0
    n_seeds = 0
    with db.conectar(cfg) as conn:
        # de-paras de lead vivos (aba Apoio): se o xlsm existe, ele é a fonte — não
        # sobrescrever com as fotos congeladas do JSON legado.
        SEEDS_APOIO = {"dpara_qualificacao_lead", "dpara_ativo_receptivo", "dpara_canal_midia"}
        apoio_ok = bool(leads_apoio_path) and Path(leads_apoio_path).exists()

        log.info("Populando seeds de-para a partir de %s:", MD_LEGADO.name)
        for mapa in MAPEAMENTOS:
            # havendo xlsm autoritativo, nunca sobrescreve com o JSON legado congelado
            if apoio_ok and mapa["tabela"] in SEEDS_APOIO:
                continue
            total += carregar(conn, mapa)
            n_seeds += 1
        if gerentes_path:
            gx = Path(gerentes_path)
            if gx.exists():
                total += carregar_gerentes(conn, gx)
                n_seeds += 1
            else:
                # não recarrega do JSON: mantém a dpara_gerentes atual em vez de sujá-la
                log.warning("  gerentes xlsx não encontrado (%s) — dpara_gerentes mantida como está.", gx)
        if headcount_path:
            hx = Path(headcount_path)
            if hx.exists():
                total += carregar_headcount_corretores(conn, hx)
                n_seeds += 1
            else:
                log.warning("  headcount xlsx não encontrado (%s) — dpara_corretor_headcount mantida como está.", hx)
        if apoio_ok:
            total += carregar_leads_apoio(conn, Path(leads_apoio_path), carregar.secoes)  # type: ignore[attr-defined]
            n_seeds += 4
        elif leads_apoio_path:
            log.warning("  Base de Leads.xlsm não encontrado (%s) — de-paras de lead mantidos como estão.",
                        leads_apoio_path)
        if args.xlsm:
            xlsm = Path(args.xlsm)
            if xlsm.exists():
                total += carregar_depara_produtos(conn, xlsm)
                n_seeds += 1
            else:
                log.warning("  --xlsm não encontrado: %s", xlsm)
        if etapa_precadastro_path:
            ep = Path(etapa_precadastro_path)
            if ep.exists():
                total += carregar_etapa_precadastro(conn, ep)
                n_seeds += 1
            else:
                log.warning("  etapa-precadastro xlsm não encontrado (%s) — dpara_etapa_precadastro mantida como está.", ep)
        if credito_manual_path:
            cm = Path(credito_manual_path)
            if cm.exists():
                total += carregar_precadastro_credito_manual(conn, cm)
                n_seeds += 1
            else:
                log.warning("  credito-manual xlsx não encontrado (%s) — precadastros_credito_manual mantida como está.", cm)
        conn.commit()
    log.info("Concluído: %d linhas carregadas em %d seeds.", total, n_seeds)
    log.info("Pendentes (SharePoint): feriados, profissões, equipe_corretor (superada por dim_corretor).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
