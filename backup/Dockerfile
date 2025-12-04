FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      mariadb-client \
      gnupg \
      cron \
      ca-certificates \
      curl \
      msmtp \
      coreutils \
    && rm -rf /var/lib/apt/lists/*

RUN id -u backup &>/dev/null || useradd --system --home /home/backup --shell /usr/sbin/nologin backup \
    && mkdir -p /home/backup \
    && mkdir -p /home/backup/logs \
    && chown -R backup:backup /home/backup

COPY backup.sh /usr/local/bin/backup.sh
COPY check_backup.sh /usr/local/bin/check_backup.sh

RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/check_backup.sh \
    && chown backup:backup /usr/local/bin/backup.sh /usr/local/bin/check_backup.sh

RUN mkdir -p /home/backup/.gnupg && chmod 700 /home/backup/.gnupg && chown -R backup:backup /home/backup/.gnupg

# Cron: backup tous les jours à 2h (exécuté en tant qu'utilisateur backup)
RUN echo "0 2 * * * backup /usr/local/bin/backup.sh >> /home/backup/logs/backup.log 2>&1" > /etc/cron.d/backup-cron \
    && chmod 0644 /etc/cron.d/backup-cron \
    && crontab /etc/cron.d/backup-cron

VOLUME ["/backups", "/home/backup/logs"]

CMD ["cron", "-f"]
