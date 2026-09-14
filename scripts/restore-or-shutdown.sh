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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[restore-or-shutdown] $*" >&2; }

[[ $# -eq 1 ]] || {
  echo "Usage: $(basename "$0") <failed-profile>" >&2
  exit 2
}
failed_profile="$1"

STATE_DIR="/var/lib/radiance-vllm/state"
STATE_FILE="$STATE_DIR/current-profile"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yaml" --env-file "$REPO_ROOT/.env")

if [[ -f "$STATE_FILE" ]]; then
  prior_profile="$(cat "$STATE_FILE")"
  if [[ "$prior_profile" != "$failed_profile" ]]; then
    log "attempting to restore prior known-good profile '$prior_profile'..."
    if DEPLOY_IS_RESTORE=1 "$SCRIPT_DIR/deploy.sh" "$prior_profile"; then
      log "restore succeeded -- '$prior_profile' is serving again. '$failed_profile' was NOT recorded as current."
      exit 0
    else
      log "ERROR: restore of '$prior_profile' also failed -- bringing radiance-vllm down rather than leave a failed/unhealthy container running under restart:unless-stopped"
      "${COMPOSE[@]}" down
      exit 1
    fi
  else
    log "prior recorded profile is the same as the one that just failed -- nothing to restore to, bringing service down"
    "${COMPOSE[@]}" down
    exit 1
  fi
else
  log "no prior known-good deployment recorded -- bringing service down rather than leave a failed/unvalidated deploy running"
  "${COMPOSE[@]}" down
  exit 1
fi
