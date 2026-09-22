#!/usr/bin/env bash
# Configures OpenCode (CLI and Desktop share one config file) to use this
# deployment as a provider. Ported from the abandoned
# Containerized-VLLM-AMD-R9700 repo's configure-opencode.sh -- same
# surgical-merge / backup / strict-JSON-only design, adapted for this
# repo's profile shape and the stable served-model-name design (plan §14).
#
# Surgical merge: writes/updates provider["scar-vllm"] only. Everything
# else in the file is left as-is. Always backs up first. Refuses to touch
# a config that isn't valid strict JSON (e.g. hand-edited with // comments).
#
# Usage:
#   scripts/configure-opencode.sh [--endpoint local|lan|<url>] [--profile NAME] [--dry-run]
#   scripts/configure-opencode.sh --remove
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROVIDER_ID="scar-vllm"
PLACEHOLDER_API_KEY="local-no-auth-required" # pragma: allowlist secret -- not a secret, no auth on this server (plan §17/§25)

ENDPOINT_MODE="local"
PROFILE=""
DRY_RUN=0
REMOVE=0
FORCE=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--endpoint local|lan|<url>] [--profile NAME] [--dry-run] [--force]
       $(basename "$0") --remove

  --endpoint local|lan|<url>  local (default): http://localhost:<API_PORT>/v1
                              lan: http://\$(hostname):<API_PORT>/v1
                              <url>: used verbatim (must end in /v1)
  --profile NAME              Model profile (default: DEFAULT_MODEL_PROFILE from .env)
  --force                     Force rewrite even if already current
  --dry-run                   Print what would be written; touch nothing
  --remove                    Delete the "${PROVIDER_ID}" provider entry
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT_MODE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_fail "Unknown option: $1"; usage; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { log_fail "'jq' is required but not found on PATH."; exit 1; }
load_env

if [[ -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
  CONFIG_DIR="$OPENCODE_CONFIG_DIR"
elif command -v opencode >/dev/null 2>&1; then
  CONFIG_DIR="$(opencode debug paths 2>/dev/null | awk '$1=="config"{print $2}')"
fi
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/opencode}"

if [[ -f "${CONFIG_DIR}/opencode.jsonc" ]]; then
  CONFIG_PATH="${CONFIG_DIR}/opencode.jsonc"
elif [[ -f "${CONFIG_DIR}/opencode.json" ]]; then
  CONFIG_PATH="${CONFIG_DIR}/opencode.json"
else
  CONFIG_PATH="${CONFIG_DIR}/opencode.json"
fi

if [[ "$REMOVE" -eq 1 ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    log_warn "No OpenCode config found at ${CONFIG_PATH} -- nothing to remove."
  elif ! jq -e --arg pid "$PROVIDER_ID" '.provider[$pid] // empty' "$CONFIG_PATH" >/dev/null 2>&1; then
    log_warn "Provider '${PROVIDER_ID}' not present -- nothing to remove."
  else
    backup="${CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$CONFIG_PATH" "$backup"
    tmp="$(mktemp)"
    jq --arg pid "$PROVIDER_ID" 'del(.provider[$pid])' "$CONFIG_PATH" > "$tmp"
    mv "$tmp" "$CONFIG_PATH"
    log_pass "Removed provider '${PROVIDER_ID}' (backup: ${backup})"
  fi
  exit 0
fi

[[ -n "$PROFILE" ]] || PROFILE="${DEFAULT_MODEL_PROFILE:-$DEFAULT_MODEL_PROFILE_FALLBACK}"
PROFILE="$(resolve_profile_alias "$PROFILE")"
PROFILE_PATH="$(resolve_model_profile "$PROFILE")"

get_profile_var() { grep "^${1}=" "$PROFILE_PATH" | head -1 | cut -d= -f2-; }
SERVED_MODEL_NAME="$(get_profile_var SERVED_MODEL_NAME)"
MAX_MODEL_LEN="$(get_profile_var MAX_MODEL_LEN)"
[[ -n "$SERVED_MODEL_NAME" ]] || { log_fail "Profile ${PROFILE} has no SERVED_MODEL_NAME"; exit 1; }
[[ "$MAX_MODEL_LEN" =~ ^[0-9]+$ ]] || { log_fail "Profile ${PROFILE} has a non-numeric MAX_MODEL_LEN"; exit 1; }

# Label reflects whichever stack this profile actually deploys to, so it
# doesn't go stale the next time the sequential canary promotes a different
# stack (radiance-baseline <-> radlight; see stack_for_profile in common.sh).
case "$(stack_for_profile "$PROFILE")" in
  radlight) STACK_LABEL="Radlight" ;;
  *) STACK_LABEL="Radiance" ;;
esac
PROVIDER_LABEL="scar.lab ${STACK_LABEL} vLLM"

case "$ENDPOINT_MODE" in
  local) BASE_URL="http://localhost:${API_PORT:-8081}/v1" ;;
  lan|remote) BASE_URL="http://$(hostname):${API_PORT:-8081}/v1" ;;
  http://*|https://*) BASE_URL="$ENDPOINT_MODE" ;;
  *) log_fail "Unknown --endpoint value: '${ENDPOINT_MODE}'"; exit 1 ;;
