#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FORGE="$(bash scripts/find-forge.sh)"

bash scripts/bootstrap.sh
FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-default}" "$FORGE" test "$@"
