# 🗄️ Procédure de restauration MariaDB (DPO)

Cette procédure doit être exécutée **uniquement par la DPO** ou une personne habilitée, car elle nécessite l’accès :

* à la **clé privée GPG** du DPO
* à la **passphrase** associée
* aux serveurs où restaurer les données

Les dumps sont chiffrés, compressés et signés via ce pipeline :

```
mysqldump → gzip → GPG encryption → mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg
```

---

# 1. 📥 Récupérer le fichier de backup chiffré

Les dumps se trouvent dans le dossier :

```
backups/
```

Ou sur le serveur de backup centralisé.

Exemple de récupération depuis un serveur distant :

```bash
scp admin@serveur-backup:/data/backups/mariadb_2025-12-04_020000.sql.gz.gpg .
scp admin@serveur-backup:/data/backups/mariadb_2025-12-04_020000.sql.gz.gpg.sha256 .
```

---

# 2. 🔒 Vérifier l’intégrité du fichier (optionnel mais recommandé)

Si un fichier `.sha256` est présent :

```bash
sha256sum -c mariadb_2025-12-04_020000.sql.gz.gpg.sha256
```

Résultat attendu :

```
mariadb_2025-12-04_020000.sql.gz.gpg: OK
```

---

# 3. 🔓 Déchiffrer et décompresser le dump

Sur la machine DPO (où se trouve la clé privée) :

```bash
gpg --decrypt mariadb_2025-12-04_020000.sql.gz.gpg | gunzip > restore.sql
```

* GPG demande la **passphrase** de la clé privée du DPO.
* Le fichier en clair `restore.sql` est créé.

> ⚠️ **Attention : `restore.sql` est en clair — le manipuler avec précaution.**

---

# 4. 📤 Transférer le dump déchiffré vers le serveur MariaDB cible

Exemple :

```bash
scp restore.sql admin@serveur-mariadb:/tmp/restore.sql
```

---

# 5. 🗃️ Restauration dans MariaDB

### 5.1 Connexion au serveur MariaDB

Si MariaDB tourne en Docker :

```bash
ssh admin@serveur-mariadb
cd /chemin/du/projet
```

### 5.2 Exécuter la restauration

Dans le cas d’un conteneur nommé `mariadb_encrypted` :

```bash
docker compose exec -T mariadb_encrypted mariadb -u root -p < /tmp/restore.sql
```

Le mot de passe root est celui stocké dans `secrets/mariadb_root_password.txt`.

---

# 6. 🔍 Vérifications post-restauration

### Vérifier l’existence de la base :

```bash
docker compose exec -T mariadb_encrypted mariadb -u root -p -e "SHOW DATABASES;"
```

### Repérer quelques tables importantes :

```bash
docker compose exec -T mariadb_encrypted mariadb -u root -p -e "SELECT COUNT(*) FROM appdb.utilisateurs;"
```

### Vérifier les routines :

```bash
docker compose exec -T mariadb_encrypted mariadb -u root -p -e "SHOW PROCEDURE STATUS;"
```

---

# 7. 🧹 Suppression des fichiers en clair

Une fois la restauration validée :

### Sur le serveur MariaDB :

```bash
sudo shred -u /tmp/restore.sql
```

### Sur la machine DPO :

```bash
shred -u restore.sql
```

> **Ne jamais conserver le dump en clair** sur un disque non chiffré.

---

# 8. 🛡️ Points de sécurité importants

* Conserver la **clé privée GPG** dans un emplacement sécurisé (YubiKey, HSM, coffre chiffré).
* Le dump chiffré `.gpg` peut être conservé ; le fichier **décompressé** doit être supprimé.
* Toujours vérifier l’intégrité (`sha256`) avant restauration.
* Ne jamais transmettre un dump SQL en clair par email ou messagerie.

---

# 9. 🧪 Restauration partielle (optionnel)

Pour extraire et restaurer uniquement une table :

### 9.1 Trouver la section :

```bash
grep -n "CREATE TABLE \`clients\`" restore.sql
```

### 9.2 Extraire un bloc :

```bash
sed -n '2300,2900p' restore.sql > clients_only.sql
```

### 9.3 Restaurer :

```bash
docker compose exec -T mariadb_encrypted mariadb -u root -p appdb < clients_only.sql
```

---

# ✔️ Fin de procédure

Cette procédure garantit :

* confidentialité (clé privée uniquement côté DPO)
* intégrité (checksum + déchiffrement propre)
* traçabilité (opérations explicites)
* sécurité forte des données sensibles

