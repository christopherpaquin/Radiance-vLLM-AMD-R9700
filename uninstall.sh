#!/usr/bin/env bash
# Stops and removes the radiance-vllm container/image. Does NOT touch
# llama.cpp, does NOT delete /var/lib/radiance-vllm's model cache or state
# by default (models are large and expensive to re-download).
#
# Usage: ./uninstall.sh [--purge-data]
#   --purge-data: also deletes /var/lib/radiance-vllm entirely. Asks for
#                 confirmation; refuses on an unsafe-looking path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

log_step "Stopping and removing radiance-vllm container"
PROFILE="$(load_current_profile)"
export MODEL_PROFILE="$PROFILE"
compose down 2>/dev/null || log_warn "compose down returned non-zero (container may not exist)"

if [[ "${1:-}" == "--purge-data" ]]; then
  target="/var/lib/radiance-vllm"
  # Safety gate: refuse anything that isn't exactly this well-known path.
  if [[ "$target" != "/var/lib/radiance-vllm" ]]; then
    log_fail "Refusing to purge an unexpected path: ${target}"
    exit 1
  fi
  read -r -p "This will permanently delete ${target} (model cache, state, benchmarks). Type 'yes' to confirm: " confirm
  if [[ "$confirm" == "yes" ]]; then
    sudo rm -rf "$target"
    log_pass "Purged ${target}."
  else
    log_info "Purge cancelled."
  fi
fi

log_pass "Uninstall complete. llama.cpp was not touched."
