"""Materializa a estrutura versionada de de-paras em DEPARA_DIR (SharePoint/OneDrive).

Para cada de-para do config/deparas.yml cria:
    <DEPARA_DIR>/depara_<nome>/
        arquivo/   -> o .xlsx do de-para (copiado, materializado do silver, ou gerado)
        caminho/   -> caminho.md documentando origem, tabela silver, como atualizar

Uso:
  python montar_estrutura_depara.py            # monta tudo (DEPARA_DIR do .env)
  python montar_estrutura_depara.py --destino <pasta>
"""
from __future__ import annotations

import argparse
import os
import shutil
from datetime import date
from pathlib import Path

import openpyxl
import yaml

from config.settings import RAIZ, carregar_config_pg

MANIFESTO = RAIZ / "config" / "deparas.yml"
LIMITE_COPIA_MB = 40  # nao copia fontes gigantes; documenta e aponta o caminho


def exportar_silver(tabela: str, destino: Path) -> str:
    """SELECT * FROM silver.<tabela> -> .xlsx. Materializa de-para hoje embutido no pipeline."""
    from cvdw import db
    with db.conectar(carregar_config_pg()) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema='silver' AND table_name=%s ORDER BY ordinal_position", (tabela,))
        cols = [r[0] for r in cur.fetchall()]
        if not cols:
            return f"tabela silver.{tabela} nao existe"
        cur.execute(f'SELECT {", ".join(chr(34)+c+chr(34) for c in cols)} FROM silver.{tabela}')
        linhas = cur.fetchall()
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = tabela[:31]
    ws.append(cols)
    for r in linhas:
        ws.append(list(r))
    wb.save(destino / f"{tabela}.xlsx")
    return f"materializado {len(linhas)} linhas"


def doc_caminho(pasta: Path, d: dict, base: Path, status: str, fonte_txt: str) -> None:
    md = pasta / "caminho" / "caminho.md"
    linhas = [
        f"# de-para: {d['nome']}",
        "",
        f"- **descrição:** {d.get('descricao','')}",
        f"- **tabela silver:** `{d.get('silver') or '—'}`",
        f"- **tipo:** {d['tipo']}",
        f"- **origem:** {fonte_txt}",
        f"- **status:** {status}",
        f"- **atualizado em:** {date.today().isoformat()}",
        "",
        "## Como atualizar",
    ]
    if d["tipo"] == "arquivo":
        linhas.append("Substituir o arquivo em `arquivo/` pela versão nova da fonte acima (o dono do processo mantém a fonte no SharePoint).")
    elif d["tipo"] == "silver":
        linhas.append(f"Rodar `montar_estrutura_depara.py` — re-exporta `silver.{d['silver']}` para `arquivo/`. "
                      "O conteúdo hoje vive embutido no pipeline (JSON/seed); este xlsx é a cópia legível/versionada.")
    elif d["tipo"] == "gerado":
        linhas.append("Rodar `gerar_depara_classificacao.py` (lê a Vendas Consolidadas) e depois `montar_estrutura_depara.py`.")
    else:
        linhas.append("**Pendente:** falta a fonte. Ver descrição — precisa do xlsx do SharePoint / carga.")
    md.write_text("\n".join(linhas) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Monta a estrutura versionada de de-paras.")
    ap.add_argument("--destino", help="pasta destino (default: DEPARA_DIR do .env)")
    args = ap.parse_args()

    destino = Path(args.destino or os.getenv("DEPARA_DIR", ""))
    if not destino:
        print("ERRO: defina DEPARA_DIR no .env ou passe --destino."); return 2
    destino.mkdir(parents=True, exist_ok=True)

    cfg = yaml.safe_load(MANIFESTO.read_text(encoding="utf-8"))
    base = Path(cfg["base_sharepoint"])
    print(f"Destino: {destino}\n")

    for d in cfg["deparas"]:
        pasta = destino / f"depara_{d['nome']}"
        (pasta / "arquivo").mkdir(parents=True, exist_ok=True)
        (pasta / "caminho").mkdir(parents=True, exist_ok=True)
        tipo = d["tipo"]
        status, fonte_txt = "?", "—"

        try:
            if tipo == "arquivo":
                src = base / d["fonte_rel"]
                fonte_txt = f"`{src}`"
                if not src.exists():
                    status = "FONTE NAO ENCONTRADA"
                elif src.stat().st_size > LIMITE_COPIA_MB * 1024 * 1024:
                    status = f"arquivo grande ({src.stat().st_size//1024//1024} MB) — nao copiado, ver caminho"
                else:
                    shutil.copy2(src, pasta / "arquivo" / src.name)
                    status = f"copiado ({src.name})"
            elif tipo == "silver":
                fonte_txt = f"materializado de `silver.{d['silver']}` (hoje embutido no pipeline)"
                status = exportar_silver(d["silver"], pasta / "arquivo")
            elif tipo == "gerado":
                src = destino / d["fonte_rel"]
                fonte_txt = f"gerado por script -> `{src.name}`"
                if src.exists() and src.resolve() != (pasta / "arquivo" / src.name).resolve():
                    shutil.copy2(src, pasta / "arquivo" / src.name)
                    status = f"copiado ({src.name})"
                elif src.exists():
                    status = "ja no lugar"
                else:
                    status = "FALTA GERAR (rodar gerar_depara_classificacao.py)"
            else:
                fonte_txt = "pendente (SharePoint / carga)"
                status = "pendente"
        except Exception as exc:  # noqa: BLE001
            status = f"ERRO: {str(exc).splitlines()[0]}"

        doc_caminho(pasta, d, base, status, fonte_txt)
        print(f"  depara_{d['nome']:24} [{tipo:8}] {status}")

    print("\nEstrutura montada.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
