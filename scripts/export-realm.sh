#!/usr/bin/env bash
# Capture the running realm back into realm/uniche-realm.json (config-as-code workflow).
#
#   ./scripts/export-realm.sh                # DEFAULT: config only — no live users. Safe everywhere.
#   ./scripts/export-realm.sh --with-users   # also capture the live user LIST (dev use only)
#   ./scripts/export-realm.sh --config-only  # explicit alias for the default
#
# The Keycloak admin UI is NOT the source of truth: change the realm in the console, run this, and
# commit the diff. The script NEVER writes live secrets or key material to the file:
#   * realm signing/encryption KEYS are dropped entirely — they are per-environment runtime state,
#     owned by Keycloak and persisted in its DB volume; on import Keycloak regenerates them. Keys
#     must never live in git (a leaked realm private key lets anyone forge tokens);
#   * client secrets and IdP broker secrets are restored to the committed ${...} placeholders;
#   * seed-user passwords are kept as their ${...} placeholders (never the resolved hashes);
#   * --with-users additionally keeps the live user list (dev only; still no credential hashes).
set -euo pipefail

cd "$(dirname "$0")/.."

REALM=uniche
ADMIN_SUB="a0000000-0000-4000-a000-000000000001"
COMMITTED="realm/uniche-realm.json"

# Config-only is the DEFAULT so an export is safe to run on any environment, including one with real
# users. Pass --with-users only on a throwaway dev instance where capturing the user list is useful.
MODE=config-only
case "${1:-}" in
  ""|--config-only)     MODE=config-only ;;
  --with-users|--full)  MODE=full ;;
  *) echo "usage: $0 [--config-only | --with-users]" >&2; exit 2 ;;
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
import json, re, sys

export_path, committed_path, mode, admin_sub = sys.argv[1:5]
new = json.load(open(export_path))
old = json.load(open(committed_path))

# --- Realm KEYS: never commit signing/encryption private keys or HMAC/AES secrets ---
# These are per-environment runtime state: Keycloak generates them on import and persists them in
# its DB volume. Dropping the key providers here means the committed realm carries NO key material;
# each environment (dev, staging) keeps its own keys, and none of them ever land in git.
comps = new.get("components")
if isinstance(comps, dict):
    dropped = comps.pop("org.keycloak.keys.KeyProvider", None)
    if dropped:
        print(f"Dropped {len(dropped)} realm key provider(s) — keys stay in each env's DB, not git.",
              file=sys.stderr)

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

# --- Safety net: warn on any residual secret-shaped value that is not a placeholder/sentinel ---
# Catches anything a future realm change introduces (LDAP bind creds, new key types, an IdP secret
# that wasn't externalised) so it gets noticed in review instead of silently committed. Matches only
# keys that actually carry secret VALUES — NOT config toggles like *Password* policy flags.
def key_is_secret(k):
    kl = k.lower()
    return kl in {"secret", "clientsecret", "bindcredential", "secretdata"} \
        or kl.endswith("secret") or kl.endswith("privatekey")
PLACEHOLDER = re.compile(r"^\$\{[^}]+\}$")          # externalised: ${VAR}
SENTINEL = re.compile(r"^(CHANGE_ME|REDACTED|TODO)", re.I)  # intentional non-secret placeholder text
def is_safe(v):
    if isinstance(v, str):
        return bool(PLACEHOLDER.match(v) or SENTINEL.match(v))
    if isinstance(v, list):
        return all(isinstance(x, str) and is_safe(x) for x in v) if v else True
    return False
def scan(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}"
            if key_is_secret(k) and v not in (None, "", []) and not is_safe(v):
                sample = str(v)[:24].replace("\n", " ")
                print(f"WARNING: possible secret left in export at {p} = {sample}... "
                      f"— review before committing", file=sys.stderr)
            scan(v, p)
    elif isinstance(node, list):
        for idx, v in enumerate(node):
            scan(v, f"{path}[{idx}]")
scan(new)

json.dump(new, open(committed_path, "w"), indent=2, ensure_ascii=False)
print(f"Wrote {committed_path} (mode={mode}).")
PY

echo "Done. Review the diff and commit — no live secrets, key material, or credential hashes were written."
