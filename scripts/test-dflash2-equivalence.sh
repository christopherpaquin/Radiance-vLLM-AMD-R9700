#!/usr/bin/env bash
# Formal DFlash2 speculative-decoding output-equivalence gate
# (plan-radlight-integration "Correctness" / "DFlash2 speculative
# decoding"): same prompts, same deterministic sampling config, DFlash2
# enabled vs. disabled, compare final generated output. DFlash2 cannot
# ship if deterministic output differs unexpectedly.
#
# Deploys config/models/qwen38-27b-radlight.env (DFlash2 ON) and
# qwen38-27b-radlight-nospec.env (DFlash2 OFF, otherwise identical --
# same target model, same context/KV/parser settings) in turn, on the
# canary port, runs a fixed battery of temperature=0/seed=42 prompts
# against each, and diffs the results. Comparison is on NORMALIZED
# COMPLETE OUTPUT (message content + canonicalized tool_calls), not raw
# token IDs -- this vLLM build's OpenAI-compatible endpoint doesn't
# return token IDs by default and the task explicitly allows either.
#
# Single-GPU VRAM exclusivity applies here too: this script stops
# whatever stack is currently running (recording it to restore
# afterward) for its entire duration, exactly like canary-radlight.sh.
#
# Usage: scripts/test-dflash2-equivalence.sh [canary-port]
set -uo pipefail # not -e: must reach the restore step on any failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
require_env_file

CANARY_PORT="${1:-8081}"
SPEC_PROFILE="qwen38-27b-radlight"
NOSPEC_PROFILE="qwen38-27b-radlight-nospec"
resolve_model_profile "$SPEC_PROFILE" >/dev/null
resolve_model_profile "$NOSPEC_PROFILE" >/dev/null

RESULTS_DIR="${REPO_ROOT}/benchmarks/results/dflash2-equivalence-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RESULTS_DIR"

PRIOR_PROFILE="$(load_current_profile)"
PRIOR_STACK="$(load_current_stack)"
if [[ -z "$PRIOR_PROFILE" ]]; then
  log_fail "No current known-good profile on record -- refusing to run with no verified restore target."
  exit 1
fi
log_info "Current known-good (restore target): profile='${PRIOR_PROFILE}' stack='${PRIOR_STACK}'"

