#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FORGE="$(bash scripts/find-forge.sh)"

echo "==> Forge"
"$FORGE" --version

bash scripts/bootstrap.sh

echo "==> Format"
"$FORGE" fmt --check

echo "==> Build"
"$FORGE" build --sizes

echo "==> Tests (ci profile)"
FOUNDRY_PROFILE=ci "$FORGE" test -vvv
