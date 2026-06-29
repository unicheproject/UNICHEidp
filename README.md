# UNICHE IdP

The platform identity provider (D4.3 §3.5): **Keycloak configured as code**, and the single source
of truth for the **`uniche` realm** — its clients, the shared-audience client scope, login/token
settings, the (disabled) ECCCH AAI federation, and the dev test users.

This repo brings up **only the IdP** (Keycloak + its Postgres). The Catalogue and Portal run from
their own repos and reach this IdP over the shared external Docker network `uniche` at the issuer URL
below — they do **not** embed this image.

> One of three independent repos: **uniche-idp** (this), `uniche-catalogue`, `uniche-portal`.

---

## Quick start

```bash
# 1. One-time on the host: the shared network
docker network create uniche

# 2. Configure and run
cp .env.example .env
docker compose up -d --build

# 3. Get a dev token and inspect it
TOKEN=$(curl -s http://uniche-idp.localhost:8081/realms/uniche/protocol/openid-connect/token \
  -d grant_type=password -d client_id=dev-cli \
  -d username=admin@uniche.test -d password=admin | jq -r .access_token)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq    # aud:uniche-platform, fixed sub, no role claims
```

Admin console: `http://uniche-idp.localhost:8081` (user/pass from `.env`, default `admin`/`admin`).

---

## Runtime contract (what the other repos consume)

| Output | Value (local dev) | Consumed by |
| :-- | :-- | :-- |
| Issuer URL | `http://uniche-idp.localhost:${IDP_HTTP_PORT}/realms/uniche` (default port `8081`) | Catalogue (`issuer-uri`), Portal (`IDP_URL`) |
| Realm | `uniche` | both |
| Shared audience | `uniche-platform` | Catalogue validates it; Portal token scope |
| Client `portal-web` | public, Authorization Code + PKCE | Portal |
| Client `catalogue` | confidential (resource server + client-credentials); dev secret `catalogue-dev-secret` | Catalogue |
| Client `dev-cli` | public, Direct Access Grants (**dev only**) | curl/test recipes in both repos |
| **Fixed admin `sub`** | `a0000000-0000-4000-a000-000000000001` | Catalogue `admin.seed.subject` |
| Dev users | `admin@uniche.test` / `admin` (fixed sub); `curator@uniche.test` / `curator` (no rights) | login demos |

Tokens carry **only standard OIDC claims + `aud: uniche-platform`** — no role/membership/admin
claims (the `roles` scope is intentionally removed from every client). All authorization is resolved
by the Catalogue at request time.

---

## Issuer consistency (the #1 local-dev gotcha)

The `iss` claim must be **identical** for the browser (Portal login) and the backend (Catalogue
validation). We pin it to `http://uniche-idp.localhost:${IDP_HTTP_PORT}`:

- Keycloak runs with `KC_HOSTNAME=http://uniche-idp.localhost:8081` (fixed frontend URL).
- Backend containers reach the same URL via `extra_hosts: ["uniche-idp.localhost:host-gateway"]`
  (it resolves to the host gateway, i.e. the published Keycloak port).
- The **browser** needs no hosts-file edit: per RFC 6761, browsers resolve any `*.localhost` name to
  loopback automatically. This is why `*.localhost` is used instead of `host.docker.internal`, which
  a Windows/WSL browser cannot resolve.

Always open the app and the admin console via `uniche-idp.localhost:8081`, **not** `localhost:8081`,
so the issuer matches.

---

## Configuration as code

`realm/uniche-realm.json` is the committed source of truth, baked into the image at build and applied
with `--import-realm` on startup. The admin console is read-only for config purposes:

- **Capture console changes:** `./scripts/export-realm.sh` → review diff → commit.
- **Re-apply local realm without rebuild:** `./scripts/import-realm.sh`.
- **Add an authoring-tool client:** `./scripts/add-tool-client.sh <slug> <base-url>` (uses
  `realm/client-template.json`), then `export-realm.sh` to persist. The seven tool clients are
  **not** pre-created — their redirect URIs are unknown until each tool exists.

## Enabling ECCCH AAI (FS-IAM-02)

Shipped as a **disabled** OIDC identity-provider broker (`eccch-aai`) with placeholder endpoints.
To enable: set the real issuer/endpoints + client secret in `realm/uniche-realm.json` (or via the
console then `export-realm.sh`), flip `enabled: true`, and rebuild. Brokered users present a stable
`sub` and are authorized identically to local users downstream.

## Version pinning

Keycloak and Postgres images are pinned by tag **and** `@sha256` digest (see `docker/Dockerfile` and
`docker-compose.yml`); the built image is tagged `uniche/idp:0.1.0`. No `latest` anywhere. Bumps land
via PR (Renovate/Dependabot).

## Deferred (later passes)

Production hardening details — real hostnames + TLS at the platform reverse proxy, admin bootstrap
via the secret store, real ECCCH endpoints — are per-deployment `[DEPLOY]` inputs.
