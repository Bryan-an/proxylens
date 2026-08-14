#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'error: run this script from a Git working tree.\n' >&2
    exit 1
}

chmod +x .githooks/pre-commit .githooks/pre-push scripts/quality.sh scripts/setup-hooks.sh scripts/package.sh scripts/notarize.sh
git config --local core.hooksPath .githooks

printf 'Git hooks enabled for ProxyLens.\n'
printf 'Configured core.hooksPath: %s\n' "$(git config --local --get core.hooksPath)"
