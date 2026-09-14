#!/usr/bin/env bash
# Configures PI (~/.pi/agent/models.json on the host it runs on -- raptor.lab
# in this deployment) to use this server as a provider. New script -- no
# prior PI configurator existed in the abandoned vLLM repo (it only shipped
# configure-opencode.sh); see plan-radiance-observability.md §13.
#
# Same surgical-merge/backup/strict-JSON discipline as configure-opencode.sh.
# Run this ON THE HOST WHERE PI RUNS (raptor.lab), not on scar.lab, unless
# PI_CONFIG_DIR is overridden to point at a mounted/synced path.
#
# Usage:
#   scripts/configure-pi.sh [--endpoint <url>] [--profile NAME] [--dry-run]
#   scripts/configure-pi.sh --remove
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROVIDER_ID="scar-radiance-vllm"
PROVIDER_LABEL="scar.lab Radiance vLLM"

ENDPOINT="http://scar.lab:8081/v1"
PROFILE=""
DRY_RUN=0
REMOVE=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--endpoint <url>] [--profile NAME] [--dry-run]
       $(basename "$0") --remove

  --endpoint <url>   Full base URL, must end in /v1 (default: http://scar.lab:8081/v1)
  --profile NAME     Model profile (default: DEFAULT_MODEL_PROFILE from .env)
  --dry-run          Print what would be written; touch nothing
  --remove           Delete the "${PROVIDER_ID}" provider entry
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_fail "Unknown option: $1"; usage; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { log_fail "'jq' is required but not found on PATH."; exit 1; }
load_env

PI_CONFIG_DIR="${PI_CONFIG_DIR:-$HOME/.pi/agent}"
CONFIG_PATH="${PI_CONFIG_DIR}/models.json"

if [[ "$REMOVE" -eq 1 ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    log_warn "No PI config found at ${CONFIG_PATH} -- nothing to remove."
  elif ! jq -e --arg pid "$PROVIDER_ID" '.providers[$pid] // empty' "$CONFIG_PATH" >/dev/null 2>&1; then
    log_warn "Provider '${PROVIDER_ID}' not present -- nothing to remove."
  else
    backup="${CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$CONFIG_PATH" "$backup"
    tmp="$(mktemp)"
    jq --arg pid "$PROVIDER_ID" 'del(.providers[$pid])' "$CONFIG_PATH" > "$tmp"
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

OUTPUT_LIMIT=$(( MAX_MODEL_LEN / 4 ))

NEW_PROVIDER="$(jq -n \
  --arg name "$PROVIDER_LABEL" \
  --arg baseUrl "$ENDPOINT" \
  --arg modelId "$SERVED_MODEL_NAME" \
  --argjson context "$MAX_MODEL_LEN" \
  --argjson output "$OUTPUT_LIMIT" \
  '{
    name: $name,
    baseUrl: $baseUrl,
    api: "openai-completions",
    apiKey: "local-lab-no-key", # pragma: allowlist secret -- not a secret, no auth on this server (plan §17/§25)
    authHeader: true,
    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: false,
      maxTokensField: "max_tokens"
    },
    models: [
      {
        id: $modelId,
        name: $modelId,
        reasoning: true,
        input: ["text"],
        contextWindow: $context,
        maxTokens: $output,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
      }
    ]
  }')"

log_step "Profile: ${PROFILE}  ->  PI model: ${PROVIDER_ID}/${SERVED_MODEL_NAME}"
log_info "Endpoint: ${ENDPOINT}"
log_info "Config file: ${CONFIG_PATH}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_step "Dry run -- would write (nothing touched):"
  jq -n --arg pid "$PROVIDER_ID" --argjson prov "$NEW_PROVIDER" '{providers: {($pid): $prov}}'
  exit 0
fi

if [[ -f "$CONFIG_PATH" ]]; then
  if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    log_fail "${CONFIG_PATH} is not valid JSON. Refusing to auto-merge."
    exit 1
  fi
else
  mkdir -p "$PI_CONFIG_DIR"
  printf '{\n  "providers": {}\n}\n' > "$CONFIG_PATH"
  log_info "No existing PI config found -- created a fresh one at ${CONFIG_PATH}"
fi

tmp="$(mktemp)"
jq --arg pid "$PROVIDER_ID" --argjson prov "$NEW_PROVIDER" '
  .providers = ((.providers // {}) + {($pid): $prov})
' "$CONFIG_PATH" > "$tmp"

if cmp -s "$CONFIG_PATH" "$tmp"; then
  rm -f "$tmp"
  log_pass "PI config already up to date: ${CONFIG_PATH}"
else
  backup="${CONFIG_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$CONFIG_PATH" "$backup"
  mv "$tmp" "$CONFIG_PATH"
  log_pass "Wrote provider '${PROVIDER_ID}' to ${CONFIG_PATH} (backup: ${backup})"
fi

log_info "Rollback: scripts/configure-pi.sh --remove"
