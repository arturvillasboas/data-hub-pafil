"""Reconcilia distratos da pipeline (silver.distratos) vs. o CSV legado (rel_distratos)
de um mês — contagem, VGV e diferença por reserva. Gera reconciliacao/RECONCILIACAO_DISTRATOS_<mes>.md.

  python reconciliar_distratos.py --csv "<rel_distratos.csv>" --mes 2026-05
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

from config.settings import RAIZ, carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("reconciliar")

OUT_DIR = RAIZ / "reconciliacao"


def _num_br(s: str) -> float:
    """'421.497,20' -> 421497.20 ; vazio -> 0.0"""
    s = (s or "").strip()
    if not s:
        return 0.0
    return float(s.replace(".", "").replace(",", "."))


def ler_csv_legado(caminho: Path) -> dict[int, dict]:
    """Lê o CSV legado (rel_distratos) -> {reserva: {valor, empreendimento}}."""
    legado: dict[int, dict] = {}
    with open(caminho, "r", encoding="utf-8-sig", newline="") as f:
        leitor = csv.DictReader(f, delimiter=";")
        for linha in leitor:
            reserva_raw = (linha.get("Reserva") or "").strip()
            if not reserva_raw.isdigit():
                continue
            reserva = int(reserva_raw)
            legado[reserva] = {
                "valor": _num_br(linha.get("Valor do contrato", "")),
                "empreendimento": (linha.get("Empreendimento") or "").strip(),
            }
    return legado


def ler_pipeline(conn, mes: str) -> dict[int, dict]:
    """Lê silver.distratos do mês -> {id_reserva: {valor, empreendimento}}."""
    pipeline: dict[int, dict] = {}
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id_reserva, valor_contrato, empreendimento
            FROM silver.distratos
            WHERE ano_mes_distrato = %s
            """,
            (mes,),
        )
        for id_reserva, valor, empreend in cur.fetchall():
            pipeline[int(id_reserva)] = {
                "valor": float(valor or 0),
                "empreendimento": empreend or "",
            }
    return pipeline


def reconciliar(legado: dict[int, dict], pipeline: dict[int, dict], mes: str) -> tuple[str, bool]:
    """Monta o relatório markdown e diz se houve divergência."""
    set_leg, set_pipe = set(legado), set(pipeline)
    so_legado = sorted(set_leg - set_pipe)
    so_pipeline = sorted(set_pipe - set_leg)
    comuns = sorted(set_leg & set_pipe)

    vgv_leg = sum(v["valor"] for v in legado.values())
    vgv_pipe = sum(v["valor"] for v in pipeline.values())

    # divergências de valor entre reservas presentes nos dois lados (tolerância R$ 0,01)
    val_diff = [
        (r, legado[r]["valor"], pipeline[r]["valor"])
        for r in comuns
        if abs(legado[r]["valor"] - pipeline[r]["valor"]) > 0.01
    ]

    def brl(x: float) -> str:
        return "R$ " + f"{x:,.2f}".replace(",", "_").replace(".", ",").replace("_", ".")

    houve_div = bool(so_legado or so_pipeline or val_diff or len(set_leg) != len(set_pipe))

    L = []
    L.append(f"# Reconciliação de Distratos — {mes}")
    L.append("")
    L.append("Pipeline nova (API → silver.distratos) vs. CSV legado (rel_distratos, fechamento mensal).")
    L.append("")
    L.append("## Totais")
    L.append("")
    L.append("| Métrica | Legado (CSV) | Pipeline (API) | Δ |")
    L.append("|---|--:|--:|--:|")
    L.append(f"| Qtd distratos | {len(set_leg)} | {len(set_pipe)} | {len(set_pipe)-len(set_leg):+d} |")
    L.append(f"| VGV distratos | {brl(vgv_leg)} | {brl(vgv_pipe)} | {brl(vgv_pipe-vgv_leg)} |")
    L.append("")

    L.append("## Achados")
    L.append("")
    if not houve_div:
        L.append("✅ **Bate número-a-número** — mesmas reservas, mesmos valores.")
    else:
        if so_legado:
            L.append(f"- ⚠️ **{len(so_legado)} reserva(s) só no LEGADO** (a pipeline não trouxe): "
                     + ", ".join(map(str, so_legado)))
        if so_pipeline:
            L.append(f"- ⚠️ **{len(so_pipeline)} reserva(s) só na PIPELINE** (novas desde o export do CSV): "
                     + ", ".join(map(str, so_pipeline)))
        if val_diff:
            L.append(f"- ⚠️ **{len(val_diff)} reserva(s) com VGV divergente** (> R$ 0,01):")
            L.append("")
            L.append("  | Reserva | Legado | Pipeline | Δ |")
            L.append("  |--:|--:|--:|--:|")
            for r, vl, vp in val_diff[:50]:
                L.append(f"  | {r} | {brl(vl)} | {brl(vp)} | {brl(vp-vl)} |")
    L.append("")
    L.append("> Divergência é **achado**, não falha: o CSV é um snapshot do fechamento; a pipeline é "
             "estado atual (distratos novos entram). Reservas só-no-legado merecem investigação.")
    L.append("")
    return "\n".join(L), houve_div


def main() -> int:
    ap = argparse.ArgumentParser(description="Reconcilia distratos pipeline vs CSV legado.")
    ap.add_argument("--csv", required=True, help="caminho do CSV legado (rel_distratos)")
    ap.add_argument("--mes", required=True, help="mês de referência YYYY-MM (ex.: 2026-05)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    configurar_logging(args.verbose)
    # console do Windows é cp1252; o relatório tem → e emoji (UTF-8)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    caminho = Path(args.csv)
    if not caminho.exists():
        log.error("CSV não encontrado: %s", caminho)
        return 2

    legado = ler_csv_legado(caminho)
    cfg = carregar_config_pg()
    with db.conectar(cfg) as conn:
        pipeline = ler_pipeline(conn, args.mes)

    relatorio, houve_div = reconciliar(legado, pipeline, args.mes)

    OUT_DIR.mkdir(exist_ok=True)
    destino = OUT_DIR / f"RECONCILIACAO_DISTRATOS_{args.mes}.md"
    destino.write_text(relatorio, encoding="utf-8")

    # também imprime um resumo no console
    print(relatorio)
    log.info("Relatório salvo em %s", destino)
    return 1 if houve_div else 0


if __name__ == "__main__":
    raise SystemExit(main())
