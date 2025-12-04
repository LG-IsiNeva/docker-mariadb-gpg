\
#!/bin/bash
set -euo pipefail

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "${ts} [monitor] [${level}] ${msg}"
}

: "${BACKUP_DIR:?BACKUP_DIR non défini}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-30}"

pattern="${BACKUP_DIR}/mariadb_*.sql.gz.gpg"

latest_file="$(ls -1t ${pattern} 2>/dev/null | head -n1 || true)"

if [ -z "${latest_file}" ]; then
  log "ERROR" "Aucun fichier de backup trouvé dans ${BACKUP_DIR}"
  exit 2
fi

now_ts="$(date +%s)"
file_ts="$(stat -c %Y "${latest_file}")"

age_sec=$(( now_ts - file_ts ))
max_age_sec=$(( BACKUP_MAX_AGE_HOURS * 3600 ))

log "INFO" "Dernier backup: ${latest_file}"
log "INFO" "Age (secondes): ${age_sec} (max: ${max_age_sec})"

if [ "${age_sec}" -gt "${max_age_sec}" ]; then
  log "ERROR" "Dernier backup trop ancien (> ${BACKUP_MAX_AGE_HOURS}h)"
  exit 1
fi

log "INFO" "OK: dernier backup récent"
exit 0
