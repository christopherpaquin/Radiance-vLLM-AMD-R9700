#!/usr/bin/env bash
# Sequential canary for the Radlight stack (plan-radlight-integration §5).
# A single 32GiB R9700 cannot hold the current production stack AND a
# Radlight candidate resident at once, so this is genuinely sequential, not
# a zero-impact port-only staging: the current production container is
# stopped for the duration of this canary.
#
# Order: capture rollback manifest -> stop current production stack
# (preserved, not removed) -> deploy the radlight profile on the canary
# port -> deploy.sh's own health-wait + validate-model.sh gates run
# automatically, and on failure fall back through restore-or-shutdown.sh
# (radiance-baseline, then llama.cpp if that also fails -- see that
# script). On success, the canary is left running on the canary port for
# the rest of the correctness/long-context/benchmark matrix
# (docs/RADLIGHT-TUNABLES.md, docs/runbook.md) -- this script does NOT
# promote to production port 8080 by itself; run scripts/promote-radlight.sh
# only after every gate has passed.
#
# Usage: scripts/canary-radlight.sh <radlight-profile> [canary-port]
set -uo pipefail # not -e: must reach rollback logic on failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="${1:-}"
CANARY_PORT="${2:-8081}"
[[ -n "$PROFILE" ]] || { log_fail "Usage: $(basename "$0") <radlight-profile> [canary-port]"; exit 1; }
PROFILE="$(resolve_profile_alias "$PROFILE")"
resolve_model_profile "$PROFILE" >/dev/null
require_env_file

if [[ "$(stack_for_profile "$PROFILE")" != "radlight" ]]; then
  log_fail "'${PROFILE}' is not a radlight profile (stack_for_profile resolved to '$(stack_for_profile "$PROFILE")'). Use scripts/deploy.sh for radiance-baseline profiles."
  exit 1
fi

log_step "Radlight sequential canary: profile '${PROFILE}' on canary port ${CANARY_PORT}"

PRIOR_PROFILE="$(load_current_profile)"
PRIOR_STACK="$(load_current_stack)"
if [[ -z "$PRIOR_PROFILE" ]]; then
  log_fail "No current known-good profile on record -- refusing to run a canary with no verified rollback target. Deploy a baseline profile with scripts/deploy.sh first."
  exit 1
fi
log_info "Current known-good (rollback target): profile='${PRIOR_PROFILE}' stack='${PRIOR_STACK}'"

# --- 1. rollback manifest ----------------------------------------------------

STATE_DIR="/var/lib/radiance-vllm/state"
MANIFEST="${STATE_DIR}/rollback-manifest.json"
mkdir -p "$STATE_DIR"

log_step "Capturing rollback manifest"
load_env
PRIOR_CONTAINER="$(container_name_for_stack "$PRIOR_STACK")"
prior_image_digest="$(docker inspect "$PRIOR_CONTAINER" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo unknown)"
prior_port="$(docker inspect "$PRIOR_CONTAINER" --format '{{range $p, $b := .NetworkSettings.Ports}}{{(index $b 0).HostPort}}{{end}}' 2>/dev/null || echo unknown)"

# Effective .env, secrets excluded (TOKEN/KEY/SECRET in the var name).
redacted_env="$(grep -vE '^\s*(#|$)' "${REPO_ROOT}/.env" | grep -vE 'TOKEN|KEY|SECRET' || true)"

opencode_state="unknown"
if ssh -o BatchMode=yes -o ConnectTimeout=5 raptor.lab 'true' >/dev/null 2>&1; then
  opencode_state="raptor.lab reachable (config not modified by this script)"
else
  opencode_state="raptor.lab not reachable at manifest-capture time"
fi

printf '%s\n' "$redacted_env" > "${STATE_DIR}/rollback-manifest.env-snapshot"

python3 - "$MANIFEST" "$PRIOR_STACK" "$PRIOR_PROFILE" "$prior_image_digest" "$prior_port" "$PROFILE" "$CANARY_PORT" "$opencode_state" "${STATE_DIR}/rollback-manifest.env-snapshot" << 'PY'
import json, sys, datetime

manifest_path, prior_stack, prior_profile, prior_image_digest, prior_port, candidate_profile, canary_port, opencode_state, env_snapshot_path = sys.argv[1:10]

manifest = {
    "captured_at": datetime.datetime.utcnow().isoformat() + "Z",
    "prior_known_good": {
        "stack": prior_stack,
        "profile": prior_profile,
        "image_digest": prior_image_digest,
        "port": prior_port,
    },
    "candidate": {
        "stack": "radlight",
        "profile": candidate_profile,
        "canary_port": canary_port,
    },
    "effective_env_snapshot_file": env_snapshot_path,
    "client_state": {
        "opencode_pi_raptor_lab": opencode_state,
        "note": "OpenCode/PI endpoint and model id are not touched by this canary -- they still point at scar.lab:8080/v1 / scar-coder throughout. Nothing to restore on the client side unless a later promotion step changes that.",
    },
}
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)
print(f"wrote {manifest_path}")
PY
log_pass "Rollback manifest written: ${MANIFEST} (effective .env snapshot: ${STATE_DIR}/rollback-manifest.env-snapshot)"

# --- 2. stop current production stack cleanly (preserved, not removed) -----

log_step "Stopping current production stack ('${PRIOR_STACK}', container '${PRIOR_CONTAINER}') -- preserved for rollback, not removed"
export STACK_FLAVOR="$PRIOR_STACK"
export MODEL_PROFILE="$PRIOR_PROFILE"
if ! compose stop "$PRIOR_CONTAINER"; then
  log_fail "Could not stop ${PRIOR_CONTAINER}. Aborting before touching any VRAM the canary needs -- current production should be untouched."
  exit 1
fi
log_pass "${PRIOR_CONTAINER} stopped. GPU is now free for the Radlight canary."

# --- 3. deploy radlight on the canary port ----------------------------------

log_step "Deploying '${PROFILE}' on canary port ${CANARY_PORT}"
export API_PORT="$CANARY_PORT"
if DEPLOY_IS_RESTORE=0 "${SCRIPT_DIR}/deploy.sh" "$PROFILE"; then
  log_pass "Radlight canary '${PROFILE}' is up and passed validate-model.sh on port ${CANARY_PORT}."
  log_info "Next: run the correctness/long-context/DFlash2-equivalence/benchmark matrix against http://localhost:${CANARY_PORT}/v1 (see docs/runbook.md 'Radlight canary'), then scripts/promote-radlight.sh '${PROFILE}' only if every gate passes."
  exit 0
else
  log_fail "Radlight canary '${PROFILE}' failed to deploy/validate. deploy.sh's own restore-or-shutdown.sh should have already restored '${PRIOR_PROFILE}' (or fallen through to llama.cpp if that also failed -- see its output above)."
  log_step "Verifying production is actually being served again"
  if curl -fsS --max-time 10 http://localhost:8080/v1/models >/dev/null 2>&1; then
    log_pass "Production (:8080) is responding again."
  else
    log_fail "Production (:8080) is NOT responding. Manual intervention required immediately -- check scripts/status.sh and consider scripts/rollback.sh."
  fi
  exit 1
fi
