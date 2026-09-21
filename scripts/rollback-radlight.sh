#!/usr/bin/env bash
# Manual LEVEL-1 rollback: radlight -> the previously-validated
# radiance-baseline profile (NOT all the way to llama.cpp -- for that, use
# scripts/rollback.sh). Safe to run any time radlight is in production and
# an operator decides to step back one level, for any reason.
#
# Usage: scripts/rollback-radlight.sh [radiance-baseline-profile]
#   Defaults to the last radiance-baseline profile recorded before radlight
#   was promoted, if scripts/canary-radlight.sh's rollback manifest is
#   present; otherwise pass the profile explicitly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STATE_DIR="/var/lib/radiance-vllm/state"
MANIFEST="${STATE_DIR}/rollback-manifest.json"

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  if [[ -f "$MANIFEST" ]]; then
    PROFILE="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['prior_known_good']['profile'])" 2>/dev/null || true)"
  fi
fi
if [[ -z "$PROFILE" ]]; then
  log_fail "No profile given and no rollback manifest found at ${MANIFEST}. Usage: $(basename "$0") <radiance-baseline-profile>"
  exit 1
fi
PROFILE="$(resolve_profile_alias "$PROFILE")"
resolve_model_profile "$PROFILE" >/dev/null

if [[ "$(stack_for_profile "$PROFILE")" != "radiance-baseline" ]]; then
  log_fail "'${PROFILE}' is not a radiance-baseline profile -- refusing (this script is level-1 rollback only, radlight -> radiance-baseline)."
  exit 1
fi

log_step "Level-1 rollback: stopping radlight-vllm, restoring '${PROFILE}' (radiance-baseline) on port 8080"

if docker inspect radlight-vllm --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  docker update --restart=no radlight-vllm 2>/dev/null || true
  docker stop radlight-vllm || { log_fail "Could not stop radlight-vllm."; exit 1; }
fi

export API_PORT=8080
if grep -q '^API_PORT=' "${REPO_ROOT}/.env"; then
  sed -i 's/^API_PORT=.*/API_PORT=8080/' "${REPO_ROOT}/.env"
else
  echo "API_PORT=8080" >> "${REPO_ROOT}/.env"
fi
if grep -q '^STACK_FLAVOR=' "${REPO_ROOT}/.env"; then
  sed -i 's/^STACK_FLAVOR=.*/STACK_FLAVOR=radiance-baseline/' "${REPO_ROOT}/.env"
else
  echo "STACK_FLAVOR=radiance-baseline" >> "${REPO_ROOT}/.env"
fi

if DEPLOY_IS_RESTORE=1 "${SCRIPT_DIR}/deploy.sh" "$PROFILE"; then
  log_pass "Level-1 rollback complete: scar.lab:8080/v1 is served by radiance-vllm (profile: ${PROFILE}) again."
else
  log_fail "Level-1 rollback ALSO failed to come up. Falling through to the final fallback: scripts/rollback.sh (llama.cpp)."
  "${SCRIPT_DIR}/rollback.sh"
fi
