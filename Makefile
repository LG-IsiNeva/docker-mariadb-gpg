COMPOSE ?= docker compose
STACK_FILE ?= stack.yml

.PHONY: build up down logs backup restore monitor help

help:
	@echo "Cibles disponibles :"
	@echo "  make build    - Build de l'image de backup"
	@echo "  make up       - Démarre la stack (mariadb + backup)"
	@echo "  make down     - Arrête la stack"
	@echo "  make logs     - Affiche les logs des services"
	@echo "  make backup   - Lance un backup manuel immédiat"
	@echo "  make restore  - Restaure un dump SQL dans MariaDB (SQL_FILE=...)"
	@echo "  make monitor  - Vérifie l'âge du dernier backup (check_backup.sh)"

build:
	$(COMPOSE) -f $(STACK_FILE) build

up:
	$(COMPOSE) -f $(STACK_FILE) up -d

down:
	$(COMPOSE) -f $(STACK_FILE) down

logs:
	$(COMPOSE) -f $(STACK_FILE) logs -f

backup:
	$(COMPOSE) -f $(STACK_FILE) exec mariadb_backup /usr/local/bin/backup.sh

# Usage : make restore SQL_FILE=chemin/vers/restore.sql
restore:
	@if [ -z "$(SQL_FILE)" ]; then \
	  echo "Usage: make restore SQL_FILE=chemin/vers/restore.sql"; \
	  exit 1; \
	fi
	@echo "Restauration de $(SQL_FILE) dans MariaDB (mot de passe root requis) ..."
	$(COMPOSE) -f $(STACK_FILE) exec -T mariadb_encrypted mariadb -u root -p < $(SQL_FILE)

monitor:
	@echo "Vérification de l'âge du dernier backup ..."
	$(COMPOSE) -f $(STACK_FILE) exec mariadb_backup /usr/local/bin/check_backup.sh
