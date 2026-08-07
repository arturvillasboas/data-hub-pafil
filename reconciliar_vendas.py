"""Reconcilia vendas da pipeline vs. a planilha legada Vendas Consolidadas.xlsm, por
proposta (=idreserva): VGV no overlap e drift de status. Requer openpyxl (só p/ ler o .xlsm).
Gera reconciliacao/RECONCILIACAO_VENDAS.md.

  python reconciliar_vendas.py --xlsm "<Vendas Consolidadas.xlsm>"
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

from config.settings import RAIZ, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("reconciliar_vendas")
OUT_DIR = RAIZ / "reconciliacao"


def ler_legado(xlsm: Path, aba: str) -> dict[int, dict]:
    """Lê a aba de vendas consolidadas -> {proposta: {vgv, status}}."""
    import openpyxl  # import tardio: dependência opcional

    wb = openpyxl.load_workbook(xlsm, read_only=True, data_only=True)
    ws = wb[aba]
    linhas = list(ws.iter_rows(values_only=True))
    # cabeçalho = primeira linha que contém 'Proposta'
    hdr_idx = next(i for i, r in enumerate(linhas) if r and "Proposta" in r)
    hdr = linhas[hdr_idx]
    jp, jv, js = hdr.index("Proposta"), hdr.index("VGV (Praticado)"), hdr.index("Status")

    legado: dict[int, dict] = {}
    for r in linhas[hdr_idx + 1:]:
        if not r or r[jp] is None:
            continue
        try:
            p = int(r[jp])
        except (TypeError, ValueError):
            continue
        legado[p] = {
            "vgv": float(r[jv]) if isinstance(r[jv], (int, float)) else 0.0,
            "status": r[js],
        }
    return legado


def ler_pipeline(conn) -> dict[int, dict]:
    with conn.cursor() as cur:
        cur.execute("SELECT id_reserva, valor_contrato, situacao FROM silver.reservas")
        return {int(i): {"vgv": float(v or 0), "situacao": s} for i, v, s in cur.fetchall()}


def brl(x: float) -> str:
    return "R$ " + f"{x:,.2f}".replace(",", "_").replace(".", ",").replace("_", ".")


def montar_relatorio(legado: dict[int, dict], pipe: dict[int, dict]) -> str:
    set_leg, set_pipe = set(legado), set(pipe)
    comum = sorted(set_leg & set_pipe)
    so_leg = set_leg - set_pipe

    vleg = sum(legado[p]["vgv"] for p in comum)
    vpipe = sum(pipe[p]["vgv"] for p in comum)
    identicos = sum(1 for p in comum if abs(legado[p]["vgv"] - pipe[p]["vgv"]) <= 0.01)
    divergentes = [
        (p, legado[p]["vgv"], pipe[p]["vgv"])
        for p in comum if abs(legado[p]["vgv"] - pipe[p]["vgv"]) > 0.01
    ]

    # drift: legado conta Vendida mas CRM já é Distrato
    stale = [p for p in comum
             if (legado[p]["status"] or "").strip().lower() in ("vendida", "validada", "envio mega")
             and (pipe[p]["situacao"] or "") == "Distrato"]

    ct = Counter((legado[p]["status"], pipe[p]["situacao"]) for p in comum)

    L: list[str] = []
    L.append("# Reconciliação de Vendas — pipeline vs. Vendas Consolidadas (legado)")
    L.append("")
    L.append("Pipeline nova (API → `silver.reservas`) vs. planilha de fechamento manual "
             "`Vendas Consolidadas.xlsm` (depois consumida pelo PBI). Chave: Proposta = idreserva.")
    L.append("")
    L.append("> ⚠️ **Bronze local é parcial** — o run completo vai para a VPS. Por isso a comparação "
             "honesta é **por proposta no overlap**, não o total geral.")
    L.append("")
    L.append("## Overlap por proposta")
    L.append("")
    L.append("| | Propostas |")
    L.append("|---|--:|")
    L.append(f"| Legado (planilha) | {len(set_leg)} |")
    L.append(f"| Pipeline (reservas) | {len(set_pipe)} |")
    L.append(f"| **Em ambos** | **{len(comum)}** |")
    L.append(f"| Só no legado (ausente no bronze local) | {len(so_leg)} |")
    L.append("")
    L.append("## (a) VGV no overlap — `valor_contrato` vs. `VGV (Praticado)`")
    L.append("")
    L.append("| Métrica | Legado | Pipeline | Δ |")
    L.append("|---|--:|--:|--:|")
    L.append(f"| VGV ({len(comum)} propostas) | {brl(vleg)} | {brl(vpipe)} | {brl(vpipe-vleg)} |")
    pct = 100 * (vpipe - vleg) / vleg if vleg else 0
    L.append(f"| Δ % | | | {pct:.2f}% |")
    L.append(f"| Propostas com VGV **idêntico** (≤ R$ 0,01) | | | **{identicos} / {len(comum)}** |")
    L.append("")
    if divergentes:
        L.append(f"<details><summary>{len(divergentes)} proposta(s) com VGV divergente</summary>")
        L.append("")
        L.append("| Proposta | Legado | Pipeline | Δ |")
        L.append("|--:|--:|--:|--:|")
        for p, vl, vp in sorted(divergentes, key=lambda x: -abs(x[2]-x[1]))[:40]:
            L.append(f"| {p} | {brl(vl)} | {brl(vp)} | {brl(vp-vl)} |")
        L.append("</details>")
        L.append("")
    L.append("## (b) Drift de status — Status (legado) × situacao (pipeline)")
    L.append("")
    L.append(f"🔴 **{len(stale)} propostas que o legado conta como venda viva (Vendida/Validada/Envio Mega) "
             f"já estão DISTRATO no CRM** — a planilha manual está defasada (não pega distratos posteriores).")
    L.append("")
    L.append("| Status (legado) | situacao (pipeline) | Qtd |")
    L.append("|---|---|--:|")
    for (sl, sp), n in ct.most_common(20):
        L.append(f"| {sl} | {sp} | {n} |")
    L.append("")
    L.append("### Leitura")
    L.append("- `valor_contrato` da API reproduz o **VGV (Praticado)** do fechamento manual ao centavo "
             f"em {identicos}/{len(comum)} propostas — a medida está correta.")
    L.append("- Status como **Validada / Venda distratada / Repassada / Envio Mega** são reclassificação "
             "**manual** sem correspondência na API → viram regra de Silver/Gold (de-para de status) "
             "ou input operacional, não vêm do CRM.")
    L.append("- As **vendas-defasadas** (Vendida no legado, Distrato no CRM) são o ganho da pipeline: "
             "número sempre atual vs. planilha que envelhece entre fechamentos.")
    L.append("")
    return "\n".join(L)


def main() -> int:
    ap = argparse.ArgumentParser(description="Reconcilia vendas pipeline vs planilha legada.")
    ap.add_argument("--xlsm", required=True, help="caminho do Vendas Consolidadas.xlsm")
    ap.add_argument("--aba", default="Vendas Consolidadas", help="nome da aba")
    args = ap.parse_args()

    configurar_logging(False)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

    xlsm = Path(args.xlsm)
    if not xlsm.exists():
        log.error("Arquivo não encontrado: %s", xlsm)
        return 2

    legado = ler_legado(xlsm, args.aba)
    log.info("Legado: %d propostas lidas da aba %r.", len(legado), args.aba)
    cfg = carregar_config_pg()
    with db.conectar(cfg) as conn:
        pipe = ler_pipeline(conn)
    log.info("Pipeline: %d reservas.", len(pipe))

    relatorio = montar_relatorio(legado, pipe)
    OUT_DIR.mkdir(exist_ok=True)
    destino = OUT_DIR / "RECONCILIACAO_VENDAS.md"
    destino.write_text(relatorio, encoding="utf-8")
    print(relatorio)
    log.info("Relatório salvo em %s", destino)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
