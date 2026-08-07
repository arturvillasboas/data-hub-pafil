"""Descoberta de schema da API CVDW: amostra cada objeto, infere tipos (formato BR)
e a chave de negócio. Gera schema/cvdw_schema.json (+ report.md).

  python descoberta_schema.py [--registros 10] [--objetos reservas,leads]
"""
from __future__ import annotations
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from config.settings import Objeto, carregar_config_api, carregar_objetos
from cvdw.api import ClienteCVDW, ErroAPI
from cvdw.log import configurar_logging, get_logger
from cvdw.tipos import (
    consolidar_tipo,
    inferir_tipo,
    nome_coluna,
    tipo_sql,
)

log = get_logger("descoberta")

RAIZ = Path(__file__).resolve().parent
DIR_SCHEMA = RAIZ / "schema"
ARQ_JSON = DIR_SCHEMA / "cvdw_schema.json"
ARQ_REPORT = DIR_SCHEMA / "cvdw_schema_report.md"


def inferir_campos(registros: list[dict[str, Any]], profundidade: int = 1) -> list[dict]:
    """Infere a lista de campos de um conjunto de registros.

    Desce `profundidade` níveis em objetos/listas-de-objetos aninhados.
    """
    chaves = _chaves_ordenadas(registros)
    total = len(registros)
    campos: list[dict] = []

    for chave in chaves:
        valores = [reg.get(chave) for reg in registros]
        presentes = [v for v in valores if v is not None and v != ""]
        # nullable se algum registro não tem a chave ou tem valor nulo/vazio.
        nullable = len(presentes) < total or any(chave not in reg for reg in registros)

        tipo = consolidar_tipo([inferir_tipo(v) for v in presentes])
        campo: dict[str, Any] = {
            "coluna": nome_coluna(chave),
            "chave_original": chave,
            "tipo": tipo,
            "tipo_sql": tipo_sql(tipo),
            "nullable": bool(nullable),
            "exemplo": _exemplo_str(next(iter(presentes), None)),
        }

        if profundidade > 0 and tipo == "objeto":
            sub = [v for v in presentes if isinstance(v, dict)]
            campo["subcampos"] = inferir_campos(sub, profundidade - 1)
        elif profundidade > 0 and tipo == "lista":
            sub_objs: list[dict] = []
            for v in presentes:
                if isinstance(v, list):
                    sub_objs.extend(x for x in v if isinstance(x, dict))
            if sub_objs:
                campo["subcampos"] = inferir_campos(sub_objs, profundidade - 1)

        campos.append(campo)
    return campos


def _chaves_ordenadas(registros: list[dict[str, Any]]) -> list[str]:
    """Coleta as chaves preservando a ordem de primeira aparição."""
    vistos: set[str] = set()
    ordem: list[str] = []
    for reg in registros:
        for chave in reg.keys():
            if chave not in vistos:
                vistos.add(chave)
                ordem.append(chave)
    return ordem


def _exemplo_str(valor: Any) -> str | None:
    """Converte um valor de exemplo em string curta para o schema/relatório."""
    if valor is None:
        return None
    if isinstance(valor, (dict, list)):
        texto = json.dumps(valor, ensure_ascii=False)
    else:
        texto = str(valor)
    return texto if len(texto) <= 120 else texto[:117] + "..."


def detectar_id(
    obj: Objeto, campos: list[dict], registros: list[dict[str, Any]]
) -> tuple[str | None, str]:
    """Determina a coluna de id de negócio (ou None -> hash).

    Verifica a unicidade na amostra: se o candidato se repete (ex.: idreserva
    numa tabela de comissões), cai para o hash técnico da linha.
    """
    nomes = {c["coluna"] for c in campos}

    # 1) id fixado manualmente no config.
    if obj.id is None:
        return None, "config_hash"
    if obj.id and obj.id != "auto":
        col = nome_coluna(obj.id)
        if col not in nomes:
            log.warning("[%s] id '%s' do config não existe na amostra; usando hash",
                        obj.nome_logico, obj.id)
            return None, "config_nao_encontrado"
        if not _coluna_unica(col, registros):
            log.warning("[%s] id '%s' não é único na amostra; usando hash",
                        obj.nome_logico, col)
            return None, "config_nao_unico"
        return col, "config"

    # 2) auto: candidatos por prioridade, sempre validando unicidade.
    leaf = obj.path.split("/")[-1]
    candidatos = [
        "id",
        f"id{leaf}", f"id{leaf.rstrip('s')}",
        f"id{obj.nome_logico}", f"id{obj.nome_logico.rstrip('s')}",
        f"{leaf}_id", f"{obj.nome_logico}_id",
        "codigointerno", "codigo_interno",
    ]
    for cand in candidatos:
        if cand in nomes and _coluna_unica(cand, registros):
            return cand, "auto"

    # 3) heurística: 1º campo "id*" numérico e único.
    for campo in campos:
        if campo["coluna"].startswith("id") and campo["tipo"] in ("inteiro", "numero"):
            if _coluna_unica(campo["coluna"], registros):
                return campo["coluna"], "auto_heuristica"

    return None, "sem_id_unico"


def _coluna_unica(coluna: str, registros: list[dict[str, Any]]) -> bool:
    """Verifica se a coluna tem valores não-nulos e todos distintos na amostra."""
    valores = []
    for reg in registros:
        mapeado = {nome_coluna(k): v for k, v in reg.items()}
        v = mapeado.get(coluna)
        if v is not None and v != "":
            valores.append(str(v))
    return len(valores) > 0 and len(valores) == len(set(valores))


