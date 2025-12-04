# MariaDB chiffré + backups GPG + Docker secrets (version durcie)

Ce projet fournit une stack Docker pour :

- MariaDB avec **chiffrement du tablespace InnoDB** (file_key_management)
- Sauvegardes automatiques via un conteneur `mariadb-backup`
- Dumps **compressés (gzip) et chiffrés avec GPG (clé publique du DPO)**
- Mots de passe et clés gérés via **Docker secrets**
- **Monitoring** de la fraîcheur des backups + **notifications** (webhook / mail)
- Architecture durcie : réseau isolé, healthchecks, rotation, checksums, resource limits

> ⚠️ Les fichiers du répertoire `secrets/` sont des *placeholders* à adapter et ne doivent **jamais** être commités en production.

---

## 1. Arborescence

```text
.
├─ docker-compose.yml        # Définition des services Docker (réseau, healthchecks, secrets)
├─ Makefile                  # Automatisation build/deploy/backup/monitor/restore
├─ README.md                 # Ce document
├─ mariadb/
│  └─ my.cnf                 # Configuration MariaDB + TDE (file_key_management)
├─ backup/
│  ├─ Dockerfile             # Image du conteneur de backup (cron + msmtp + curl)
│  ├─ backup.sh              # Script de backup quotidien (gzip + gpg + checksum + notifications)
│  └─ check_backup.sh        # Script de monitoring (âge du dernier backup)
├─ secrets/                  # (à remplir) secrets Docker
│  ├─ mariadb_root_password.txt
│  ├─ mariadb_app_password.txt
│  ├─ mariadb_backup_password.txt
│  ├─ mariadb_file_keys.txt
│  ├─ dpo_pubkey.asc
│  ├─ backup_webhook_url.txt
│  └─ backup_smtp_password.txt
├─ backups/                  # Dumps compressés + chiffrés .sql.gz.gpg (montés depuis le conteneur backup)
└─ logs/                     # Logs du conteneur de backup (montés)
```

---

## 2. Préparation des secrets

Dans `secrets/` :

```bash
echo "SuperRootPwd"   > secrets/mariadb_root_password.txt
echo "AppPwd123!"     > secrets/mariadb_app_password.txt
echo "BackupPwd123!"  > secrets/mariadb_backup_password.txt

# Clés InnoDB (exemple, à générer proprement)
# Utiliser de vraies clés aléatoires :
openssl rand -hex 32
openssl rand -hex 32

cat > secrets/mariadb_file_keys.txt <<'EOF'
1;AES;0123456789ABCDEF0123456789ABCDEF
2;AES;FEDCBA9876543210FEDCBA9876543210
EOF

# Clé publique GPG du DPO (sur le poste DPO) :
gpg --armor --export dpo@exemple.local > secrets/dpo_pubkey.asc

# URL de webhook (optionnel)
echo "https://mon.webhook.local/backup" > secrets/backup_webhook_url.txt

# Mot de passe SMTP (optionnel)
echo "MonSuperMotDePasseSMTP" > secrets/backup_smtp_password.txt
```

> 💡 Remplace les valeurs d'exemple par des secrets **réels** et ne versionne jamais ce répertoire.

---

## 3. Réseau, ports et sécurité

- Les services sont connectés sur un réseau Docker dédié `dbnet`.
- MariaDB expose le port `3306:3306` :
  - si tu n’as pas besoin d’accès extérieur (autre que Docker), tu peux supprimer le bloc `ports:` de `mariadb` dans `stack.yml`.
- Les secrets (`mariadb_*_password`, `mariadb_file_keys`, `dpo_pubkey`, etc.) sont montés dans `/run/secrets/`.

Le chiffrement InnoDB s’appuie sur `mariadb_file_keys.txt` monté comme secret :

```ini
file_key_management_filename = /run/secrets/mariadb_file_keys
file_key_management_encryption_algorithm = AES_CTR
```

---

## 4. Commandes Makefile

Le `Makefile` suppose `docker compose` (v2).  
Si tu utilises `docker-compose`, adapte la variable `COMPOSE` dans le Makefile.

### 4.1 Build des images

```bash
make build
```

### 4.2 Démarrage de la stack

```bash
make up
```

### 4.3 Arrêt / suppression des conteneurs

```bash
make down
```

### 4.4 Lancer un backup manuel

```bash
make backup
```

Résultat : un fichier du type:

```text
backups/mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg
backups/mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg.sha256
```

### 4.5 Vérifier la fraîcheur du dernier backup

```bash
make monitor
```

### 4.6 Voir les logs

```bash
make logs
```

---

## 5. Création de l’utilisateur SQL de backup

Une fois `make up` lancé et le conteneur MariaDB démarré :

```bash
docker compose -f stack.yml exec -it mariadb_encrypted mariadb -u root -p
```

Puis, dans MariaDB :

```sql
CREATE USER 'backup_ro'@'%' IDENTIFIED BY 'BackupPwd123!';

GRANT SELECT, SHOW VIEW, RELOAD, LOCK TABLES, REPLICATION CLIENT
  ON *.* TO 'backup_ro'@'%';

FLUSH PRIVILEGES;
```

> Tu peux aussi automatiser ça avec un script d’init SQL monté dans `docker-entrypoint-initdb.d`.

