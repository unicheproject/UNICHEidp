#!/usr/bin/env bash
# Capture the running realm back into realm/uniche-realm.json (config-as-code workflow).
#
# The Keycloak admin UI is NOT the source of truth: if you change the realm via the console,
# run this script and commit the diff. Uses `kc.sh export` against the shared Postgres DB
# (concurrent export is safe with Postgres), then copies the file out and re-pins the admin sub.
set -euo pipefail

cd "$(dirname "$0")/.."
REALM=uniche
ADMIN_SUB="a0000000-0000-4000-a000-000000000001"

echo "Exporting realm '$REALM' from the running keycloak service..."
docker compose exec -T keycloak /opt/keycloak/bin/kc.sh export \
  --dir /tmp/realm-export --users realm_file --realm "$REALM"

docker compose cp keycloak:/tmp/realm-export/"$REALM"-realm.json ./realm/uniche-realm.json

# Re-assert the fixed admin sub (kc.sh export preserves ids, but guard against drift).
python3 - "$ADMIN_SUB" <<'PY'
import json, sys
sub = sys.argv[1]
p = "realm/uniche-realm.json"
d = json.load(open(p))
for u in d.get("users", []):
    if u.get("username") == "admin@uniche.test":
        u["id"] = sub
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print("admin@uniche.test id pinned to", sub)
PY

echo "Wrote realm/uniche-realm.json — review the diff and commit."
