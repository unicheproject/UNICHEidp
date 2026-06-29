# UNICHE IdP — Keycloak with the `uniche` realm baked into the image.
#
# Base images are pinned by tag AND @sha256 digest (resolved 2026-06-29). Never `latest`.
#   quay.io/keycloak/keycloak:26.1 -> sha256:be6a86215213145bfb4fb3e2b3ab982a806d00262655abdcf3ffa6a38d241c7c
#
# Stage 1 builds an optimized Keycloak (DB vendor + health/metrics baked in) so the runtime
# container starts with `start --optimized` and no first-request build cost.
FROM quay.io/keycloak/keycloak:26.1@sha256:be6a86215213145bfb4fb3e2b3ab982a806d00262655abdcf3ffa6a38d241c7c AS builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.1@sha256:be6a86215213145bfb4fb3e2b3ab982a806d00262655abdcf3ffa6a38d241c7c
COPY --from=builder /opt/keycloak/ /opt/keycloak/

# The realm definition is the single source of truth (config-as-code). It is baked into the image
# and applied with `--import-realm` on startup, so a fresh DB comes up with the `uniche` realm present.
COPY realm/uniche-realm.json /opt/keycloak/data/import/uniche-realm.json

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
