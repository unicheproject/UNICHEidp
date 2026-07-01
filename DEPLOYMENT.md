# Deploying the UNICHE IdP to a staging VM

Keycloak + its PostgreSQL, with the `uniche` realm baked into the image (config-as-code). It runs
from this repo's `docker compose` and sits **behind your external nginx** (which terminates TLS);
Keycloak itself speaks plain HTTP on the VM's loopback interface.

Throughout, replace the example host `idp.uniche-staging.example.org` with your real DNS name.

---

## 0. The one rule that governs everything: issuer consistency

The token `iss` claim must be **identical** for the browser (Portal login) and the backend
(Catalogue token validation). On staging that is simply the **public HTTPS URL**:

```
https://idp.uniche-staging.example.org/realms/uniche
```

This same value must appear as:
- the IdP's `KC_HOSTNAME` (this repo, below),
- the Catalogue's `IDP_ISSUER_URI`,
- the Portal's `IDP_URL` (the base, i.e. without `/realms/uniche`).

Because everything in staging uses the one public URL, the dev-only `host.docker.internal` /
`*.localhost` host-gateway tricks are **not needed** — drop them.

---

## 1. Prerequisites on the VM

- Docker Engine + Compose v2.
- `docker network create uniche` (the compose files declare this network `external`).
- A DNS A record for the IdP host pointing at the nginx VM, and a TLS certificate for it at nginx.

---

## 2. Configuration to change from dev → staging

### `.env` (copy from `.env.example`; comes from your secret store in a real pipeline)
```dotenv
KC_ADMIN=<choose a master-admin login>
KC_ADMIN_PASSWORD=<strong secret — NOT 'admin'>
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=<strong secret>

# Seed credentials — resolved into the realm file's ${...} placeholders at FIRST import.
# Set these BEFORE the first `docker compose up` (after import they live in the DB; see §5).
SEED_ADMIN_PASSWORD=<strong secret>
SEED_CURATOR_PASSWORD=<strong secret>
CATALOGUE_CLIENT_SECRET=<strong secret>

# Bind published ports to loopback so ONLY nginx (same VM) can reach them.
# The value is interpolated into the host side of the port mapping, so "127.0.0.1:8081"
# becomes "127.0.0.1:8081:8080".
IDP_HTTP_PORT=127.0.0.1:8081
IDP_DB_PORT=127.0.0.1:5433
```

### `docker-compose.override.yml` (create next to the compose file)
The base compose hardcodes `KC_HOSTNAME` to the dev URL and sets no proxy headers, so override them.
`docker compose` merges this file automatically.
```yaml
services:
  keycloak:
    environment:
      # Public issuer base. Keycloak derives issuer, JWKS and redirect URLs from this.
      KC_HOSTNAME: https://idp.uniche-staging.example.org
      # Trust X-Forwarded-* from nginx (TLS terminates there; Keycloak speaks HTTP internally).
      KC_PROXY_HEADERS: xforwarded
      KC_HTTP_ENABLED: "true"
```

---

## 3. nginx vhost (your proxy — not in this repo)

```nginx
server {
  listen 443 ssl;
  server_name idp.uniche-staging.example.org;
  ssl_certificate     /etc/letsencrypt/live/idp.uniche-staging.example.org/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/idp.uniche-staging.example.org/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:8081;
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $host;
    proxy_set_header X-Forwarded-Port  $server_port;
  }
}
```

---

## 4. Deploy

```bash
cp .env.example .env          # then edit it
# create docker-compose.override.yml as above
docker network create uniche  # once per VM
docker compose up -d --build
docker compose logs -f keycloak
```

For repeatable deploys, build the image in CI, push it to a registry, and replace the `build:`
block with `image: <registry>/uniche-idp:<tag>` on the VM.

### Smoke test
```bash
curl -s https://idp.uniche-staging.example.org/realms/uniche/.well-known/openid-configuration \
  | jq .issuer
# → must print EXACTLY: https://idp.uniche-staging.example.org/realms/uniche
```
Master admin console: `https://idp.uniche-staging.example.org/admin/`.

---

## 5. Realm-as-code and your users — READ THIS

**Short answer: no, a config change or redeploy does NOT wipe your users — as long as you keep the
database volume.** There are two separate things:

| In the realm JSON (`realm/uniche-realm.json`, baked into the image) | In the Keycloak **database** (`keycloak-db-data` volume) |
| :-- | :-- |
| Realm settings, clients, client scopes, protocol mappers, and the **seed** users defined in the file (but **no keys** — see "Realm keys" below) | Every user created at runtime, their credentials, role/group assignments, sessions, consents, and the realm's **signing/encryption keys** |

`--import-realm` runs on every start but **imports a realm only if it does not already exist**. Once
`uniche` is in the database, each later start logs *"Realm 'uniche' already exists. Import skipped"*
and changes nothing.

- **Safe (users preserved):** restarting the container, rebuilding/redeploying the image, bumping
  the Keycloak version — as long as the `keycloak-db-data` volume survives.
