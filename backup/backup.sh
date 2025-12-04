\
#!/bin/bash
set -euo pipefail

########################################
# Logging utilitaire
########################################
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "${ts} [backup] [${level}] ${msg}"
}

########################################
# Configuration via variables d'environnement
########################################

: "${MARIADB_HOST:?MARIADB_HOST non défini}"
: "${MARIADB_PORT:?MARIADB_PORT non défini}"
: "${MARIADB_USER:?MARIADB_USER non défini}"
: "${MARIADB_PASSWORD_FILE:?MARIADB_PASSWORD_FILE non défini}"
: "${MARIADB_DATABASES:?MARIADB_DATABASES non défini}"
: "${GPG_RECIPIENT:?GPG_RECIPIENT non défini}"
: "${BACKUP_DIR:?BACKUP_DIR non défini}"

# Secrets
if [ ! -f "${MARIADB_PASSWORD_FILE}" ]; then
  log "ERROR" "Fichier de mot de passe MariaDB introuvable: ${MARIADB_PASSWORD_FILE}"
  exit 1
fi
MARIADB_PASSWORD="$(cat "${MARIADB_PASSWORD_FILE}")"

# Optionnel : URL de webhook via secret
BACKUP_WEBHOOK_URL_FILE_DEFAULT="/run/secrets/backup_webhook_url"
BACKUP_WEBHOOK_URL_FILE="${BACKUP_WEBHOOK_URL_FILE:-$BACKUP_WEBHOOK_URL_FILE_DEFAULT}"
BACKUP_WEBHOOK_URL=""
if [ -n "${BACKUP_WEBHOOK_URL_FILE:-}" ] && [ -f "${BACKUP_WEBHOOK_URL_FILE}" ]; then
  BACKUP_WEBHOOK_URL="$(cat "${BACKUP_WEBHOOK_URL_FILE}")"
fi

# Optionnel : envoi de mail via SMTP (msmtp)
BACKUP_ALERT_EMAIL="${BACKUP_ALERT_EMAIL:-}"
BACKUP_SMTP_HOST="${BACKUP_SMTP_HOST:-}"
BACKUP_SMTP_PORT="${BACKUP_SMTP_PORT:-587}"
BACKUP_SMTP_USER="${BACKUP_SMTP_USER:-}"
BACKUP_SMTP_PASSWORD_FILE_DEFAULT="/run/secrets/backup_smtp_password"
BACKUP_SMTP_PASSWORD_FILE="${BACKUP_SMTP_PASSWORD_FILE:-$BACKUP_SMTP_PASSWORD_FILE_DEFAULT}"
BACKUP_SMTP_FROM="${BACKUP_SMTP_FROM:-backup@mariadb.local}"

# Âge max d'un backup (monitoring) en heures (utilisé par check_backup.sh)
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-30}"

########################################
# Notifications
########################################

send_webhook() {
  local status="$1"
  local message="$2"
  local ts
  ts="$(date --iso-8601=seconds 2>/dev/null || date)"

  if [ -z "${BACKUP_WEBHOOK_URL:-}" ]; then
    return 0
  fi

  curl -sS -X POST "${BACKUP_WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"${status}\",\"message\":\"${message}\",\"timestamp\":\"${ts}\"}" \
    >/dev/null 2>&1 || true
}

send_mail() {
  local subject="$1"
  local body="$2"

  if [ -z "${BACKUP_ALERT_EMAIL}" ] || [ -z "${BACKUP_SMTP_HOST}" ]; then
    return 0
  fi

  local smtp_pass=""
  if [ -f "${BACKUP_SMTP_PASSWORD_FILE}" ]; then
    smtp_pass="$(cat "${BACKUP_SMTP_PASSWORD_FILE}")"
  fi

  mkdir -p "${HOME}/.config"
  cat > "${HOME}/.msmtprc" <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ${HOME}/msmtp.log

account        default
host           ${BACKUP_SMTP_HOST}
port           ${BACKUP_SMTP_PORT}
from           ${BACKUP_SMTP_FROM}
EOF
  if [ -n "${BACKUP_SMTP_USER}" ] && [ -n "${smtp_pass}" ]; then
    cat >> "${HOME}/.msmtprc" <<EOF
user           ${BACKUP_SMTP_USER}
password       ${smtp_pass}
EOF
  fi
  echo "account default" >> "${HOME}/.msmtprc"
  chmod 600 "${HOME}/.msmtprc"

  {
    echo "From: ${BACKUP_SMTP_FROM}"
    echo "To: ${BACKUP_ALERT_EMAIL}"
    echo "Subject: ${subject}"
    echo
    echo "${body}"
  } | msmtp -t >/dev/null 2>&1 || true
}

notify_status() {
  local status="$1"
  local msg="$2"

  log "$( [ "$status" = "success" ] && echo INFO || echo ERROR )" "$msg"
  send_webhook "$status" "$msg"

  if [ "$status" = "error" ]; then
    send_mail "[ALERTE][Backup MariaDB] Echec du backup" "$msg"
  fi
}

########################################
# Import de la clé publique GPG du DPO
########################################

if [ -f /run/secrets/dpo_pubkey ]; then
  gpg --batch --yes --import /run/secrets/dpo_pubkey || true
fi

if ! gpg --list-keys "${GPG_RECIPIENT}" >/dev/null 2>&1; then
  notify_status "error" "Clé GPG pour ${GPG_RECIPIENT} introuvable dans le keyring."
  exit 1
fi

########################################
# Gestion des erreurs globales
########################################

trap 'notify_status "error" "Echec du backup MariaDB (voir logs dans le conteneur mariadb-backup)."; exit 1' ERR

########################################
# Exécution du backup (mysqldump -> gzip -> gpg)
########################################

mkdir -p "${BACKUP_DIR}"

DATE="$(date +%F_%H%M%S)"
BASENAME="mariadb_${DATE}.sql.gz.gpg"
OUTFILE="${BACKUP_DIR}/${BASENAME}"

# Fichier temporaire de configuration MySQL client
TMP_CNF="$(mktemp /tmp/backup-my.cnf.XXXXXX)"
cat > "${TMP_CNF}" <<EOF
[client]
host=${MARIADB_HOST}
port=${MARIADB_PORT}
user=${MARIADB_USER}
password=${MARIADB_PASSWORD}
EOF
chmod 600 "${TMP_CNF}"

log "INFO" "Début du dump vers ${OUTFILE}"

# Grâce à set -euo pipefail, si mysqldump, gzip ou gpg échoue, le script s'arrête.
set -o pipefail
mysqldump --defaults-extra-file="${TMP_CNF}" \
  --single-transaction \
  --routines \
  --triggers \
  ${MARIADB_DATABASES} \
  | gzip \
  | gpg --batch --yes --encrypt --recipient "${GPG_RECIPIENT}" \
  > "${OUTFILE}"

rm -f "${TMP_CNF}"

# Vérification : fichier créé et non vide
if [ ! -s "${OUTFILE}" ]; then
  notify_status "error" "Fichier de backup vide ou inexistant: ${OUTFILE}"
  exit 1
fi

# Calcul d'un checksum pour vérification d'intégrité ultérieure
sha256sum "${OUTFILE}" > "${OUTFILE}.sha256" || true

# Rotation simple : supprimer les backups de plus de 30 jours
find "${BACKUP_DIR}" -type f -name "mariadb_*.sql.gz.gpg" -mtime +30 -delete || true
find "${BACKUP_DIR}" -type f -name "mariadb_*.sql.gz.gpg.sha256" -mtime +30 -delete || true

notify_status "success" "Backup MariaDB OK (${OUTFILE})"
