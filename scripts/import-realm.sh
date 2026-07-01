#!/usr/bin/env bash
# Apply the local realm/uniche-realm.json to the running Keycloak (overwriting the realm).
# Useful to re-apply realm edits without rebuilding the image. For a clean rebuild instead run:
#   docker compose down -v && docker compose up -d --build
set -euo pipefail

cd "$(dirname "$0")/.."

# The realm file holds ${...} placeholders (seed passwords, catalogue secret) that Keycloak
# resolves from environment variables at import time. The import runs *inside* the container, so
# forward any of these that are set in the current shell — that way a fresh `.env` takes effect
# even if the running container was started with older values. To load them first, run:
#   source ./scripts/load-env.sh
# If a var is unset here, the container's own env (compose default) is used instead.
env_flags=()
for v in SEED_ADMIN_PASSWORD SEED_CURATOR_PASSWORD CATALOGUE_CLIENT_SECRET; do
  if [ -n "${!v:-}" ]; then
    env_flags+=(-e "$v=${!v}")
  fi
done

echo "Copying realm into the keycloak container and importing (override=true)..."
docker compose cp ./realm/uniche-realm.json keycloak:/opt/keycloak/data/import/uniche-realm.json
docker compose exec -T ${env_flags[@]+"${env_flags[@]}"} keycloak /opt/keycloak/bin/kc.sh import \
  --file /opt/keycloak/data/import/uniche-realm.json --override true

echo "Imported. Restart the service if needed: docker compose restart keycloak"
