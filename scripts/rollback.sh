#!/usr/bin/env bash
# Manual rollback: stop radiance-vllm, restart llama.cpp, verify. Plan §19.
# Safe to run any time, including outside a failed-cutover scenario (e.g.
# an operator decides to roll back later for any reason).
#
# Usage: scripts/rollback.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

log_step "Stopping radiance-vllm"
PROFILE="$(load_current_profile)"
export MODEL_PROFILE="$PROFILE"
compose stop radiance-vllm 2>/dev/null || log_warn "radiance-vllm stop returned non-zero (may already be stopped)"

log_step "Restoring llama.cpp"
if ! docker update --restart=unless-stopped llamacpp; then
  log_fail "Could not re-enable llamacpp's restart policy."
  exit 1
fi
if ! docker start llamacpp; then
  log_fail "Could not start llamacpp."
  exit 1
fi

log_step "Verifying rollback"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 http://localhost:8080/v1/models >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 5
done

if [[ "$ok" -eq 1 ]]; then
  log_pass "Rollback verified: scar.lab:8080/v1 responding again (llama.cpp)."
else
  log_fail "Rollback commands succeeded but :8080/v1/models is not responding. Investigate immediately: docker logs llamacpp"
  exit 1
fi

log_info "Reminder (plan §19): if OpenCode/PI were already reconfigured for radiance-vllm/scar-coder,"
log_info "revert those configs too -- this script only reverts the server side."
