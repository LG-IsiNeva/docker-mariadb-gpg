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


### 2.1 Variables d'environnement et .env

Définir les utilisateurs/clients dans le fichier `.env` :

```env
# Liste des utilisateurs/clients (séparés par des virgules, sans espaces)
CLIENT_NAMES=admin,app_user,backup_user,app_developer
```

### 2.2 Génération automatique des certificats mTLS

Utiliser le script suivant pour générer la CA, le certificat serveur et les certificats clients (un par nom dans `CLIENT_NAMES`) :

```bash
cd backup
./generate_certs.sh
```

Les certificats et clés sont générés dans le dossier `secrets/` :
- `ca.crt`, `ca.key` : autorité de certification
- `server.crt`, `server.key` : certificat serveur
- `<client>.crt`, `<client>.key` : certificats clients (un par utilisateur)

> Le CN du certificat client doit correspondre au nom d'utilisateur MariaDB.

### 2.3 Secrets MariaDB et GPG

```bash
# Mots de passe utilisateurs (un fichier par utilisateur)
echo "SuperRootPwd"   > secrets/mariadb_root_password.txt
echo "AppPwd123!"     > secrets/app_user_password.txt
echo "BackupPwd123!"  > secrets/backup_user_password.txt
echo "DevPwd123!"     > secrets/app_developer_password.txt

# Clés InnoDB (exemple, à générer proprement)
openssl rand -hex 32
openssl rand -hex 32
cat > secrets/mariadb_file_keys.txt <<'EOF'
1;0123456789ABCDEF0123456789ABCDEF
2;FEDCBA9876543210FEDCBA9876543210
EOF

# Clé publique GPG du DPO (sur le poste DPO)
gpg --armor --export dpo@exemple.local > secrets/dpo_pubkey.asc

# URL de webhook (optionnel)
echo "https://mon.webhook.local/backup" > secrets/backup_webhook_url.txt

# Mot de passe SMTP (optionnel)
echo "MonSuperMotDePasseSMTP" > secrets/backup_smtp_password.txt
```

> 💡 Remplace les valeurs d'exemple par des secrets **réels** et ne versionne jamais ce répertoire.

---

## 3. Authentification Mutuelle TLS (mTLS)

MariaDB peut être configuré pour exiger une authentification mutuelle TLS 1.3 :

- Le serveur utilise `server.crt` et `server.key` (générés dans `secrets/`).
- Les clients doivent présenter leur certificat (`<client>.crt`/`<client>.key`), signé par la CA (`ca.crt`).
- Le CN du certificat client doit correspondre au nom d'utilisateur MariaDB.

Configurer MariaDB dans `my.cnf` :

```ini
[mysqld]
ssl-ca=/run/secrets/ca.crt
ssl-cert=/run/secrets/server.crt
ssl-key=/run/secrets/server.key
require_secure_transport=ON
tls_version=TLSv1.3
```

> Monter les fichiers secrets dans `/run/secrets/` via Docker Compose/Swarm.

Pour chaque client, fournir le couple `<client>.crt`/`<client>.key` et la CA (`ca.crt`).

### Exemple de connexion depuis WinDev (mTLS)

Pour se connecter à MariaDB avec mTLS depuis WinDev :

1. Placez les fichiers suivants sur le poste client WinDev :
  - ca.crt (autorité de certification)
  - <client>.crt (certificat client)
  - <client>.key (clé privée du client)

2. Dans le code WinDev (WLanguage) :

```wlanguage
MaConnexion est une Connexion
MaConnexion..Provider = "MySQL"
MaConnexion..Serveur = "adresse_du_serveur"
MaConnexion..Port = 3307
MaConnexion..Utilisateur = "<client>"
MaConnexion..MotDePasse = "(mot de passe du client)"
MaConnexion..BaseDeDonnees = "appdb"
// Chemins absolus ou relatifs selon l'environnement WinDev
MaConnexion..Option["SSL_CA"] = "C:\\chemin\\vers\\ca.crt"
MaConnexion..Option["SSL_CERT"] = "C:\\chemin\\vers\\<client>.crt"
MaConnexion..Option["SSL_KEY"] = "C:\\chemin\\vers\\<client>.key"
MaConnexion..Option["SSL_MODE"] = "REQUIRED"

SI HConnecte(MaConnexion) ALORS
  Info("Connexion sécurisée établie !")
SINON
  Erreur("Echec de connexion : " + HErreurInfo())
FIN
```

> Adapter les chemins et le nom d'utilisateur selon votre configuration.

### Exemple de connexion client mTLS

Pour se connecter à MariaDB avec mTLS :

```bash
mariadb \
  --host=localhost \
  --port=3307 \
  --ssl-ca=secrets/ca.crt \
  --ssl-cert=secrets/<client>.crt \
  --ssl-key=secrets/<client>.key \
  --user=<client> \
  --password=$(cat secrets/<client>_password.txt)
```

