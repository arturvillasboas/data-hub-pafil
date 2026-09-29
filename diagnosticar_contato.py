"""Mostra a trilha completa de fila_sync/log_sync de um contato, pra investigar duplicidade.

  python diagnosticar_contato.py --idlead 99666
  python diagnosticar_contato.py --telefone +5519978200204
"""
from __future__ import annotations

import argparse
import json

from config.settings import carregar_config_pg
from cvdw import db
from cvdw.log import configurar_logging, get_logger

log = get_logger("diagnosticar_contato")


def resolver_contato_id(conn, idlead: str | None, telefone: str | None) -> int | None:
    with conn.cursor() as cur:
        if idlead:
            cur.execute(
                "SELECT id FROM integracao.depara_contato WHERE idlead_cvcrm = %s", (idlead,)
            )
        else:
            cur.execute(
                "SELECT id FROM integracao.depara_contato WHERE telefone_chave = %s", (telefone,)
            )
        row = cur.fetchone()
        return row[0] if row else None


def main() -> int:
    ap = argparse.ArgumentParser(description="Trilha de fila_sync/log_sync de um contato.")
    ap.add_argument("--idlead", help="idlead_cvcrm")
    ap.add_argument("--telefone", help="telefone_chave (E.164, ex.: +5519978200204)")
    args = ap.parse_args()

    if not args.idlead and not args.telefone:
        ap.error("informe --idlead ou --telefone")

    configurar_logging(False)
    cfg = carregar_config_pg()

    with db.conectar(cfg) as conn:
        contato_id = resolver_contato_id(conn, args.idlead, args.telefone)
        if contato_id is None:
            log.error("Contato não encontrado em integracao.depara_contato.")
            return 1

        with conn.cursor() as cur:
            cur.execute(
                "SELECT idlead_cvcrm, id_contato_ghl, telefone_chave FROM integracao.depara_contato WHERE id = %s",
                (contato_id,),
            )
            idlead_cvcrm, id_contato_ghl, telefone = cur.fetchone()
        print(f"\ncontato_id={contato_id}  idlead_cvcrm={idlead_cvcrm}  id_contato_ghl={id_contato_ghl}  telefone={telefone}\n")

        print("=" * 100)
        print("FILA_SYNC (o que chegou de cada plataforma)")
        print("=" * 100)
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, origem, tipo_evento, campos, status, hash_evento, criado_em, erro_msg
                  FROM integracao.fila_sync
                 WHERE contato_id = %s
                 ORDER BY criado_em
                """,
                (contato_id,),
            )
            for fid, origem, tipo_evento, campos, status, hash_evento, criado_em, erro_msg in cur.fetchall():
                print(f"\n[fila_sync #{fid}] {criado_em}  origem={origem}  tipo_evento={tipo_evento}  status={status}")
                print(f"  campos: {json.dumps(campos, ensure_ascii=False)}")
                if erro_msg:
                    print(f"  erro: {erro_msg}")

        print("\n" + "=" * 100)
        print("LOG_SYNC (o que foi de fato escrito em cada plataforma)")
        print("=" * 100)
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, fila_sync_id, destino, campos_enviados, status, criado_em, detalhe
                  FROM integracao.log_sync
                 WHERE contato_id = %s
                 ORDER BY criado_em
                """,
                (contato_id,),
            )
            for lid, fila_sync_id, destino, campos_enviados, status, criado_em, detalhe in cur.fetchall():
                print(f"\n[log_sync #{lid}] {criado_em}  fila_sync_id={fila_sync_id}  destino={destino}  status={status}")
                print(f"  campos_enviados: {json.dumps(campos_enviados, ensure_ascii=False)}")
                if detalhe:
                    print(f"  detalhe: {detalhe}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