---

## 6. Fonctionnement du backup (durci)

Le conteneur `mariadb-backup` :

- lit le mot de passe de `backup_ro` depuis `/run/secrets/mariadb_backup_password`
- importe la clé publique du DPO depuis `/run/secrets/dpo_pubkey`
- exécute quotidiennement (via `cron`) le script `backup.sh`

Le script `backup.sh` fait :

1. création d’un fichier temporaire `/tmp/backup-my.cnf.XXXXXX` utilisé par `mysqldump` via `--defaults-extra-file=...`
2. exécution de :

   ```bash
   mysqldump --defaults-extra-file=...      --single-transaction --routines --triggers      ${MARIADB_DATABASES}      | gzip      | gpg --encrypt --recipient "${GPG_RECIPIENT}"      > backups/mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg
   ```

3. suppression du fichier de config temporaire
4. calcul d’un `sha256sum` (`.sha256`) pour vérification d'intégrité
5. rotation (suppression des backups `.sql.gz.gpg` et `.sha256` de plus de 30 jours)
6. logging structuré + notifications (webhook / mail)

Grâce à `set -euo pipefail` + un `trap ERR`, en cas d’erreur MySQL/GPG/IO, le script :

- s’arrête proprement
- logue l’erreur
- envoie les notifications configurées.

---

## 7. Monitoring des backups

`check_backup.sh` :

- vérifie le **dernier fichier** `mariadb_*.sql.gz.gpg` dans `BACKUP_DIR`
- calcule son **âge** (en secondes) et le compare à `BACKUP_MAX_AGE_HOURS`
- codes de retour :
  - `0` : OK (backup récent)
  - `1` : CRITIQUE (backup trop ancien)
  - `2` : aucun backup trouvé

Utilisation :

```bash
make monitor
```

Ce script est aussi utilisé comme **healthcheck** du service `mariadb-backup`.  
Tu peux le brancher sur une sonde de supervision (Zabbix, Centreon, Prometheus, etc.) via `docker exec` ou autre.

---

## 8. Notifications (mail / webhook en cas d'échec)

Le script `backup.sh` envoie des notifications **en cas d'échec** et logue les succès.

### 8.1 Webhook

- `BACKUP_WEBHOOK_URL_FILE` pointe vers un secret Docker contenant l'URL (par défaut `/run/secrets/backup_webhook_url`).
- JSON envoyé :

```json
{
  "status": "success" | "error",
  "message": "Texte de statut",
  "timestamp": "2025-12-04T08:30:00+01:00"
}
```

### 8.2 Mail (SMTP)

Le script utilise `msmtp`.

Variables d'environnement (dans `stack.yml`, service `mariadb-backup`) :

- `BACKUP_ALERT_EMAIL` : destinataire des alertes
- `BACKUP_SMTP_HOST`, `BACKUP_SMTP_PORT`
- `BACKUP_SMTP_USER`
- `BACKUP_SMTP_PASSWORD_FILE` : fichier secret (par défaut `/run/secrets/backup_smtp_password`)
- `BACKUP_SMTP_FROM` : adresse expéditrice

À la moindre erreur, tu reçois :

- un log en `[ERROR]`
- un webhook (si configuré)
- un mail avec sujet : `[ALERTE][Backup MariaDB] Echec du backup`

---

## 9. Resource limits & healthchecks

Dans `stack.yml` :

- Les services `mariadb` et `mariadb-backup` ont des limites et réservations CPU/mémoire (section `deploy.resources`).
- `mariadb` a un healthcheck `mysqladmin ping`.
- `mariadb-backup` a un healthcheck basé sur `check_backup.sh` (âge du dernier backup).

> Selon ton orchestrateur (compose vs Swarm), `deploy.resources` et `depends_on.condition: service_healthy` seront plus ou moins utilisés, mais la config reste cohérente.

---

## 10. Procédure de restauration (résumé côté DPO)

1. Récupérer un fichier `mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg` depuis `backups/`.
2. Sur un poste/VM DPO, déchiffrer et décompresser :

   ```bash
   gpg --decrypt mariadb_2025-12-04_020000.sql.gz.gpg | gunzip > restore.sql
   ```

3. Copier `restore.sql` sur la machine qui héberge MariaDB :

   ```bash
   scp restore.sql admin@serveur-mariadb:/tmp/restore.sql
   ```

4. Restaurer dans le conteneur MariaDB :

   ```bash
   docker compose -f stack.yml exec -T mariadb_encrypted mariadb -u root -p < /tmp/restore.sql
   ```

5. Supprimer les fichiers SQL en clair (`restore.sql`, `/tmp/restore.sql`).

---

## 11. Améliorations possibles

- Script d’init SQL pour `backup_ro` (monté dans `docker-entrypoint-initdb.d`).
- Rétention avancée (daily/weekly/monthly).
- Intégration à un SIEM / logging centralisé (ELK, Loki, etc.).
- Chiffrement des colonnes sensibles côté application (clé hors de la DB).

Cette version intègre déjà la plupart des remarques de durcissement (ports cohérents, secrets, réseau isolé, compression avant chiffrement, meilleure gestion des erreurs, monitoring et notifications).
