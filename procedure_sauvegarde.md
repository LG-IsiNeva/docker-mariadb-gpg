
# 💾 Procédure de sauvegarde MariaDB

Cette procédure décrit comment lancer, vérifier et superviser les sauvegardes de la base MariaDB avec chiffrement GPG et gestion des secrets, en utilisant uniquement `docker compose` et le fichier `docker-compose.yml`.

---

mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg
mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg.sha256

## 1. Sauvegarde manuelle immédiate

Lancer une sauvegarde à la demande :

```bash
docker compose exec mariadb_backup /usr/local/bin/backup.sh
```

Le backup est généré dans le dossier `backups/` sous la forme :

```
mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg
mariadb_YYYY-MM-DD_HHMMSS.sql.gz.gpg.sha256
```

---


## 2. Sauvegarde automatique (cron)

Le conteneur `mariadb-backup` exécute automatiquement le script `backup.sh` chaque jour (via cron).

Aucune action manuelle n’est requise pour la sauvegarde quotidienne.

---


## 3. Vérification de la fraîcheur du dernier backup

Pour vérifier que la dernière sauvegarde est récente :

```bash
docker compose exec mariadb_backup /usr/local/bin/check_backup.sh
```

Code de retour :
- `0` : OK (backup récent)
- `1` : CRITIQUE (backup trop ancien)
- `2` : Aucun backup trouvé

---


## 4. Logs et supervision

Les logs du backup sont accessibles dans le dossier `logs/` ou via :

```bash
docker compose logs -f mariadb_backup
```

Le script de backup envoie des notifications (webhook/mail) en cas d’échec.

---


## 5. Points de sécurité

- Les mots de passe et clés sont lus depuis `/run/secrets/` (jamais en clair dans les scripts).
- Les dumps sont chiffrés avec la clé publique GPG du DPO.
- Les backups anciens sont automatiquement supprimés (rotation).
- Ne jamais transmettre un dump SQL en clair.

---


## 6. Restauration

Voir la procédure détaillée dans `procedure_restoration.md`.

> Les fichiers Makefile et stack.yml ne sont plus utilisés.
