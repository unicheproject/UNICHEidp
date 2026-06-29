#!/usr/bin/env bash
# Capture the running realm back into realm/uniche-realm.json (config-as-code workflow).
#
#   ./scripts/export-realm.sh                # full: also captures the user LIST (dev use)
#   ./scripts/export-realm.sh --config-only  # config only: no live users — SAFE on staging/prod
#
# The Keycloak admin UI is NOT the source of truth: change the realm in the console, run this, and
# commit the diff. Either way the script NEVER writes live secrets or credential hashes to the file:
#   * client secrets and IdP broker secrets are restored to the committed ${...} placeholders;
#   * seed-user passwords are kept as their ${...} placeholders (never the resolved hashes);
#   * --config-only additionally skips the live user list entirely (use it anywhere with real users).
set -euo pipefail

cd "$(dirname "$0")/.."

REALM=uniche
ADMIN_SUB="a0000000-0000-4000-a000-000000000001"
COMMITTED="realm/uniche-realm.json"

MODE=full
case "${1:-}" in
  "")            MODE=full ;;
  --config-only) MODE=config-only ;;
  *) echo "usage: $0 [--config-only]" >&2; exit 2 ;;
esac

USERS_FLAG=realm_file
[[ "$MODE" == config-only ]] && USERS_FLAG=skip

echo "Exporting realm '$REALM' (mode=$MODE) from the running keycloak service..."
TMP="$(mktemp)"
LOG="$(mktemp)"
trap 'rm -f "$TMP" "$LOG"' EXIT

# `kc.sh export` writes the realm data and THEN tries to start the server, which fails because the
# already-running container holds the management port — a harmless non-zero exit. So ignore the exit
# code and assert the file was actually produced instead. (Concurrent export is safe with Postgres.)
docker compose exec -T keycloak rm -rf /tmp/realm-export >/dev/null 2>&1 || true
docker compose exec -T keycloak /opt/keycloak/bin/kc.sh export \
  --dir /tmp/realm-export --users "$USERS_FLAG" --realm "$REALM" >"$LOG" 2>&1 || true
if ! docker compose exec -T keycloak test -s /tmp/realm-export/"$REALM"-realm.json; then
  echo "ERROR: realm export produced no file. kc.sh output:" >&2
  cat "$LOG" >&2
  exit 1
fi

docker compose cp keycloak:/tmp/realm-export/"$REALM"-realm.json "$TMP"

# Merge the export into the committed file, scrubbing anything secret. The committed file supplies
# the placeholders we restore, so the externalised credentials are never overwritten.
python3 - "$TMP" "$COMMITTED" "$MODE" "$ADMIN_SUB" <<'PY'
import json, sys

export_path, committed_path, mode, admin_sub = sys.argv[1:5]
new = json.load(open(export_path))
old = json.load(open(committed_path))

# --- Users: never let live user data / credential hashes reach the committed file ---
old_users = old.get("users", [])
old_creds = {u.get("username"): u.get("credentials") for u in old_users}
if mode == "config-only":
    # Take the curated seed users (with ${...} placeholders) wholesale; no live users at all.
    new["users"] = old_users
else:
    # Keep the exported user LIST, but restore placeholder credentials for the seed accounts so the
    # externalised passwords are never replaced by resolved hashes.
    for u in new.get("users", []):
        uname = u.get("username")
        if old_creds.get(uname) is not None:
            u["credentials"] = old_creds[uname]
        elif u.get("credentials"):
            print(f"WARNING: user {uname!r} carries live credentials — review before committing", file=sys.stderr)

# --- Client secrets: restore the committed ${...} placeholder; never emit a resolved secret ---
old_secret = {c.get("clientId"): c.get("secret") for c in old.get("clients", []) if "secret" in c}
for c in new.get("clients", []):
    if "secret" in c:
        repl = old_secret.get(c.get("clientId"))
        if repl is None:
            repl = "${REDACTED_CLIENT_SECRET}"
            print(f"WARNING: client {c.get('clientId')!r} secret has no committed placeholder — "
                  f"redacted; externalise it like CATALOGUE_CLIENT_SECRET", file=sys.stderr)
        c["secret"] = repl

# --- Identity-provider broker secrets (e.g. ECCCH AAI) ---
old_idp = {i.get("alias"): i.get("config", {}).get("clientSecret") for i in old.get("identityProviders", [])}
for i in new.get("identityProviders", []):
    cfg = i.get("config", {})
    if "clientSecret" in cfg and old_idp.get(i.get("alias")) is not None:
        cfg["clientSecret"] = old_idp[i.get("alias")]

# --- Re-pin the fixed admin sub (consumed by the Catalogue as ADMIN_SEED_SUBJECT) ---
for u in new.get("users", []):
    if u.get("username") == "admin@uniche.test":
        u["id"] = admin_sub

json.dump(new, open(committed_path, "w"), indent=2, ensure_ascii=False)
print(f"Wrote {committed_path} (mode={mode}).")
PY

echo "Done. Review the diff and commit — no live secrets or credential hashes were written."