- **Destroys users:** `docker compose down -v` (deletes the volume), deleting the realm in the admin
  console, or a deliberate destructive re-import.

**Key consequence:** because import is skipped once the realm exists, **editing the realm JSON and
redeploying does NOT apply the change.** To change realm config on a running staging realm, do one
of these (in order of preference):

1. **Admin Console / `kcadm` / Admin REST** against the live realm — non-destructive, users
   untouched. Then re-export to keep the file in sync and commit it:
   ```bash
   ./scripts/export-realm.sh                # DEFAULT: config only — no live users. Safe here.
   ./scripts/export-realm.sh --with-users   # also capture the live user LIST (dev only)
   ```
   The export **never writes secrets or key material**: client/IdP secrets and seed passwords are
   restored to their `${...}` placeholders, and the realm's signing/encryption **keys are dropped
   entirely** (they are per-environment — see "Realm keys" below). A residual-secret scan warns on
   anything secret-shaped that slips through, so it is caught in review rather than committed.
2. **Partial import** for purely additive changes (a new client or scope) via the admin REST
   `partialImport` endpoint.
3. *(Last resort — destructive)* delete the realm and re-import: this recreates only the objects and
   **seed** users in the JSON and **loses every runtime user**. Don't do this once real users exist.

Recommended model: treat the JSON as your **bootstrap + reviewed source of truth**; make incremental
changes through the admin API and re-export. **Back up the `keycloak-db` database regularly** — that
is where your users actually live.

### Realm keys live in the database, never in git

The realm's token **signing/encryption keys** (RSA private keys, HMAC/AES secrets) are *not* in
`realm/uniche-realm.json` — `export-realm.sh` strips them. They are per-environment runtime state:
Keycloak **generates fresh keys on first import** and stores them in the `keycloak-db-data` volume,
where they survive restarts and redeploys. So dev and staging each hold their own keys and none ever
reach the repo. Consumers (Catalogue, Portal) fetch the public keys from JWKS at runtime, so a key
change is transparent to them — no restart or config change on their side.

**Consequence for `docker compose down -v`:** deleting the volume deletes the keys too, so the next
`up` generates brand-new ones. On an environment with **no users worth keeping**, that is the
simplest way to *rotate* a compromised key — nuke the volume and let Keycloak regenerate. On an
environment with **real users**, `down -v` wipes them as well, so rotate in the Admin Console
instead (Realm Settings → Keys: add new `rsa-generated`/`hmac-generated`/`aes-generated` providers at
a higher priority, then delete the old ones).

---

## 6. Local development: applying realm changes

You do **not** need `docker compose down -v` after every config change. Pick the loop that fits:

**A. Edit live, then capture (everyday loop).** Change the realm in the Admin Console, then export
and commit — no restart, because you edited the running realm directly:
```bash
./scripts/export-realm.sh                     # config-only, key-free by default
git add realm/uniche-realm.json && git commit
```

**B. Hand-edit the JSON, then re-apply.** A plain restart will **not** pick up an edited file (import
is skipped once the realm exists — see §5). Force it:
```bash
docker compose down -v && docker compose up -d --build   # clean slate: fresh DB, fresh keys
# or, without deleting the whole volume — re-imports the uniche realm only:
./scripts/import-realm.sh
```
Both are destructive to the `uniche` realm's runtime users and regenerate its keys — fine in dev.

**When to reach for `down -v && up --build`:** to prove the committed file imports cleanly *from
scratch*, or to reset to a known-good state — not reflexively after every tweak.

---

## 7. Harden the seeded realm for staging

The realm ships with dev conveniences. Apply these via the admin console / `kcadm` (see §5 — do NOT
re-import destructively):

- **Seeded-user passwords and the catalogue client secret** are NOT in the realm file — they are
  `${SEED_ADMIN_PASSWORD}` / `${SEED_CURATOR_PASSWORD}` / `${CATALOGUE_CLIENT_SECRET}` placeholders
  resolved from env at first import. Set strong values in `.env` (or the secret store) **before the
  first `docker compose up`**. To change them *after* import, update the live realm via the admin
  console (the placeholders are only read at import time — see §5). The **platform admin is whoever's
  `sub` equals the Catalogue's `ADMIN_SEED_SUBJECT`** — keep the seeded admin user, or point
  `ADMIN_SEED_SUBJECT` at your real admin's `sub`.
- **`portal-web` client** lists only `localhost`/`*.localhost` redirect URIs and web origins. Add the
  staging Portal URL:
  - Valid redirect URIs: `https://uniche-staging.example.org/*`
  - Web origins: `https://uniche-staging.example.org`
- **Realm CSP `frame-ancestors`** (Realm Settings → Security Defenses) lists the dev Portal origins
  for the silent-SSO iframe. Add `https://uniche-staging.example.org`.
- **`dev-cli` client** is a public client with direct-access (password) grants for local testing.
  Disable it on staging unless you need scripted token fetches.