Remplacez `<client>` par le nom d'utilisateur souhaité (doit correspondre au CN du certificat client).

> Le port doit correspondre à celui exposé dans stack.yml (ici 3307).

---

## 3. Réseau, ports et sécurité

- Les services sont connectés sur un réseau Docker dédié `dbnet`.
- MariaDB expose le port `3307:3306` :
  - si tu n'as pas besoin d'accès extérieur (autre que Docker), tu peux supprimer le bloc `ports:` de `mariadb` dans `stack.yml`.
- Les secrets (`mariadb_*_password`, `mariadb_file_keys`, `dpo_pubkey`, etc.) sont montés dans `/run/secrets/`.

Le chiffrement InnoDB s'appuie sur `mariadb_file_keys.txt` monté comme secret :

```ini
file_key_management_filename = /run/secrets/mariadb_file_keys
file_key_management_encryption_algorithm = AES_CTR
```

---


## 4. Sauvegarde et restauration : procédures

Des procédures détaillées sont disponibles pour la sauvegarde et la restauration :

- [Procédure de sauvegarde](procedure_sauvegarde.md) :
  - Lancer une sauvegarde manuelle
  - Sauvegarde automatique (cron)
  - Vérification de la fraîcheur
  - Logs, supervision, sécurité

- [Procédure de restauration](procedure_restoration.md) :
  - Récupération et vérification d’un backup
  - Déchiffrement, transfert, restauration
  - Vérifications post-restauration
  - Sécurité et suppression des fichiers en clair

Résumé rapide :

- Sauvegarde manuelle :
  ```bash
  docker compose exec mariadb_backup /usr/local/bin/backup.sh
  ```
- Vérification du dernier backup :
  ```bash
  docker compose exec mariadb_backup /usr/local/bin/check_backup.sh
  ```
- Restauration :
  ```bash
  gpg --decrypt mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg | gunzip > restore.sql
  scp restore.sql admin@serveur-mariadb:/tmp/restore.sql
  docker compose exec -T mariadb_encrypted mariadb -u root -p < /tmp/restore.sql
  ```


---

## 5. Commandes Docker Compose

Toutes les opérations se font désormais avec le fichier `docker-compose.yml` et la commande `docker compose` :

- Build des images :
  ```bash
  docker compose build
  ```
- Démarrage de la stack :
  ```bash
  docker compose up -d
  ```
- Arrêt / suppression des conteneurs :
  ```bash
  docker compose down
  ```
- Logs :
  ```bash
  docker compose logs -f
  ```
- Sauvegarde manuelle :
  ```bash
  docker compose exec mariadb_backup /usr/local/bin/backup.sh
  ```
- Vérification du dernier backup :
  ```bash
  docker compose exec mariadb_backup /usr/local/bin/check_backup.sh
  ```
- Restauration :
  ```bash
  docker compose exec -T mariadb_encrypted mariadb -u root -p < restore.sql
  ```

> Les fichiers Makefile et stack.yml ne sont plus utilisés.

---

## 5. Création de l'utilisateur SQL de backup

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

> Tu peux aussi automatiser ça avec un script d'init SQL monté dans `docker-entrypoint-initdb.d`.

---

## 6. Fonctionnement du backup (durci)

Le conteneur `mariadb-backup` :

- lit le mot de passe de `backup_ro` depuis `/run/secrets/mariadb_backup_password`
- importe la clé publique du DPO depuis `/run/secrets/dpo_pubkey`
- exécute quotidiennement (via `cron`) le script `backup.sh`

Le script `backup.sh` fait :

1. création d'un fichier temporaire `/tmp/backup-my.cnf.XXXXXX` utilisé par `mysqldump` via `--defaults-extra-file=...`
2. exécution de :

   ```bash
   mysqldump --defaults-extra-file=...      --single-transaction --routines --triggers      ${MARIADB_DATABASES}      | gzip      | gpg --encrypt --recipient "${GPG_RECIPIENT}"      > backups/mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg
   ```

3. suppression du fichier de config temporaire
4. calcul d'un `sha256sum` (`.sha256`) pour vérification d'intégrité
5. rotation (suppression des backups `.sql.gz.gpg` et `.sha256` de plus de 30 jours)
6. logging structuré + notifications (webhook / mail)

Grâce à `set -euo pipefail` + un `trap ERR`, en cas d'erreur MySQL/GPG/IO, le script :

- s'arrête proprement
- logue l'erreur
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

- Script d'init SQL pour `backup_ro` (monté dans `docker-entrypoint-initdb.d`).
- Rétention avancée (daily/weekly/monthly).
- Intégration à un SIEM / logging centralisé (ELK, Loki, etc.).
- Chiffrement des colonnes sensibles côté application (clé hors de la DB).

Cette version intègre déjà la plupart des remarques de durcissement (ports cohérents, secrets, réseau isolé, compression avant chiffrement, meilleure gestion des erreurs, monitoring et notifications).
