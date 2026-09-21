#!/usr/bin/env bash
# Promotes a validated Radlight canary (scripts/canary-radlight.sh) from
# its canary port to production port 8080. The ONLY step that touches the
# live production endpoint for the radlight stack -- run this only after
# every gate in the mission spec has passed (correctness, tool-calling,
# DFlash2 equivalence, long-context, benchmark thresholds -- see
# docs/runbook.md "Radlight canary" and docs/RADLIGHT-TUNABLES.md).
#
# Order: preflight -> stop the radlight canary (it currently owns the
# canary port, not 8080) -> stop whatever is presently on 8080 (should be
# the radiance-baseline container, already stopped by canary-radlight.sh,
# but handle either state) -> redeploy radlight on 8080 -> re-validate ->
# on any failure, roll back automatically through restore-or-shutdown.sh's
# two-level chain (radiance-baseline, then llama.cpp if that also fails).
#
# Usage: scripts/promote-radlight.sh <radlight-profile>
set -uo pipefail # not -e: must reach rollback logic on failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { log_fail "Usage: $(basename "$0") <radlight-profile>"; exit 1; }
PROFILE="$(resolve_profile_alias "$PROFILE")"
resolve_model_profile "$PROFILE" >/dev/null
require_env_file

if [[ "$(stack_for_profile "$PROFILE")" != "radlight" ]]; then
  log_fail "'${PROFILE}' is not a radlight profile."
  exit 1
fi

log_step "Promotion preflight"
if ! "${SCRIPT_DIR}/preflight.sh" --cutover; then
  log_fail "Preflight failed. Aborting -- production port 8080 untouched."
  exit 1
fi

log_step "Stopping the radlight canary (currently on its canary port, not 8080)"
export STACK_FLAVOR="radlight"
export MODEL_PROFILE="$PROFILE"
compose stop radlight-vllm 2>/dev/null || log_warn "radlight-vllm canary was not running (already stopped?)"

log_step "Ensuring port 8080 is free"
if docker inspect radiance-vllm --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  log_step "radiance-vllm is still running on 8080 -- stopping it (rollback-preserved, not removed)"
  docker update --restart=no radiance-vllm 2>/dev/null || true
  docker stop radiance-vllm || { log_fail "Could not stop radiance-vllm. Aborting before touching 8080."; exit 1; }
fi

log_step "Recreating radlight-vllm on port 8080 (was on the canary port)"
export API_PORT=8080
if grep -q '^API_PORT=' "${REPO_ROOT}/.env"; then
  sed -i 's/^API_PORT=.*/API_PORT=8080/' "${REPO_ROOT}/.env"
else
  echo "API_PORT=8080" >> "${REPO_ROOT}/.env"
fi
if grep -q '^STACK_FLAVOR=' "${REPO_ROOT}/.env"; then
  sed -i 's/^STACK_FLAVOR=.*/STACK_FLAVOR=radlight/' "${REPO_ROOT}/.env"
else
  echo "STACK_FLAVOR=radlight" >> "${REPO_ROOT}/.env"
fi

promotion_rollback() {
  log_fail "Promotion failed -- rolling back automatically via the two-level chain."
  export STACK_FLAVOR="radlight"
  export MODEL_PROFILE="$PROFILE"
  compose stop radlight-vllm 2>/dev/null || true
  "${SCRIPT_DIR}/restore-or-shutdown.sh" "$PROFILE"
}
trap promotion_rollback ERR

if ! DEPLOY_IS_RESTORE=0 "${SCRIPT_DIR}/deploy.sh" "$PROFILE"; then
  promotion_rollback
  trap - ERR
  exit 1
fi
trap - ERR

log_step "Re-running tool-calling smoke subset against production port"
if ! "${SCRIPT_DIR}/test-tool-calling.sh" "$PROFILE"; then
  log_fail "Post-promotion tool-calling validation failed."
  promotion_rollback
  exit 1
fi

log_pass "Promotion complete. scar.lab:8080/v1 is now served by radlight-vllm (profile: ${PROFILE})."
log_info "Verify clients still work: OpenCode/PI on raptor.lab (endpoint/model id unchanged -- scar.lab:8080/v1, scar-coder), Hermes locally."
log_info "Rollback if needed: scripts/rollback-radlight.sh (radlight -> radiance-baseline), or scripts/rollback.sh for the final llama.cpp fallback."
