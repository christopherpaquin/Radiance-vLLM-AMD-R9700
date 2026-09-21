#!/usr/bin/env bash
# Runs one repeatable benchmark measurement against the currently running
# vLLM server and records it under benchmarks/results/.
#
# This is deliberately simple: one (concurrency x prompt-size) point per
# invocation. Loop over it externally for a full matrix — see
# docs/BENCHMARKING.md.
#
# Design notes (see docs/BENCHMARKING.md for the full rationale):
#   - TTFT and throughput/latency are measured in two separate phases, each
#     with its own wall-clock, rather than pairing a streaming + non-
#     streaming request per "request" and sharing one wall-clock. Sharing a
#     wall-clock across both would silently dilute the throughput number
#     (it would include time spent on a request whose tokens aren't counted).
#   - TTFT (phase 1) is measured via streaming requests using curl's own
#     time_starttransfer timing (time to first byte of the SSE stream), not
#     server-side instrumentation. It's an approximation, not a lab-grade
#     measurement.
#   - Token counts and throughput/latency (phase 2) come from non-streaming
#     requests, using the API's own `usage` field as ground truth (rather
#     than trying to count tokens locally).
#   - Prompt "size" is an approximate target (filler text sized by word
#     count); the actual prompt_tokens from the API response is what gets
#     recorded.
#
# Usage:
#   scripts/benchmark.sh <model-profile> [--concurrency N] [--prompt-tokens N] [--max-tokens N]
#
# Requires: jq, curl, bc
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

for tool in jq curl bc; do
  command -v "$tool" >/dev/null 2>&1 || { log_fail "'$tool' is required but not found on PATH."; exit 1; }
done

CONCURRENCY=1
PROMPT_TOKENS=512
MAX_TOKENS=256
PROFILE=""

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <model-profile> [--concurrency N] [--prompt-tokens N] [--max-tokens N]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --prompt-tokens) PROMPT_TOKENS="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) log_fail "Unknown option: $1"; usage; exit 1 ;;
    *)
      if [[ -n "$PROFILE" ]]; then log_fail "Multiple profiles given"; usage; exit 1; fi
      PROFILE="$1"; shift ;;
  esac
done

[[ -n "$PROFILE" ]] || { usage; exit 1; }
PROFILE="$(resolve_profile_alias "$PROFILE")"
PROFILE_PATH="$(resolve_model_profile "$PROFILE")"
export MODEL_PROFILE="$PROFILE"
STACK="$(stack_for_profile "$PROFILE")"
export STACK_FLAVOR="$STACK"
CONTAINER="$(container_name_for_stack "$STACK")"
load_env

url="$(api_base_url)"
if ! models_json="$(curl -fsS --max-time 10 "${url}/v1/models" 2>&1)"; then
  log_fail "vLLM API not reachable at ${url} (${models_json}). Is it running? scripts/start.sh ${PROFILE}"
  exit 1
fi
model_id="$(printf '%s' "$models_json" | jq -r '.data[0].id // empty')"
[[ -n "$model_id" ]] || { log_fail "Could not determine served model id from ${url}/v1/models"; exit 1; }

# --- container / environment metadata ----------------------------------------

vllm_version="$(compose exec -T "$CONTAINER" python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null | tr -d '\r' || true)"
[[ -n "$vllm_version" ]] || vllm_version="unknown"

rocm_version="$(compose exec -T "$CONTAINER" python3 -c 'import torch; print(torch.version.hip)' 2>/dev/null | tr -d '\r' || true)"
[[ -n "$rocm_version" ]] || rocm_version="unknown"

vram_used_mb="unknown"
if command -v rocm-smi >/dev/null 2>&1; then
  vram_used_mb="$(rocm-smi --showmeminfo vram --json 2>/dev/null | jq -r '[.. | objects | select(has("VRAM Total Used Memory (B)")) | (."VRAM Total Used Memory (B)" | tonumber / 1048576)] | first // "unknown"' 2>/dev/null || echo unknown)"
fi

# --- build an approximately-sized prompt --------------------------------------

# Rough heuristic: ~1.3 tokens per English word. Ground truth is whatever the
# API reports back in usage.prompt_tokens.
words_needed=$(( PROMPT_TOKENS * 10 / 13 ))
filler="Explain, in careful technical detail, how a modern operating system schedules processes across multiple CPU cores while balancing fairness and throughput."
prompt=""
while [[ "$(printf '%s' "$prompt" | wc -w)" -lt "$words_needed" ]]; do
  prompt="${prompt} ${filler}"
