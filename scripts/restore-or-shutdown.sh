#!/usr/bin/env bash
# Shared failure-recovery logic: called by BOTH deploy.sh (if the newly
# recreated container never becomes healthy) and validate-model.sh (if
# guardrail checks fail). Ported near-verbatim from the llama.cpp repo's
# scripts/restore-or-shutdown.sh (same pattern, proven on this exact host) --
# centralized so both failure points get the same recovery behavior.
#
# This is the safety net the plan's autonomous-execution authorization
# (plan-radiance-vllm.md §25) depends on: with no human checkpoint at
# cutover, this mechanism is what keeps a bad deploy from becoming an
# extended outage.
#
# Usage: restore-or-shutdown.sh <failed-profile>
#
# If a prior validated profile is recorded in the state file (and it isn't
# the same one that just failed), re-deploys it. Otherwise brings the
# service down rather than leave a failed/unvalidated deploy running.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

log() { echo "[restore-or-shutdown] $*" >&2; }

[[ $# -eq 1 ]] || {
  echo "Usage: $(basename "$0") <failed-profile>" >&2
  exit 2
}
failed_profile="$1"
failed_stack="$(stack_for_profile "$failed_profile")"

# Brings down whichever stack just failed -- MUST use that stack's own
# compose file (a radlight failure needs compose.radlight.yaml, not
# compose.yaml) or `down` would silently no-op against the wrong file.
bring_down_failed_stack() {
  export STACK_FLAVOR="$failed_stack"
  export MODEL_PROFILE="$failed_profile"
  compose down
}

if [[ -f "$CURRENT_PROFILE_FILE" ]]; then
  prior_profile="$(load_current_profile)"
  if [[ "$prior_profile" != "$failed_profile" ]]; then
    prior_stack="$(load_current_stack)"
    log "attempting to restore prior known-good profile '$prior_profile' (stack: ${prior_stack})..."
    bring_down_failed_stack || log "warning: bringing down the failed stack (${failed_stack}) did not exit cleanly, continuing to restore attempt"
    if DEPLOY_IS_RESTORE=1 "$SCRIPT_DIR/deploy.sh" "$prior_profile"; then
      log "restore succeeded -- '$prior_profile' (stack: ${prior_stack}) is serving again. '$failed_profile' was NOT recorded as current."
      exit 0
    elif [[ "$failed_stack" == "radlight" ]]; then
      # Two-level rollback path (plan-radlight-integration §5): a radlight
      # canary/promotion failed AND restoring the radiance-baseline stack
      # it displaced also failed. This specific combination is the one
      # case the mission spec says should fall through to the FINAL
      # fallback automatically, without an operator invoking it by hand.
      log "ERROR: restore of Radiance-baseline profile '$prior_profile' also failed after a radlight failure."
      bring_down_failed_stack
      log "invoking the final fallback: scripts/rollback.sh (llama.cpp)"
      if "$SCRIPT_DIR/rollback.sh"; then
        log "final fallback succeeded: llama.cpp is serving again on the production port."
        exit 1 # still a failure of this deploy attempt, but the host is safely served
      else
        log "CRITICAL: final fallback (llama.cpp) ALSO failed to come up. Port 8080 may be unserved. Manual intervention required immediately: docker start llamacpp"
        exit 1
      fi
    else
      # A same-stack (radiance-baseline-to-radiance-baseline) restore
      # failure -- e.g. switching between fallback profiles. Preserves this
      # repo's original behavior: bring the service down and let the
      # operator decide on scripts/rollback.sh explicitly, rather than
      # silently starting llama.cpp for a failure mode that predates and is
      # unrelated to the radlight integration.
      log "ERROR: restore of '$prior_profile' also failed. Not auto-invoking the llama.cpp fallback (this failure did not involve the radlight stack) -- run scripts/rollback.sh manually if needed."
      bring_down_failed_stack
      exit 1
    fi
  else
    log "prior recorded profile is the same as the one that just failed -- nothing to restore to, bringing service down"
    bring_down_failed_stack
    exit 1
  fi
else
  log "no prior known-good deployment recorded -- bringing service down rather than leave a failed/unvalidated deploy running"
  bring_down_failed_stack
  exit 1
fi
