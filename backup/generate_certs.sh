#!/bin/bash
# Génère une CA, un certificat serveur et des certificats clients à partir d'un .env
# Place les fichiers dans secrets/
# Utilise OpenSSL (doit être installé)

set -euo pipefail

# Charger les variables d'environnement depuis .env
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo ".env introuvable. Abandon." >&2
  exit 1
fi

SECRETS_DIR="secrets"
mkdir -p "$SECRETS_DIR"

# Paramètres par défaut
CA_KEY="$SECRETS_DIR/ca.key"
CA_CERT="$SECRETS_DIR/ca.crt"
SERVER_KEY="$SECRETS_DIR/server.key"
SERVER_CSR="$SECRETS_DIR/server.csr"
SERVER_CERT="$SECRETS_DIR/server.crt"
SERVER_EXT="$SECRETS_DIR/server.ext"

# 1. Générer la CA si absente
if [ ! -f "$CA_KEY" ]; then
  openssl genrsa -out "$CA_KEY" 4096
fi
if [ ! -f "$CA_CERT" ]; then
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
    -subj "/CN=MariaDB-CA" -out "$CA_CERT"
fi


# 2. Générer le certificat serveur
openssl genrsa -out "$SERVER_KEY" 4096
openssl req -new -key "$SERVER_KEY" -subj "/CN=mariadb-server" -out "$SERVER_CSR"
echo "subjectAltName=DNS:mariadb-server,IP:127.0.0.1" > "$SERVER_EXT"
openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SERVER_CERT" -days "${DAYS_VALID:-1825}" -sha256 -extfile "$SERVER_EXT"


# 3. Générer les certificats clients
IFS=',' read -ra CLIENTS <<< "$CLIENT_NAMES"
for CLIENT in "${CLIENTS[@]}"; do
  CLIENT_KEY="$SECRETS_DIR/${CLIENT}.key"
  CLIENT_CSR="$SECRETS_DIR/${CLIENT}.csr"
  CLIENT_CERT="$SECRETS_DIR/${CLIENT}.crt"
  openssl genrsa -out "$CLIENT_KEY" 4096
  openssl req -new -key "$CLIENT_KEY" -subj "/CN=$CLIENT" -out "$CLIENT_CSR"
  openssl x509 -req -in "$CLIENT_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$CLIENT_CERT" -days "${DAYS_VALID:-1825}" -sha256
  rm -f "$CLIENT_CSR"
done

# Nettoyage
rm -f "$SERVER_CSR" "$SERVER_EXT"
echo "Certificats générés dans $SECRETS_DIR :"
ls -1 "$SECRETS_DIR" | grep -E '\.(key|crt)$'
