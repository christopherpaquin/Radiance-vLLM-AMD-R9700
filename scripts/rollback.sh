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

PROFILE="$(load_current_profile)"
STACK="$(load_current_stack)"
export MODEL_PROFILE="$PROFILE"
export STACK_FLAVOR="${STACK:-radiance-baseline}"
CONTAINER="$(container_name_for_stack "${STACK:-radiance-baseline}")"

log_step "Stopping ${CONTAINER} (stack: ${STACK:-radiance-baseline})"
compose stop "$CONTAINER" 2>/dev/null || log_warn "${CONTAINER} stop returned non-zero (may already be stopped)"
# Belt-and-suspenders: also stop the OTHER stack's container if it happens
# to be running (e.g. a radlight canary left up on 8081 during a manual
# final-fallback invocation) -- final rollback should never leave a second
# GPU-resident container competing for VRAM with llama.cpp.
for other in radiance-vllm radlight-vllm; do
  [[ "$other" == "$CONTAINER" ]] && continue
  if docker inspect "$other" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    log_warn "${other} is also running -- stopping it too before starting llama.cpp"
    docker stop "$other" 2>/dev/null || true
  fi
done

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
