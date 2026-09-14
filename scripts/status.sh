#!/usr/bin/env bash
# Reports current container/model/API/GPU state.
#
# Usage: scripts/status.sh
set -uo pipefail # not -e: show as much status as possible even if one check fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PROFILE="$(load_current_profile)"
export MODEL_PROFILE="$PROFILE"
load_env

echo "Model profile: ${PROFILE:-<none started via scripts/deploy.sh>}"

if [[ -n "$PROFILE" ]]; then
  PROFILE_PATH="${REPO_ROOT}/config/models/${PROFILE}.env"
  if [[ -f "$PROFILE_PATH" ]]; then
    get_profile_var() { grep "^${1}=" "$PROFILE_PATH" | head -1 | cut -d= -f2-; }
    echo "  Served model name:      $(get_profile_var SERVED_MODEL_NAME)"
    echo "  Max context length:     $(get_profile_var MAX_MODEL_LEN)"
    echo "  GPU memory utilization: $(get_profile_var GPU_MEMORY_UTILIZATION)"
    echo "  KV cache dtype:         $(get_profile_var KV_CACHE_DTYPE)"
    echo "  Spec decode args:       $(get_profile_var SPEC_DECODE_ARGS)"
  fi
fi

echo
echo "Container:"
if [[ -n "$PROFILE" ]]; then
  compose ps radiance-vllm 2>&1 | sed 's/^/  /'
  health="$(compose ps --format '{{.Health}}' radiance-vllm 2>/dev/null || true)"
  echo "  Health: ${health:-unknown}"
else
  echo "  (skipped -- no profile on record)"
fi

echo
echo "API:"
url="$(api_base_url)"
echo "  URL: ${url}"
if curl -fsS "${url}/v1/models" >/dev/null 2>&1; then
  log_pass "API responding at ${url}"
else
  log_warn "API not responding at ${url}"
fi

echo
echo "Port 8080 (production endpoint):"
if docker inspect llamacpp --format '{{.State.Status}}' >/dev/null 2>&1; then
  llamacpp_running="$(docker inspect llamacpp --format '{{.State.Running}}' 2>/dev/null)"
  echo "  llamacpp: running=${llamacpp_running}"
fi
if docker inspect radiance-vllm --format '{{.State.Status}}' >/dev/null 2>&1; then
  radiance_port="$(docker inspect radiance-vllm --format '{{range $p, $b := .NetworkSettings.Ports}}{{$p}}->{{(index $b 0).HostPort}} {{end}}' 2>/dev/null)"
  echo "  radiance-vllm ports: ${radiance_port:-none}"
fi

echo
echo "GPU:"
if command -v rocm-smi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  m="$(rocm-smi --showproductname --showuse --showmeminfo vram --showtemp --showpower --json 2>/dev/null | jq -c '.card0 // .[keys[0]] // empty')"
  if [[ -n "$m" ]]; then
    printf '%s\n' "$m" | jq -r '
      "  Model:       " + (.["Card Series"] // "unknown") + " (" + (.["GFX Version"] // "unknown") + ")",
      "  VRAM total:  " + ((.["VRAM Total Memory (B)"] | tonumber / 1073741824 * 100 | round) / 100 | tostring) + " GiB",
      "  VRAM used:   " + ((.["VRAM Total Used Memory (B)"] | tonumber / 1073741824 * 100 | round) / 100 | tostring) + " GiB",
      "  GPU util:    " + (.["GPU use (%)"] // "unknown") + "%",
      "  Temperature: " + (.["Temperature (Sensor edge) (C)"] // "unknown") + " C",
      "  Power:       " + (.["Average Graphics Package Power (W)"] // "unknown") + " W"
    '
  else
    log_warn "rocm-smi produced no parseable output"
  fi
else
  log_warn "rocm-smi/jq not both available for a GPU summary"
fi
