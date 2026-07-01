#!/usr/bin/env bash
# Load the repo's .env into the CURRENT shell so the seed-secret placeholders
# (${SEED_ADMIN_PASSWORD}, ${SEED_CURATOR_PASSWORD}, ${CATALOGUE_CLIENT_SECRET})
# are available to ./scripts/import-realm.sh, which forwards them into the
# Keycloak container at import time.
#
# MUST be sourced — a child process cannot export into your shell:
#   source ./scripts/load-env.sh      # or:  . ./scripts/load-env.sh
#   ./scripts/import-realm.sh
#
# Then verify:  echo "$SEED_ADMIN_PASSWORD"
#
# Note: the realm file's placeholders are only resolved for users/clients that
# do NOT already exist. On a realm that is already imported, re-running the
# import with --override updates seed users/clients to these values.

# Guard: refuse to run as a subprocess (exports would be lost).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "load-env.sh must be SOURCED, not executed:" >&2
  echo "  source ${0}" >&2
  exit 1
fi

_UNICHE_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"

if [ ! -f "$_UNICHE_ENV_FILE" ]; then
  echo "load-env.sh: no .env found at $_UNICHE_ENV_FILE" >&2
  return 1
fi

# `set -a` marks every variable assigned while sourcing for export.
# .env is KEY=value with # comments, so it is safe to source directly.
set -a
# shellcheck disable=SC1090
. "$_UNICHE_ENV_FILE"
set +a

echo "Loaded env from $_UNICHE_ENV_FILE"
for _v in SEED_ADMIN_PASSWORD SEED_CURATOR_PASSWORD CATALOGUE_CLIENT_SECRET; do
  if [ -n "${!_v:-}" ]; then
    echo "  $_v = (set)"
  else
    echo "  $_v = (unset — import will fall back to the container/compose default)"
  fi
done
unset _v _UNICHE_ENV_FILE
