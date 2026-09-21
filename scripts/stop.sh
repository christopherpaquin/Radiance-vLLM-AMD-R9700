#!/usr/bin/env bash
# Stops radiance-vllm without removing the container -- `docker compose
# stop` (not `down`) preserves it for a fast restart, and a manual stop is
# sufficient to prevent `restart:unless-stopped` from reactivating it (same
# reasoning as this repo's rollback design for llama.cpp, plan §19).
#
# Usage: scripts/stop.sh [--remove]
#   --remove: also removes the container (docker compose down), e.g. before
#             uninstall or a full profile switch that needs force-recreate
#             semantics anyway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="$(load_current_profile)"
if [[ -z "$PROFILE" ]]; then
  log_warn "No remembered model profile. Trying compose stop anyway with an empty profile -- this may no-op."
fi
export MODEL_PROFILE="$PROFILE"
STACK="$(load_current_stack)"
export STACK_FLAVOR="$STACK"

if [[ "${1:-}" == "--remove" ]]; then
  log_step "Stopping and removing radiance-vllm"
  compose down
else
  log_step "Stopping radiance-vllm (container preserved)"
  compose stop
fi
log_pass "Stopped."
