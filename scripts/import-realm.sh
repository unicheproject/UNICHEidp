#!/usr/bin/env bash
# Apply the local realm/uniche-realm.json to the running Keycloak (overwriting the realm).
# Useful to re-apply realm edits without rebuilding the image. For a clean rebuild instead run:
#   docker compose down -v && docker compose up -d --build
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Copying realm into the keycloak container and importing (override=true)..."
docker compose cp ./realm/uniche-realm.json keycloak:/opt/keycloak/data/import/uniche-realm.json
docker compose exec -T keycloak /opt/keycloak/bin/kc.sh import \
  --file /opt/keycloak/data/import/uniche-realm.json --override true

echo "Imported. Restart the service if needed: docker compose restart keycloak"
