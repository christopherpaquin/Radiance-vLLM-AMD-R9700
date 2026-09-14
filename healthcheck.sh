#!/usr/bin/env bash
# Thin wrapper around scripts/status.sh -- top-level convenience entry
# point matching sibling repos' convention.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/status.sh" "$@"
