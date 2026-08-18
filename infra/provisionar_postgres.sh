#!/usr/bin/env bash
# provisionar_postgres.sh — instala e configura o PostgreSQL 16 na EC2 do Pafil DW.
#
# Etapa 7.2 do roadmap. Idempotente: pode rodar de novo sem quebrar nada.
# Cobre Ubuntu 22.04/24.04 (repo PGDG) e Amazon Linux 2023 (dnf) — detecta pelo
# /etc/os-release, porque o SO ainda é decisão da TI (ver PEDIDO_TI.md secao 4a).
#
# NÃO recebe senha por argumento nem por variável: gera as senhas na própria
# máquina com `openssl rand` e grava em /root/pafil_credenciais.txt (modo 0600).
# Assim nenhuma senha passa por histórico de shell, log de terminal ou repositório.
#
# Uso:
#   sudo bash provisionar_postgres.sh
#
# Depois de rodar, siga o README.md a partir da secao "3. Aplicar o schema".

set -Eeuo pipefail

PG_MAJOR=16
DB_NOME="pafil_dw"
ROLE_APP="pafil_app"          # dono do banco: ingestão + DDL das camadas
ROLE_BI="pafil_bi"            # somente leitura: Power BI / gateway
ARQ_CREDENCIAIS="/root/pafil_credenciais.txt"
DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
aviso() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Rode como root (sudo bash $0)"; exit 1; }

# --- 0. Detecta a distro ------------------------------------------------------
. /etc/os-release
case "${ID}" in
  ubuntu|debian) FAMILIA="debian" ;;
  amzn|rhel|centos|fedora) FAMILIA="rhel" ;;
  *) echo "Distro '${ID}' não coberta por este script. Ver README.md."; exit 1 ;;
esac
log "Distro detectada: ${PRETTY_NAME} (família ${FAMILIA})"

# --- 1. Timezone e patches automáticos ---------------------------------------
log "Ajustando timezone e atualizações automáticas de segurança"
timedatectl set-timezone America/Sao_Paulo