def descobrir_objeto(cliente: ClienteCVDW, obj: Objeto, registros_amostra: int) -> dict:
    """Descobre o schema de um objeto a partir de uma amostra."""
    registros, url = cliente.buscar_amostra(obj.path, registros_amostra)
    log.info("[%s] %s -> %d registros na amostra", obj.nome_logico, url, len(registros))

    campos = inferir_campos(registros, profundidade=1)
    id_col, id_origem = detectar_id(obj, campos, registros)
    if id_col:
        log.info("[%s] chave de negócio: %s (%s)", obj.nome_logico, id_col, id_origem)
    else:
        log.info("[%s] sem id único (%s) -> upsert por hash da linha",
                 obj.nome_logico, id_origem)

    return {
        "path": obj.path,
        "url": url,
        "id_detectado": id_col,
        "id_origem": id_origem,
        "qtd_amostra": len(registros),
        "campos": campos,
    }


def descobrir(objetos: list[Objeto], registros_amostra: int) -> tuple[dict, list[str]]:
    """Executa a descoberta de todos os objetos. """
    cfg_api = carregar_config_api()
    cliente = ClienteCVDW(cfg_api)

    resultado: dict[str, Any] = {
        "gerado_em": datetime.now(timezone.utc).isoformat(),
        "subdominio": cfg_api.subdominio,
        "objetos": {},
    }
    falhas: list[str] = []

    for obj in objetos:
        try:
            resultado["objetos"][obj.nome_logico] = descobrir_objeto(
                cliente, obj, registros_amostra
            )
        except ErroAPI as exc:
            log.error("[%s] falhou: %s", obj.nome_logico, exc)
            falhas.append(f"{obj.nome_logico}: {exc}")
        except Exception as exc:  
            log.exception("[%s] erro inesperado", obj.nome_logico)
            falhas.append(f"{obj.nome_logico}: {exc}")

    return resultado, falhas


def gerar_relatorio(schema: dict) -> str:
    """Monta o relatório markdown a partir do schema descoberto."""
    linhas: list[str] = [
        "# Relatório de descoberta — CVDW",
        "",
        f"Gerado em: `{schema['gerado_em']}`  ",
        f"Subdomínio: `{schema['subdominio']}`",
        "",
        f"Total de objetos: **{len(schema['objetos'])}**",
        "",
    ]
    for nome, info in schema["objetos"].items():
        linhas.append(f"## `{nome}`")
        linhas.append("")
        linhas.append(f"- Endpoint: `{info['path']}`")
        chave = info["id_detectado"] or "_hash_linha (sem id único)"
        linhas.append(f"- Chave de upsert: **{chave}** ({info['id_origem']})")
        linhas.append(f"- Registros na amostra: {info['qtd_amostra']}")
        linhas.append("")
        if not info["campos"]:
            linhas.append("> Sem registros na amostra — schema não inferido.")
            linhas.append("")
            continue
        linhas.append("| coluna | tipo | tipo_sql | nullable | exemplo |")
        linhas.append("|---|---|---|---|---|")
        for campo in info["campos"]:
            linhas.append(
                f"| `{campo['coluna']}` | {campo['tipo']} | {campo['tipo_sql']} | "
                f"{'sim' if campo['nullable'] else 'não'} | "
                f"{_md_celula(campo.get('exemplo'))} |"
            )
            for sub in campo.get("subcampos", []):
                linhas.append(
                    f"| &nbsp;&nbsp;↳ `{campo['coluna']}.{sub['coluna']}` | "
                    f"{sub['tipo']} | {sub['tipo_sql']} | "
                    f"{'sim' if sub['nullable'] else 'não'} | "
                    f"{_md_celula(sub.get('exemplo'))} |"
                )
        linhas.append("")
    return "\n".join(linhas)


def _md_celula(valor: str | None) -> str:
    """Escapa o conteúdo de uma célula de tabela markdown."""
    if valor is None:
        return ""
    return valor.replace("|", "\\|").replace("\n", " ")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Descoberta de schema da API CVDW.")
    parser.add_argument("--registros", type=int, default=10,
                        help="Registros por objeto na amostra (padrão: 10).")
    parser.add_argument("--objetos", type=str, default=None,
                        help="Lista separada por vírgula para limitar a descoberta.")
    parser.add_argument("--verbose", action="store_true", help="Logs em DEBUG.")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    configurar_logging(args.verbose)

    objetos = carregar_objetos()
    if args.objetos:
        alvo = {n.strip() for n in args.objetos.split(",")}
        objetos = [o for o in objetos if o.nome_logico in alvo]

    log.info("Iniciando descoberta de %d objeto(s)", len(objetos))
    schema, falhas = descobrir(objetos, args.registros)

    DIR_SCHEMA.mkdir(parents=True, exist_ok=True)
    with open(ARQ_JSON, "w", encoding="utf-8") as arquivo:
        json.dump(schema, arquivo, ensure_ascii=False, indent=2)
    with open(ARQ_REPORT, "w", encoding="utf-8") as arquivo:
        arquivo.write(gerar_relatorio(schema))

    log.info("Schema salvo em %s", ARQ_JSON)
    log.info("Relatório salvo em %s", ARQ_REPORT)

    _resumo(schema, falhas)
    return 1 if falhas else 0


def _resumo(schema: dict, falhas: list[str]) -> None:
    """Imprime o resumo final (objetos OK e falhas)."""
    ok = len(schema["objetos"])
    log.info("=" * 60)
    log.info("RESUMO DA DESCOBERTA: %d objeto(s) descrito(s), %d falha(s)",
             ok, len(falhas))
    for falha in falhas:
        log.error("  - FALHOU %s", falha)


if __name__ == "__main__":
    raise SystemExit(main())
