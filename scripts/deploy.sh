#!/usr/bin/env bash
# One-click (re)deploy of a model profile via docker compose.
#
# Usage: deploy.sh <profile>
#
# Order of operations, each one failing loudly and stopping before the
# next: profile resolution -> numeric GPU GID resolution -> docker compose
# up -> wait for /v1/models -> validate-model.sh (VRAM postflight,
# known-answer fixture, tool-call determinism guardrail).
#
# Internal: when validate-model.sh or restore-or-shutdown.sh needs to
# restore a prior known-good profile after a failed deploy, they re-invoke
# this script with DEPLOY_IS_RESTORE=1 set, which skips the state-file
# update and skips re-running validate-model.sh's own restore path again
# (no recursion). Ported pattern from the llama.cpp repo's deploy.sh,
# proven on this exact host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { log_fail "Usage: $(basename "$0") <model-profile> [--canary-port PORT]"; log_info "Available profiles:"; list_model_profiles | sed 's/^/  - /' >&2; exit 1; }
PROFILE="$(resolve_profile_alias "$PROFILE")"
PROFILE_PATH="$(resolve_model_profile "$PROFILE")"
require_env_file

STACK="$(stack_for_profile "$PROFILE")"
export STACK_FLAVOR="$STACK"
CONTAINER="$(container_name_for_stack "$STACK")"

if grep -q '^MODEL_ID=REPLACE_ME' "$PROFILE_PATH"; then
  log_fail "Profile '${PROFILE}' has a placeholder MODEL_ID (bake-off not yet run). Resolve it in ${PROFILE_PATH} before deploying, or use a fallback profile: qwen25-coder-14b, qwen3-coder-30b-a3b"
  exit 1
fi

log_step "Deploying profile '${PROFILE}' (stack: ${STACK}, container: ${CONTAINER})"
log_info "Profile settings (${PROFILE_PATH}):"
grep -vE '^\s*(#|$)' "$PROFILE_PATH" | sed 's/^/  /' >&2

resolve_gpu_gids

export MODEL_PROFILE="$PROFILE"

# A canary deploy of the stack NOT currently in production must not bind to
# .env's persisted API_PORT if that's already 8080 for the OTHER stack --
# scripts/canary-radlight.sh exports API_PORT=8081 before calling this
# script for exactly that reason. Only cutover.sh ever persists
# API_PORT=8080 to .env (the one step that takes over the production port).

log_step "Starting Docker Compose"
if ! compose up -d --force-recreate; then
  log_fail "docker compose up failed. See the raw Docker/Compose output above."
  exit 1
fi

load_env
url="$(api_base_url)"
log_step "Container starting. API will be available at: ${url}"

log_step "Waiting for API to become healthy (up to 40 minutes -- 27B cold load is slow; a Radlight canary's first run also compiles native kernels)"
elapsed=0
timeout=2400
interval=10
until curl -fsS "${url}/v1/models" >/dev/null 2>&1; do
  if [[ "$elapsed" -ge "$timeout" ]]; then
    log_fail "API did not become healthy within ${timeout}s."
    if [[ "${DEPLOY_IS_RESTORE:-0}" == "1" ]]; then
      log_fail "restore deploy of '${PROFILE}' itself failed to become healthy"
      exit 1
    fi
    "${SCRIPT_DIR}/restore-or-shutdown.sh" "$PROFILE"
    exit 1
  fi
  state="$(compose ps --format '{{.State}}' "$CONTAINER" 2>/dev/null || true)"
  if [[ "$state" == "exited" || "$state" == "dead" ]]; then
    log_fail "Container exited unexpectedly while waiting for health. Logs:"
    compose logs --tail=150 "$CONTAINER" >&2 || true
    if [[ "${DEPLOY_IS_RESTORE:-0}" == "1" ]]; then
      exit 1
    fi
    "${SCRIPT_DIR}/restore-or-shutdown.sh" "$PROFILE"
    exit 1
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done
log_pass "API healthy at ${url}"

if [[ "${DEPLOY_IS_RESTORE:-0}" == "1" ]]; then
  log_info "restore deploy complete (skipping validate-model.sh's own restore path to avoid recursion)"
  exit 0
fi

log_step "Running guardrail validation"
if "${SCRIPT_DIR}/validate-model.sh" "$PROFILE"; then
  save_current_profile "$PROFILE"
  log_pass "Profile '${PROFILE}' validated and recorded as current known-good deployment"
else
  log_fail "validate-model.sh failed for '${PROFILE}' -- it will attempt to restore the prior known-good profile"
  exit 1
fi