done

# --- one request: streaming, for TTFT -----------------------------------------

run_streaming_request() {
  local payload
  payload="$(jq -n --arg m "$model_id" --arg p "$prompt" --argjson mt "$MAX_TOKENS" \
    '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $mt, temperature: 0, stream: true}')"
  curl -s -o /dev/null -w '%{time_starttransfer}\n' --max-time 120 \
    -X POST "${url}/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$payload"
}

# --- one request: non-streaming, for token counts + total latency ------------

run_full_request() {
  local payload out
  payload="$(jq -n --arg m "$model_id" --arg p "$prompt" --argjson mt "$MAX_TOKENS" \
    '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $mt, temperature: 0}')"
  out="$(curl -s --max-time 120 -w '\n%{time_total}' \
    -X POST "${url}/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$payload")"
  printf '%s' "$out"
}

log_step "Running ${CONCURRENCY} concurrent request(s), target prompt ~${PROMPT_TOKENS} tokens, max_tokens=${MAX_TOKENS}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Phase 1: TTFT only (streaming, response body discarded). Kept separate from
# phase 2 so its wall-clock never dilutes the throughput number below.
log_step "Phase 1/2: TTFT (streaming)"
pids=()
for i in $(seq 1 "$CONCURRENCY"); do
  ( run_streaming_request > "${tmpdir}/${i}.ttft" ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

# Phase 2: throughput/latency (non-streaming). wall_clock here covers only
# this phase, so aggregate_tokens_per_sec isn't diluted by phase 1's time.
log_step "Phase 2/2: throughput/latency (non-streaming)"
batch_start="$(date +%s.%N)"
pids=()
for i in $(seq 1 "$CONCURRENCY"); do
  (
    full_out="$(run_full_request)"
    total_time="$(printf '%s' "$full_out" | tail -1)"
    body="$(printf '%s' "$full_out" | sed '$d')"
    printf '%s\n' "$body" > "${tmpdir}/${i}.json"
    printf '%s\n' "$total_time" > "${tmpdir}/${i}.total_time"
  ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
batch_end="$(date +%s.%N)"
wall_clock="$(echo "$batch_end - $batch_start" | bc)"

# --- aggregate -----------------------------------------------------------

total_prompt_tokens=0
total_completion_tokens=0
sum_ttft=0
sum_latency=0
ok_count=0
ttft_count=0

for i in $(seq 1 "$CONCURRENCY"); do
  ttft_file="${tmpdir}/${i}.ttft"
  if [[ -s "$ttft_file" ]]; then
    sum_ttft="$(echo "$sum_ttft + $(cat "$ttft_file")" | bc)"
    ttft_count=$((ttft_count + 1))
  fi

  f="${tmpdir}/${i}.json"
  [[ -s "$f" ]] || continue
  pt="$(jq -r '.usage.prompt_tokens // empty' "$f" 2>/dev/null || true)"
  ct="$(jq -r '.usage.completion_tokens // empty' "$f" 2>/dev/null || true)"
  [[ -n "$pt" && -n "$ct" ]] || { log_warn "Request $i did not return usage — skipping from aggregates. Response: $(cat "$f")"; continue; }
  total_prompt_tokens=$((total_prompt_tokens + pt))
  total_completion_tokens=$((total_completion_tokens + ct))
  sum_latency="$(echo "$sum_latency + $(cat "${tmpdir}/${i}.total_time")" | bc)"
  ok_count=$((ok_count + 1))
done

if [[ "$ok_count" -eq 0 ]]; then
  log_fail "No successful requests — nothing to record."
  exit 1
fi

avg_ttft="$(echo "scale=4; $sum_ttft / ${ttft_count:-1}" | bc)"
avg_latency="$(echo "scale=4; $sum_latency / $ok_count" | bc)"
avg_prompt_tokens=$((total_prompt_tokens / ok_count))
avg_completion_tokens=$((total_completion_tokens / ok_count))
aggregate_tokens_per_sec="$(echo "scale=2; $total_completion_tokens / $wall_clock" | bc)"

# --- profile metadata ----------------------------------------------------

# shellcheck disable=SC1090
profile_vars="$(grep -vE '^\s*(#|$)' "$PROFILE_PATH")"
get_profile_var() { printf '%s\n' "$profile_vars" | grep "^${1}=" | head -1 | cut -d= -f2-; }

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_dir="${REPO_ROOT}/benchmarks/results"
mkdir -p "$results_dir"
out_file="${results_dir}/$(date -u +%Y%m%dT%H%M%SZ)_${PROFILE}_c${CONCURRENCY}_p${PROMPT_TOKENS}.json"

jq -n \
  --arg timestamp "$timestamp" \
  --arg model_profile "$PROFILE" \
  --arg stack "$STACK" \
  --arg served_model "$model_id" \
  --arg model_id_config "$(get_profile_var MODEL_ID)" \
  --arg vllm_version "$vllm_version" \
  --arg rocm_version "$rocm_version" \
  --arg container_image "$([[ "$STACK" == "radlight" ]] && echo "${RADLIGHT_BASE_IMAGE:-unknown}" || echo "${VLLM_IMAGE:-unknown}")" \
  --arg max_model_len "$(get_profile_var MAX_MODEL_LEN)" \
  --arg quantization "$(get_profile_var QUANTIZATION)" \
  --arg kv_cache_dtype "$(get_profile_var KV_CACHE_DTYPE)" \
  --arg gpu_memory_utilization "$(get_profile_var GPU_MEMORY_UTILIZATION)" \
  --arg vram_used_mb "$vram_used_mb" \
  --argjson concurrency "$CONCURRENCY" \
  --argjson requested_prompt_tokens "$PROMPT_TOKENS" \
  --argjson max_tokens "$MAX_TOKENS" \
  --argjson ok_count "$ok_count" \
  --argjson avg_prompt_tokens "$avg_prompt_tokens" \
  --argjson avg_completion_tokens "$avg_completion_tokens" \
  --argjson avg_ttft_seconds "$avg_ttft" \
  --argjson avg_latency_seconds "$avg_latency" \
  --argjson aggregate_tokens_per_sec "$aggregate_tokens_per_sec" \
  --argjson wall_clock_seconds "$wall_clock" \
  '{
    timestamp: $timestamp,
    model_profile: $model_profile,
    stack: $stack,
    served_model: $served_model,
    model_id: $model_id_config,
    vllm_version: $vllm_version,
    rocm_version: $rocm_version,
    container_image: $container_image,
    max_model_len: $max_model_len,
    quantization: $quantization,
    kv_cache_dtype: $kv_cache_dtype,
    gpu_memory_utilization: $gpu_memory_utilization,
    vram_used_mb: $vram_used_mb,
    concurrency: $concurrency,
    successful_requests: $ok_count,
    requested_prompt_tokens: $requested_prompt_tokens,
    avg_prompt_tokens: $avg_prompt_tokens,
    max_tokens: $max_tokens,
    avg_completion_tokens: $avg_completion_tokens,
    avg_ttft_seconds: $avg_ttft_seconds,
    avg_latency_seconds: $avg_latency_seconds,
    aggregate_tokens_per_sec: $aggregate_tokens_per_sec,
    wall_clock_seconds: $wall_clock_seconds
  }' | tee "$out_file"

# Flat CSV index alongside the per-run JSON files, for quick spreadsheet use.
csv_file="${results_dir}/results.csv"
if [[ ! -f "$csv_file" ]]; then
  echo "timestamp,model_profile,stack,served_model,vllm_version,rocm_version,max_model_len,quantization,kv_cache_dtype,gpu_memory_utilization,vram_used_mb,concurrency,avg_prompt_tokens,max_tokens,avg_completion_tokens,avg_ttft_seconds,avg_latency_seconds,aggregate_tokens_per_sec" > "$csv_file"
fi
echo "${timestamp},${PROFILE},${STACK},${model_id},${vllm_version},${rocm_version},$(get_profile_var MAX_MODEL_LEN),$(get_profile_var QUANTIZATION),$(get_profile_var KV_CACHE_DTYPE),$(get_profile_var GPU_MEMORY_UTILIZATION),${vram_used_mb},${CONCURRENCY},${avg_prompt_tokens},${MAX_TOKENS},${avg_completion_tokens},${avg_ttft},${avg_latency},${aggregate_tokens_per_sec}" >> "$csv_file"

log_pass "Results written to ${out_file} and appended to ${csv_file}"