esac

OUTPUT_LIMIT=$(( MAX_MODEL_LEN / 4 ))

NEW_PROVIDER="$(jq -n \
  --arg name "$PROVIDER_LABEL" \
  --arg baseURL "$BASE_URL" \
  --arg apiKey "$PLACEHOLDER_API_KEY" \
  --arg modelId "$SERVED_MODEL_NAME" \
  --arg modelName "${SERVED_MODEL_NAME} via ${STACK_LABEL} vLLM/scar.lab (max ${MAX_MODEL_LEN} ctx)" \
  --argjson context "$MAX_MODEL_LEN" \
  --argjson output "$OUTPUT_LIMIT" \
  '{
    npm: "@ai-sdk/openai-compatible",
    name: $name,
    options: { baseURL: $baseURL, apiKey: $apiKey },
    models: {
      ($modelId): {
        name: $modelName,
        tool_call: true,
        limit: { context: $context, output: $output }
      }
    }
  }')"

log_step "Profile: ${PROFILE}  ->  OpenCode model: ${PROVIDER_ID}/${SERVED_MODEL_NAME}"
log_info "Endpoint: ${BASE_URL}"
log_info "Config file: ${CONFIG_PATH}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_step "Dry run -- would write (nothing touched):"
  jq -n --arg pid "$PROVIDER_ID" --argjson prov "$NEW_PROVIDER" '{provider: {($pid): $prov}}'
  exit 0
fi

if [[ -f "$CONFIG_PATH" ]]; then
  if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    log_fail "${CONFIG_PATH} is not valid strict JSON (may contain comments). Refusing to auto-merge."
    log_info "Merge this block by hand instead:"
    jq -n --arg pid "$PROVIDER_ID" --argjson prov "$NEW_PROVIDER" '{provider: {($pid): $prov}}'
    exit 1
  fi
else
  mkdir -p "$CONFIG_DIR"
  printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$CONFIG_PATH"
  log_info "No existing OpenCode config found -- created a fresh one at ${CONFIG_PATH}"
fi

tmp="$(mktemp)"
jq --arg pid "$PROVIDER_ID" --argjson prov "$NEW_PROVIDER" '
  .provider = ((.provider // {}) + {($pid): $prov})
' "$CONFIG_PATH" > "$tmp"

if cmp -s "$CONFIG_PATH" "$tmp" && [[ "$FORCE" -eq 0 ]]; then
  rm -f "$tmp"
  log_pass "OpenCode config already up to date: ${CONFIG_PATH}"
else
  backup="${CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$CONFIG_PATH" "$backup"
  mv "$tmp" "$CONFIG_PATH"
  log_pass "Wrote provider '${PROVIDER_ID}' to ${CONFIG_PATH} (backup: ${backup})"
fi

if command -v opencode >/dev/null 2>&1; then
  log_step "Validating with 'opencode models'"
  if opencode models 2>/dev/null | grep -qF "${PROVIDER_ID}/${SERVED_MODEL_NAME}"; then
    log_pass "OpenCode sees ${PROVIDER_ID}/${SERVED_MODEL_NAME}"
  else
    log_warn "OpenCode CLI didn't list ${PROVIDER_ID}/${SERVED_MODEL_NAME} -- check ${CONFIG_PATH}"
  fi
else
  log_warn "opencode CLI not found on PATH -- skipped live validation."
fi

log_info "Test: opencode run --model ${PROVIDER_ID}/${SERVED_MODEL_NAME} \"say hi in one word\""
log_info "Rollback: scripts/configure-opencode.sh --remove"
