#!/usr/bin/env bash
# Production database setup: bootstrap (create/rotate the easyshot_app role, migrate) or
# verify (RLS posture and migration state). Run through `mise run db:bootstrap|db:verify`.
#
# Needs MIGRATION_DATABASE_URL (owner role), plus APP_DATABASE_PASSWORD for bootstrap or
# DATABASE_URL (the server's app-role URL) for verify. Explicit variables win; otherwise
# the encrypted .env.production at the repository root is loaded with esec.
set -euo pipefail

case "${1:-}" in
  bootstrap | verify) ;;
  *) echo "Usage: run-production-db.sh bootstrap|verify" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
run=(cargo run -q --release -- db "$1")

if [[ -n "${MIGRATION_DATABASE_URL:-}" ]]; then
  if [[ "$1" == bootstrap && -n "${APP_DATABASE_PASSWORD:-}" ]] || [[ "$1" == verify && -n "${DATABASE_URL:-}" ]]; then
    exec "${run[@]}"
  fi
fi

if [[ -f ../.env.production ]]; then
  exec esec run ../.env.production -- "${run[@]}"
fi

exec "${run[@]}"
