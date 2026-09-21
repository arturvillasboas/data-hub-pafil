"""Exporta leads reais do CVCRM para um CSV de importação no GHL.

Decisão de negócio (21/set/2026, combinado com o SDR da Pafil): começar com
uma amostra pequena e controlada, não os ~59 mil leads do histórico inteiro.
Critério de qualificação usa a cascata já validada de canal/mídia em
gold.fato_leads (coluna "canal 2.0"), não o campo bruto bronze.leads.origem
-- é o mesmo de-para que já sustenta os relatórios de Power BI, não faz
sentido reconstruir a regra do zero a partir do dado cru. Só depois de
qualificado o lead (por canal/mídia) é que se busca o contato (nome,
telefone, email) direto em bronze.leads, porque a gold é livre de PII de
propósito.

Depois da importação no GHL, rodar a reconciliação do lado GHL (nó "Buscar
contatos GHL atualizados" no n8n) para casar os contatos recém-criados
contra integracao.depara_contato, antes de religar integracao.fila_sync via
o Gatilho reconciliacao.

Os nomes de coluna do CSV usam as mesmas chaves dos Custom Fields já criados
na sub-account do GHL (situacao_lead_cv, empreendimento_cv, midia_cv,
nome_corretor_cvcrm, idlead_cv), para que o GHL mapeie automaticamente na
tela de importação (ver ajuda.gohighlevel.com, "CSV File Format for
Importing Contacts").

  python exportar_leads_ghl.py --empreendimento "FIUSA 016" --dias 90 [--canal Lead] [--saida leads_ghl.csv]

Exclui por padrão situação Perdido e Venda Realizada (decisão de negócio,
21/set/2026): mesmo sendo campanha de ativação, não faz sentido reengajar
lead já fechado (ganho ou perdido). Ajustável via --excluir-situacao.
"""
from __future__ import annotations

import argparse
import csv

from config.settings import carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("exportar_leads_ghl")

SITUACOES_EXCLUIDAS_DEFAULT = ("Perdido", "Venda Realizada")

QUERY = """
    SELECT
        b.nome,
        integracao.normalizar_telefone(b.telefone) AS telefone,
        b.email,
        b.idlead::text                             AS idlead_cv,
        b.situacao                                 AS situacao_lead_cv,
        b.empreendimento_ultimo                    AS empreendimento_cv,
        b.corretor                                 AS nome_corretor_cvcrm,
        b.origem_nome                              AS midia_cv
    FROM bronze.leads b
    JOIN gold.fato_leads g ON g.id_lead = b.idlead
    WHERE g."canal 2.0" = %s
      AND g."Empreendimento" = %s
      AND g."Data da Última Interação" >= now() - (%s || ' days')::interval
      AND NOT (b.situacao = ANY(%s))
    ORDER BY b.idlead
"""

COLUNAS = [
    "nome", "telefone", "email", "idlead_cv",
    "situacao_lead_cv", "empreendimento_cv", "nome_corretor_cvcrm", "midia_cv",
]


def main() -> int:
    ap = argparse.ArgumentParser(description="Exporta uma amostra de leads qualificados do CVCRM para CSV de importação no GHL.")
    ap.add_argument("--empreendimento", required=True, help='nome exato em gold.fato_leads."Empreendimento" (ex.: "FIUSA 016")')
    ap.add_argument("--dias", type=int, default=90, help="janela de Data da Última Interação, em dias (default: 90)")
    ap.add_argument("--canal", default="Lead", help='valor de gold.fato_leads."canal 2.0" a incluir (default: "Lead")')
    ap.add_argument("--excluir-situacao", nargs="*", default=list(SITUACOES_EXCLUIDAS_DEFAULT),
                     help=f"situações a excluir (default: {' '.join(SITUACOES_EXCLUIDAS_DEFAULT)})")
    ap.add_argument("--saida", default="leads_ghl.csv", help="caminho do CSV de saída (default: leads_ghl.csv)")
    ap.add_argument("--verbose", action="store_true", help="log de debug")
    args = ap.parse_args()

    configurar_logging(args.verbose)
    cfg = carregar_config_pg()

    linhas = 0
    with db.conectar(cfg) as conn, conn.cursor() as cur:
        cur.execute(QUERY, (args.canal, args.empreendimento, str(args.dias), list(args.excluir_situacao)))
        with open(args.saida, "w", newline="", encoding="utf-8-sig") as f:
            writer = csv.writer(f)
            writer.writerow(COLUNAS)
            for row in cur:
                writer.writerow(["" if v is None else v for v in row])
                linhas += 1

    log.info(
        "Exportado %d leads para %s (canal 2.0=%s, empreendimento=%s, últimos %d dias por interação, excluindo situação: %s).",
        linhas, args.saida, args.canal, args.empreendimento, args.dias, ", ".join(args.excluir_situacao),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
