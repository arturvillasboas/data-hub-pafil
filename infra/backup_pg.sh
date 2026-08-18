#!/usr/bin/env bash
# backup_pg.sh — dump lógico diário do Pafil DW, com retenção e envio opcional p/ S3.
#
# Instalado em /usr/local/sbin/ por provisionar_postgres.sh e chamado pelo
# /etc/cron.d/pafil-backup às 02:30 (antes da ingestão diária das 03:00).
#
# Por que dump lógico se o EBS já tem snapshot: o snapshot protege contra perda
# da máquina; o dump protege contra erro humano/lógico (um DROP, um seed
# corrompido) e permite restaurar UMA tabela sem restaurar o volume inteiro.
#
# Ponto importante de retenção: a bronze é reconstruível a partir da API com
# `ingestao.py --full`, mas os SEEDS DE-PARA NÃO SÃO — vêm de planilhas mantidas
# à mão pelo backoffice. Se este backup falhar, é isso que se perde.
#
# Uso manual: sudo /usr/local/sbin/backup_pg.sh

set -Eeuo pipefail

DB_NOME="${PAFIL_DB:-pafil_dw}"
DIR_BACKUP="${PAFIL_DIR_BACKUP:-/var/backups/pafil}"
RETENCAO_DIAS="${PAFIL_RETENCAO_DIAS:-7}"
# Opcional: exportar PAFIL_BUCKET_S3=s3://bucket/prefixo para replicar fora da máquina.
BUCKET_S3="${PAFIL_BUCKET_S3:-}"

carimbo="$(date +%Y%m%d_%H%M%S)"
arquivo="${DIR_BACKUP}/${DB_NOME}_${carimbo}.dump"

mkdir -p "$DIR_BACKUP"

# -Fc = formato custom: comprimido e restaurável seletivamente com pg_restore -t.
su - postgres -c "pg_dump -Fc -d '${DB_NOME}' -f '${arquivo}'"
chmod 600 "$arquivo"

tamanho="$(du -h "$arquivo" | cut -f1)"
echo "$(date -Is) OK  ${arquivo} (${tamanho})"

# Réplica fora da instância — um backup que só existe no disco que ele protege
# não é backup.
if [[ -n "$BUCKET_S3" ]]; then
  if command -v aws >/dev/null 2>&1; then
    aws s3 cp "$arquivo" "${BUCKET_S3%/}/$(basename "$arquivo")" --only-show-errors
    echo "$(date -Is) OK  replicado para ${BUCKET_S3}"
  else
    echo "$(date -Is) ERRO PAFIL_BUCKET_S3 definido mas a AWS CLI não está instalada" >&2
  fi
fi

# Retenção local. O -mtime roda depois do dump do dia, então nunca fica sem cópia.
find "$DIR_BACKUP" -name "${DB_NOME}_*.dump" -type f -mtime "+${RETENCAO_DIAS}" -print -delete

# Falha ruidosa: se o dump mais recente tiver menos de 1 MB, algo está errado
# (banco vazio, permissão negada) e é melhor gritar do que acumular lixo.
if [[ "$(stat -c%s "$arquivo")" -lt 1048576 ]]; then
  echo "$(date -Is) ALERTA dump com menos de 1MB — verificar!" >&2
  exit 1
fi
