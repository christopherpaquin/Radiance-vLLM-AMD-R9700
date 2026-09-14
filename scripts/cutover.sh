#!/usr/bin/env bash
# Phase 4 (plan §3.1 Phase B / §18): takes over port 8080 from llama.cpp.
# The ONLY step in this migration that touches the live production
# endpoint -- everything before this runs on the staging port (8081) with
# zero production risk. Per plan §25, this runs autonomously (no human
# checkpoint), which makes automatic rollback (rollback.sh,
# restore-or-shutdown.sh) load-bearing, not optional.
#
# Usage: scripts/cutover.sh <profile>
#
# Order: cutover preflight -> disable llama.cpp autostart -> stop llama.cpp
# -> redeploy radiance-vllm on :8080 -> validate -> on any failure, roll
# back automatically (restart llama.cpp, leave radiance-vllm down).
set -uo pipefail # not -e: must reach rollback logic on failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { log_fail "Usage: $(basename "$0") <model-profile>"; exit 1; }
PROFILE="$(resolve_profile_alias "$PROFILE")"
resolve_model_profile "$PROFILE" >/dev/null
require_env_file

log_step "Cutover preflight"
if ! "${SCRIPT_DIR}/preflight.sh" --cutover; then
  log_fail "Cutover preflight failed. Aborting -- production port 8080 untouched."
  exit 1
fi

log_step "Disabling llama.cpp autostart and stopping it (config/container preserved, untouched otherwise)"
if ! docker update --restart=no llamacpp; then
  log_fail "Could not disable llamacpp's restart policy. Aborting before touching port 8080."
  exit 1
fi
if ! docker stop llamacpp; then
  log_fail "Could not stop llamacpp. Re-enabling its restart policy and aborting."
  docker update --restart=unless-stopped llamacpp || true
  exit 1
fi
log_pass "llama.cpp stopped, autostart disabled. Port 8080 is now free."

log_step "Recreating radiance-vllm on port 8080 (was 8081)"
export API_PORT=8080
# Persist the port change for future start/stop/status invocations.
if grep -q '^API_PORT=' "${REPO_ROOT}/.env"; then
  sed -i 's/^API_PORT=.*/API_PORT=8080/' "${REPO_ROOT}/.env"
else
  echo "API_PORT=8080" >> "${REPO_ROOT}/.env"
fi

cutover_rollback() {
  log_fail "Cutover failed -- rolling back automatically (plan §25: no human checkpoint at this step, so this IS the safety net)."
  compose stop radiance-vllm 2>/dev/null || true
  if docker update --restart=unless-stopped llamacpp && docker start llamacpp; then
    log_pass "Rolled back: llamacpp restarted on :8080, radiance-vllm stopped."
    # Verify rollback actually worked, not just that the commands exited 0.
    sleep 5
    if curl -fsS --max-time 10 http://localhost:8080/v1/models >/dev/null 2>&1; then
      log_pass "Rollback verified: :8080/v1/models responding again (llama.cpp)."
    else
      log_fail "ROLLBACK VERIFICATION FAILED: :8080/v1/models not responding after restarting llamacpp. Manual intervention required immediately."
    fi
  else
    log_fail "ROLLBACK ITSELF FAILED. Port 8080 may be down with neither service serving. Manual intervention required immediately: docker start llamacpp"
  fi
}
trap cutover_rollback ERR

if ! DEPLOY_IS_RESTORE=0 "${SCRIPT_DIR}/deploy.sh" "$PROFILE"; then
  cutover_rollback
  trap - ERR
  exit 1
fi
trap - ERR

log_step "Re-running tool-calling smoke subset against production port"
if ! "${SCRIPT_DIR}/test-tool-calling.sh" "$PROFILE"; then
  log_fail "Post-cutover tool-calling validation failed."
  cutover_rollback
  exit 1
fi

log_pass "Cutover complete. scar.lab:8080/v1 is now served by radiance-vllm (profile: ${PROFILE})."
log_info "Remaining manual steps (plan §14, §19 -- not yet automated by this script):"
log_info "  - Re-run scripts/configure-opencode.sh and scripts/configure-pi.sh on raptor.lab"
log_info "  - Verify Hermes still works (auto-detects model, should need no change)"
log_info "  - Update the dashboard's INFERENCE_BACKEND=vllm (see plan-radiance-observability.md)"