if [[ $FAMILIA == debian ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg unattended-upgrades tmux
  dpkg-reconfigure -f noninteractive unattended-upgrades
else
  dnf install -y -q curl ca-certificates dnf-automatic tmux
  # Só patches de segurança, aplicados automaticamente.
  sed -i 's/^upgrade_type.*/upgrade_type = security/' /etc/dnf/automatic.conf
  sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer
fi

# --- 2. Instala o PostgreSQL 16 ----------------------------------------------
# Major 16 fixada de propósito: é a mesma do ambiente de desenvolvimento local.
# Divergência de major entre dev e produção significa divergência de dialeto e
# de comportamento de função — o tipo de bug que só aparece em produção.
log "Instalando PostgreSQL ${PG_MAJOR}"

if [[ $FAMILIA == debian ]]; then
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt-get update -qq
  fi
  apt-get install -y -qq "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}"
  PGDATA="/var/lib/postgresql/${PG_MAJOR}/main"
  PGCONF_DIR="/etc/postgresql/${PG_MAJOR}/main"
  DROPIN_DIR="${PGCONF_DIR}/conf.d"
  SERVICO="postgresql@${PG_MAJOR}-main"
  PGBIN="/usr/lib/postgresql/${PG_MAJOR}/bin"
else
  dnf install -y -q "postgresql${PG_MAJOR}-server" "postgresql${PG_MAJOR}"
  PGDATA="/var/lib/pgsql/data"
  PGCONF_DIR="$PGDATA"
  DROPIN_DIR="${PGDATA}/conf.d"
  SERVICO="postgresql"
  PGBIN="/usr/bin"
  if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
    "${PGBIN}/postgresql-setup" --initdb
  fi
  # No RHEL/AL o postgresql.conf não tem include_dir por padrão.
  grep -q "^include_dir = 'conf.d'" "${PGCONF_DIR}/postgresql.conf" \
    || echo "include_dir = 'conf.d'" >> "${PGCONF_DIR}/postgresql.conf"
fi

# --- 3. Aplica a configuração do projeto -------------------------------------
log "Aplicando conf.d/postgresql-pafil.conf"
install -d -o postgres -g postgres -m 750 "$DROPIN_DIR"
install -o postgres -g postgres -m 640 \
  "${DIR_SCRIPT}/conf/postgresql-pafil.conf" "${DROPIN_DIR}/postgresql-pafil.conf"

# --- 4. pg_hba: só conexão local, sempre com senha (scram) -------------------
# Sem linha `host ... 0.0.0.0/0`: o acesso remoto é por túnel, que chega como
# 127.0.0.1. Quando o host do gateway do Power BI existir, adicionar UMA linha
# com o CIDR privado dele (ver README secao 6) — nunca um range aberto.
log "Escrevendo pg_hba.conf"
cat > "${PGCONF_DIR}/pg_hba.conf" <<'HBA'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# host  pafil_dw        pafil_bi        10.0.0.0/16             scram-sha-256   # gateway Power BI (7.5)
HBA
chown postgres:postgres "${PGCONF_DIR}/pg_hba.conf"
chmod 640 "${PGCONF_DIR}/pg_hba.conf"

systemctl enable "$SERVICO"
systemctl restart "$SERVICO"

# --- 5. Roles e database ------------------------------------------------------
# Senhas geradas aqui, na máquina. Só são exibidas no arquivo 0600 do root.
psql_root() { su - postgres -c "psql -v ON_ERROR_STOP=1 -tAc \"$1\""; }

existe_role() { [[ "$(psql_root "SELECT 1 FROM pg_roles WHERE rolname='$1'")" == "1" ]]; }
existe_db()   { [[ "$(psql_root "SELECT 1 FROM pg_database WHERE datname='$1'")" == "1" ]]; }

if [[ -f "$ARQ_CREDENCIAIS" ]]; then
  aviso "${ARQ_CREDENCIAIS} já existe — mantendo as senhas atuais (não regenero)."
else
  log "Gerando senhas e criando roles"
  SENHA_APP="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  SENHA_BI="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  umask 077
  cat > "$ARQ_CREDENCIAIS" <<CRED
# Credenciais do Pafil DW — geradas por provisionar_postgres.sh em $(date -Is)
# Copie para o .env da máquina do analista e para o EnvironmentFile da ingestão.
# NÃO versionar. NÃO colar em chat/e-mail.
${ROLE_APP}=${SENHA_APP}
${ROLE_BI}=${SENHA_BI}
CRED
  chmod 600 "$ARQ_CREDENCIAIS"

  existe_role "$ROLE_APP" \
    || psql_root "CREATE ROLE ${ROLE_APP} LOGIN PASSWORD '${SENHA_APP}'"
  existe_role "$ROLE_BI" \
    || psql_root "CREATE ROLE ${ROLE_BI} LOGIN PASSWORD '${SENHA_BI}'"
fi

existe_db "$DB_NOME" \
  || psql_root "CREATE DATABASE ${DB_NOME} OWNER ${ROLE_APP} ENCODING 'UTF8' TEMPLATE template0"

# pafil_bi não pode criar nada em lugar nenhum; leitura é concedida por
# grants_bi.sql, depois que as camadas existirem.
psql_root "REVOKE ALL ON DATABASE ${DB_NOME} FROM PUBLIC"
psql_root "GRANT CONNECT ON DATABASE ${DB_NOME} TO ${ROLE_APP}, ${ROLE_BI}"

# --- 6. Backup ----------------------------------------------------------------
log "Instalando o backup diário (pg_dump)"
install -o root -g root -m 750 "${DIR_SCRIPT}/backup_pg.sh" /usr/local/sbin/backup_pg.sh
install -d -o postgres -g postgres -m 700 /var/backups/pafil
cat > /etc/cron.d/pafil-backup <<'CRON'
# Backup lógico do Pafil DW — 02:30 (America/Sao_Paulo), antes da ingestão diária.
CRON_TZ=America/Sao_Paulo
30 2 * * * root /usr/local/sbin/backup_pg.sh >> /var/log/pafil-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/pafil-backup

# --- 7. Resumo ----------------------------------------------------------------
log "Pronto."
cat <<FIM

  Serviço ......... ${SERVICO} ($(systemctl is-active "$SERVICO"))
  Versão .......... $(su - postgres -c "psql -tAc 'SHOW server_version'")
  Database ........ ${DB_NOME}
  Roles ........... ${ROLE_APP} (dono) | ${ROLE_BI} (somente leitura)
  Config .......... ${DROPIN_DIR}/postgresql-pafil.conf
  pg_hba .......... ${PGCONF_DIR}/pg_hba.conf  (apenas localhost)
  Credenciais ..... ${ARQ_CREDENCIAIS}  (chmod 600, root)
  Backup .......... /etc/cron.d/pafil-backup -> /var/backups/pafil

  Próximo passo: README.md, secao "3. Aplicar o schema e rodar a carga full".

FIM