# --- fixed deterministic prompt battery --------------------------------
# temperature=0, seed=42, chat_template_kwargs.enable_thinking=false on
# every prompt -- isolates the comparison to DFlash2's effect on the
# final answer, not reasoning-length variance (a much noisier source of
# nondeterminism, unrelated to speculative decoding, that would otherwise
# swamp the signal this gate is looking for).
build_prompt_files() {
  local dir="$1"
  mkdir -p "$dir"

  python3 -c "
import json
cases = [
 ('arithmetic', {'max_tokens':16}, [{'role':'user','content':'What is 47 * 89? Reply with only the numeric answer, no words, no punctuation.'}], None),
 ('code_add_two', {'max_tokens':256}, [{'role':'user','content':'Write a Python function named add_two that takes two integers and returns their sum. Reply with ONLY the code, no explanation, no markdown code fences.'}], None),
 ('code_palindrome', {'max_tokens':256}, [{'role':'user','content':'Write a Python function named is_palindrome that checks if a string is a palindrome, ignoring case and spaces. Reply with ONLY the code, no explanation, no markdown code fences.'}], None),
 ('reasoning_binary_search', {'max_tokens':200}, [{'role':'user','content':'Explain, in exactly 3 sentences, how binary search works.'}], None),
 ('json_object', {'max_tokens':64}, [{'role':'user','content':'Return a JSON object with keys name (string, value test) and value (integer, value 42). Reply with ONLY the JSON, no explanation.'}], None),
 ('tool_call_weather', {'max_tokens':300}, [{'role':'user','content':\"What's the weather in Portland, Oregon?\"}],
   [{'type':'function','function':{'name':'get_weather','description':'Get current weather for a location','parameters':{'type':'object','properties':{'location':{'type':'string'}},'required':['location']}}}]),
]
for name, extra, messages, tools in cases:
    body = {
        'model': 'scar-coder',
        'temperature': 0,
        'seed': 42,
        'chat_template_kwargs': {'enable_thinking': False},
        'messages': messages,
    }
    body.update(extra)
    if tools:
        body['tools'] = tools
        body['tool_choice'] = 'auto'
    with open(f'$dir/{name}.json', 'w') as f:
        json.dump(body, f)
"
}

PROMPTS_DIR="${RESULTS_DIR}/prompts"
build_prompt_files "$PROMPTS_DIR"

# Extracts a normalized comparison string from a chat-completion response:
# content (if any) + canonicalized, sorted-key tool_calls (if any).
normalize_response() {
  python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    msg = d['choices'][0]['message']
    content = (msg.get('content') or '').strip()
    calls = msg.get('tool_calls') or []
    norm_calls = []
    for c in calls:
        fn = c['function']
        args = fn['arguments']
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except Exception:
                pass
        norm_calls.append({'name': fn['name'], 'arguments': args})
    print(json.dumps({'content': content, 'tool_calls': norm_calls}, sort_keys=True))
except Exception as e:
    print(json.dumps({'error': str(e)}))
"
}

run_battery() {
  local base_url="$1" out_dir="$2"
  mkdir -p "$out_dir"
  local f name resp
  for f in "$PROMPTS_DIR"/*.json; do
    name="$(basename "$f" .json)"
    resp="$(curl -fsS --max-time 60 -X POST "${base_url}/v1/chat/completions" -H 'Content-Type: application/json' -d @"$f")"
    printf '%s\n' "$resp" > "${out_dir}/${name}.raw.json"
    normalize_response <<<"$resp" > "${out_dir}/${name}.normalized.json"
  done
}

deploy_and_capture() {
  local profile="$1" out_dir="$2"
  local stack container
  stack="$(stack_for_profile "$profile")"
  container="$(container_name_for_stack "$stack")"

  log_step "Deploying '${profile}' on canary port ${CANARY_PORT}"
  resolve_gpu_gids
  export STACK_FLAVOR="$stack"
  export MODEL_PROFILE="$profile"
  export API_PORT="$CANARY_PORT"

  if ! compose up -d --force-recreate; then
    log_fail "docker compose up failed for '${profile}'."
    return 1
  fi

  local elapsed=0 timeout=2400 interval=10
  until curl -fsS "http://localhost:${CANARY_PORT}/v1/models" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      log_fail "'${profile}' did not become healthy within ${timeout}s."
      return 1
    fi
    local state
    state="$(compose ps --format '{{.State}}' "$container" 2>/dev/null || true)"
    if [[ "$state" == "exited" || "$state" == "dead" ]]; then
      log_fail "'${profile}' container exited unexpectedly. Logs:"
      compose logs --tail=100 "$container" >&2 || true
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_pass "'${profile}' healthy at :${CANARY_PORT}"

  run_battery "http://localhost:${CANARY_PORT}" "$out_dir"

  compose stop "$container" 2>/dev/null || true
}

restore_prior() {
  log_step "Restoring prior known-good ('${PRIOR_PROFILE}', stack '${PRIOR_STACK}')"
  export STACK_FLAVOR="$PRIOR_STACK"
  export MODEL_PROFILE="$PRIOR_PROFILE"
  export API_PORT=8080
  resolve_gpu_gids
  if DEPLOY_IS_RESTORE=1 "${SCRIPT_DIR}/deploy.sh" "$PRIOR_PROFILE"; then
    save_current_profile "$PRIOR_PROFILE"
    log_pass "Restored '${PRIOR_PROFILE}' on :8080."
  else
    log_fail "Restore of '${PRIOR_PROFILE}' failed -- falling through to restore-or-shutdown.sh."
    "${SCRIPT_DIR}/restore-or-shutdown.sh" "$PRIOR_PROFILE"
  fi
}

log_step "Stopping current stack ('${PRIOR_STACK}') -- GPU exclusivity"
export STACK_FLAVOR="$PRIOR_STACK"
export MODEL_PROFILE="$PRIOR_PROFILE"
compose stop "$(container_name_for_stack "$PRIOR_STACK")" 2>/dev/null || true

SPEC_DIR="${RESULTS_DIR}/spec-on"
NOSPEC_DIR="${RESULTS_DIR}/spec-off"

overall_ok=1
if ! deploy_and_capture "$SPEC_PROFILE" "$SPEC_DIR"; then
  overall_ok=0
fi
if [[ "$overall_ok" -eq 1 ]] && ! deploy_and_capture "$NOSPEC_PROFILE" "$NOSPEC_DIR"; then
  overall_ok=0
fi

restore_prior

if [[ "$overall_ok" -ne 1 ]]; then
  log_fail "One or both deploys failed -- cannot compare. See logs above. Results (partial) under ${RESULTS_DIR}"
  exit 1
fi

log_step "Comparing normalized outputs (DFlash2 ON vs. OFF)"
mismatch=0
declare -a case_names=()
for f in "$PROMPTS_DIR"/*.json; do
  case_names+=("$(basename "$f" .json)")
done

for name in "${case_names[@]}"; do
  spec_norm="$(cat "${SPEC_DIR}/${name}.normalized.json" 2>/dev/null || echo MISSING)"
  nospec_norm="$(cat "${NOSPEC_DIR}/${name}.normalized.json" 2>/dev/null || echo MISSING)"
  if [[ "$spec_norm" == "$nospec_norm" ]]; then
    log_pass "${name}: identical"
  else
    log_fail "${name}: DIVERGED"
    log_info "  DFlash2 ON:  ${spec_norm}"
    log_info "  DFlash2 OFF: ${nospec_norm}"
    mismatch=1
  fi
done

summary_file="${RESULTS_DIR}/summary.json"
python3 -c "
import json
print(json.dumps({'mismatch': $mismatch, 'cases': ${#case_names[@]}, 'results_dir': '$RESULTS_DIR'}, indent=2))
" | tee "$summary_file"

if [[ "$mismatch" -eq 1 ]]; then
  log_fail "DFlash2 output-equivalence gate FAILED -- deterministic output diverged. DFlash2 must not ship until this is resolved. Full results: ${RESULTS_DIR}"
  exit 1
fi
log_pass "DFlash2 output-equivalence gate PASSED -- identical output with speculative decoding on vs. off across ${#case_names[@]} cases. Full results: ${RESULTS_DIR}"
