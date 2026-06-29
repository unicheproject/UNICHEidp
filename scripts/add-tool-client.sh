#!/usr/bin/env bash
# Add an authoring-tool client to the `uniche` realm from the public-PKCE template.
# Run this when a tool repo is created (e.g. ./scripts/add-tool-client.sh storymaker http://localhost:4200).
#
# The client is created with the shared-audience default scope so its tokens carry aud:uniche-platform.
# After adding, capture the change as code:  ./scripts/export-realm.sh  (then commit).
set -euo pipefail

SLUG="${1:?usage: add-tool-client.sh <slug> <base-url>   e.g. add-tool-client.sh storymaker http://localhost:4200}"
BASE_URL="${2:?missing <base-url>}"
REALM=uniche
KC_ADMIN="${KC_ADMIN:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"

cd "$(dirname "$0")/.."
KCADM="docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh"

$KCADM config credentials --server http://localhost:8080 --realm master \
  --user "$KC_ADMIN" --password "$KC_ADMIN_PASSWORD"

CID=$($KCADM create clients -r "$REALM" \
  -s clientId="$SLUG" -s enabled=true -s publicClient=true \
  -s standardFlowEnabled=true -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false \
  -s 'attributes."pkce.code.challenge.method"=S256' \
  -s 'attributes."post.logout.redirect.uris"=+' \
  -s "redirectUris=[\"${BASE_URL}/*\"]" \
  -s "webOrigins=[\"${BASE_URL}\"]" \
  -i)
echo "created client '$SLUG' (id=$CID)"

# Ensure the shared-audience scope is a default scope on the new client.
SCOPE_ID=$($KCADM get client-scopes -r "$REALM" --fields id,name \
  | tr -d ' \n' | grep -o '"id":"[^"]*","name":"uniche-platform-audience"' | cut -d'"' -f4)
$KCADM update "clients/$CID/default-client-scopes/$SCOPE_ID" -r "$REALM"
echo "attached uniche-platform-audience to '$SLUG'"
echo "Now run ./scripts/export-realm.sh to persist this as code, then commit."
