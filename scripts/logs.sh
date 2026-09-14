#!/usr/bin/env bash
# Tails radiance-vllm's logs.
#
# Usage: scripts/logs.sh [-- <extra docker compose logs args>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="$(load_current_profile)"
export MODEL_PROFILE="$PROFILE"

compose logs -f "$@" radiance-vllm
