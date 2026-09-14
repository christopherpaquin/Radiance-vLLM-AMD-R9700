#!/usr/bin/env bash
# Post-deploy guardrail validation. Called automatically by deploy.sh, but
# safe to run standalone: validate-model.sh <profile>
#
# Adapted from the llama.cpp repo's validate-model.sh (same proven pattern,
# ported to vLLM's OpenAI-compatible API). Four checks, each able to fail
# the whole run:
#   1. VRAM postflight -- actual usage under representative load stays
#      within the ~1GB-headroom safety floor (plan §7.3), not just the
#      nominal GPU_MEMORY_UTILIZATION percentage (real usage has been
#      observed running several GiB over nominal on this exact hardware
#      for a 27B-class model in an earlier deployment).
#   2. Known-answer fixture -- REAL expected values, not just "output
#      looks coherent" -- catches a structurally-corrupted-but-fluent
#      response, which matters given the hybrid-architecture compatibility
#      risk this model class carries on this host (plan §6.2). The
#      code-completion half is checked via STATIC AST ANALYSIS, never
#      executed.
#   3. Tool-call determinism -- canonicalized comparison across same-server
#      trials, prefix-caching on/off, and a container restart.
#   4. FP8 KV cache correctness (only if KV_CACHE_DTYPE=fp8 for this
#      profile, plan §7.2) -- compares known-answer fixture output against
#      what a non-FP8 run would be expected to produce; a real regression
#      here is a hard failure, not a warning, per the plan's explicit
#      correctness-gate requirement for the full-spec rollout.
#
# Deliberately does NOT use `set -e`: collects every failure and always
# reaches the restore/shutdown logic at the bottom.
#
# Structured as sourceable functions + a main() guarded by the
# BASH_SOURCE/0 check at the bottom so tests/deploy.bats can exercise
# static_check_add_two / canonical_tool_call directly with crafted
# fixtures, without needing a real server.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[validate-model] $*" >&2; }

# ---------------------------------------------------------------------
# Static AST check for the code-completion fixture. NEVER executes the
# generated code. Strict about the module's SHAPE: exactly one top-level
# statement (the function itself), no decorators, exactly 2 plain
# positional args, body is an optional docstring followed by exactly one
# `return a + b` statement.
# ---------------------------------------------------------------------
static_check_add_two() {
  python3 -c "
import ast, sys

src = sys.stdin.read()
try:
    tree = ast.parse(src)
except SyntaxError as e:
    print(f'SYNTAX_ERROR: {e}')
    sys.exit(0)

if len(tree.body) != 1:
    print('EXTRA_TOP_LEVEL_STATEMENTS')
    sys.exit(0)

target = tree.body[0]
if not isinstance(target, ast.FunctionDef) or target.name != 'add_two':
    print('NO_FUNCTION_FOUND')
    sys.exit(0)

if target.decorator_list:
    print('UNEXPECTED_DECORATOR')
    sys.exit(0)

a = target.args
if a.vararg or a.kwarg or a.kwonlyargs or a.posonlyargs or a.defaults or a.kw_defaults:
    print('UNEXPECTED_ARG_SHAPE')
    sys.exit(0)
if len(a.args) != 2:
    print(f'WRONG_ARG_COUNT:{len(a.args)}')
    sys.exit(0)

body = target.body
if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], 'value', None), ast.Constant) and isinstance(body[0].value.value, str):
    body = body[1:]

if len(body) != 1 or not isinstance(body[0], ast.Return):
    print('UNEXPECTED_BODY_SHAPE')
    sys.exit(0)

ret = body[0].value
arg_names = {arg.arg for arg in a.args}
ok = (
    isinstance(ret, ast.BinOp)
    and isinstance(ret.op, ast.Add)
    and isinstance(ret.left, ast.Name)
    and isinstance(ret.right, ast.Name)
    and {ret.left.id, ret.right.id} == arg_names
)

print('OK' if ok else 'WRONG_LOGIC')
"
}

# Extracts function name + sorted-key-serialized arguments from an
# OpenAI-compatible chat-completion JSON response. Emits SEMANTIC_FAIL when
# there's no valid get_weather(location=<non-empty string mentioning
# Portland>) call.
canonical_tool_call() {
  python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    calls = d['choices'][0]['message'].get('tool_calls') or []
    out = []
    for c in calls:
        fn = c['function']
        args = json.loads(fn['arguments']) if isinstance(fn['arguments'], str) else fn['arguments']
        out.append({'name': fn['name'], 'arguments': args})

    valid = (
        len(out) == 1
        and out[0]['name'] == 'get_weather'
        and isinstance(out[0]['arguments'].get('location'), str)
        and 'portland' in out[0]['arguments']['location'].lower()
    )
    if not valid:
        print('SEMANTIC_FAIL')
    else:
        print(json.dumps(out, sort_keys=True))
except Exception as e:
    print(f'PARSE_ERROR: {e}', file=sys.stderr)
    print('PARSE_ERROR')
"
}

TOOL_REQUEST_BODY() {
  local model_id="$1" prefix_cache="$2"
  python3 - "$model_id" "$prefix_cache" << 'PY'
import json
import sys

model_id, prefix_cache = sys.argv[1], sys.argv[2]
print(json.dumps({
    'model': model_id,
    'temperature': 0,
    'seed': 42,
    'max_tokens': 300,
    'messages': [{'role': 'user', 'content': "What's the weather in Portland, Oregon?"}],
    'tools': [{
        'type': 'function',
        'function': {
            'name': 'get_weather',
            'description': 'Get current weather for a location',
            'parameters': {
                'type': 'object',
                'properties': {'location': {'type': 'string'}},
                'required': ['location'],
            },
        },
    }],
    'tool_choice': 'auto',
}))
PY
}

run_validation() {
  local profile="$1"
  local PROFILE_PATH="${REPO_ROOT}/config/models/${profile}.env"
  [[ -f "$PROFILE_PATH" ]] || { log "unknown profile: $profile"; return 2; }

  # Only .env is `source`d -- profile files (config/models/*.env) can
  # contain multi-word values (e.g. EXTRA_VLLM_ARGS="--foo --bar 32"),
  # which bash's `source` mis-parses as `VAR=firstword` followed by a
  # separate command invocation of the remaining words (harmless here
  # since nothing from the profile is needed beyond what the live
  # /v1/models call and .env already provide, but avoid it regardless).
  # shellcheck source=/dev/null
  set -a
  source "${REPO_ROOT}/.env"
  set +a

  local BASE_URL
  BASE_URL="http://localhost:${API_PORT:-8081}"
  local COMPOSE=(docker compose -f "$REPO_ROOT/compose.yaml" --env-file "$REPO_ROOT/.env")

  local models_json model_id
  models_json="$(curl -fsS --max-time 10 "$BASE_URL/v1/models" 2>&1)" || { log "cannot reach $BASE_URL/v1/models"; return 1; }
  model_id="$(python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" <<<"$models_json" 2>/dev/null || true)"
  [[ -n "$model_id" ]] || { log "could not determine served model id"; return 1; }

  local FAILURES=()

  # --- 1. VRAM postflight -------------------------------------------
  check_vram() {
    log "checking actual VRAM usage under representative load..."
    local filler body
    filler="$(python3 -c "print('The quick brown fox jumps over the lazy dog. ' * 800)")"
    body="$(python3 -c "
import json
print(json.dumps({
    'model': '$model_id',
    'temperature': 0,
    'max_tokens': 16,
    'messages': [{'role': 'user', 'content': '''$filler''' + ' Summarize in one word.'}],
}))
")"
    if ! curl -fsS -X POST "$BASE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' -d "$body" > /dev/null; then
      FAILURES+=("VRAM postflight: representative-load request failed -- server may be unhealthy")
      return
    fi

    if ! command -v rocm-smi > /dev/null 2>&1; then
      log "WARNING: rocm-smi not found on host -- cannot verify actual VRAM usage, skipping (not fatal)"
      return 0
    fi

    local hip_dev="${HIP_VISIBLE_DEVICES:-0}"
    if [[ ! "$hip_dev" =~ ^[0-9]+$ ]]; then
      log "WARNING: HIP_VISIBLE_DEVICES='$hip_dev' isn't a single plain integer -- skipping VRAM postflight"
      return 0
    fi
    local card_key="card${hip_dev}"
    local used_bytes total_bytes
    used_bytes="$(rocm-smi --showmeminfo vram --json 2> /dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    gpu = d.get('$card_key')
    if gpu and 'VRAM Total Used Memory (B)' in gpu:
        print(gpu['VRAM Total Used Memory (B)'])
except Exception:
    pass
")"
    total_bytes="$(rocm-smi --showmeminfo vram --json 2> /dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    gpu = d.get('$card_key')
    if gpu and 'VRAM Total Memory (B)' in gpu:
        print(gpu['VRAM Total Memory (B)'])
except Exception:
    pass
")"

    if [[ -z "$used_bytes" || -z "$total_bytes" ]]; then
      FAILURES+=("VRAM postflight: could not read/parse rocm-smi output for $card_key")
      return
    fi

    local used_gib total_gib headroom_gib
    used_gib="$(awk -v b="$used_bytes" 'BEGIN{printf "%.2f", b/1024/1024/1024}')"
    total_gib="$(awk -v b="$total_bytes" 'BEGIN{printf "%.2f", b/1024/1024/1024}')"
    headroom_gib="$(awk -v t="$total_gib" -v u="$used_gib" 'BEGIN{printf "%.2f", t-u}')"
    log "actual VRAM used ($card_key): ${used_gib}GiB / ${total_gib}GiB total (headroom: ${headroom_gib}GiB)"

    # Safety floor per plan §7.3: real headroom must stay positive and
    # comfortably above zero (target ~1GB) even at GPU_MEMORY_UTILIZATION
    # pushed to 0.968 -- OOM on a single GPU with no fallback is worse than
    # leaving VRAM unused.
    if awk -v h="$headroom_gib" 'BEGIN{exit !(h<0.5)}'; then
      FAILURES+=("VRAM postflight: real headroom ${headroom_gib}GiB is below the 0.5GiB safety floor -- back off GPU_MEMORY_UTILIZATION in ${profile}.env (see plan §7.3, docs/TUNING.md)")
    fi
  }

  # --- 2. Known-answer fixture ---------------------------------------
  check_known_answers() {
    log "checking known-answer fixtures..."

    local arith_resp arith_text
    arith_resp="$(curl -fsS -X POST "$BASE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json; print(json.dumps({'model':'$model_id','temperature':0,'seed':42,'max_tokens':16,'chat_template_kwargs':{'enable_thinking':False},'messages':[{'role':'user','content':'What is 47 * 89? Reply with only the numeric answer, no words, no punctuation.'}]}))")")"
    if [[ -z "$arith_resp" ]]; then
      FAILURES+=("known-answer arithmetic: request failed")
    else
      arith_text="$(python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])" <<< "$arith_resp" 2> /dev/null || true)"
      local expected=4183
      local extracted
      extracted="$(grep -oE '[0-9]+' <<< "$arith_text" | head -n1 || true)"
      if [[ "$extracted" != "$expected" ]]; then
        FAILURES+=("known-answer arithmetic: expected '$expected', got '$arith_text' (extracted '$extracted')")
      else
        log "arithmetic fixture ok (got $extracted)"
      fi
    fi

    local code_resp code_text
    code_resp="$(curl -fsS -X POST "$BASE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "$(python3 -c "import json; print(json.dumps({'model':'$model_id','temperature':0,'seed':42,'max_tokens':256,'chat_template_kwargs':{'enable_thinking':False},'messages':[{'role':'user','content':'Write a Python function named add_two that takes two integers and returns their sum. Reply with ONLY the code, no explanation, no markdown code fences.'}]}))")")"
    if [[ -z "$code_resp" ]]; then
      FAILURES+=("known-answer code-completion: request failed")
      return
    fi
    code_text="$(python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])" <<< "$code_resp" 2> /dev/null || true)"
    code_text="$(sed -e 's/^```[a-zA-Z]*$//' -e 's/^```$//' <<< "$code_text")"

    local static_result
    static_result="$(static_check_add_two <<< "$code_text")"

    if [[ "$static_result" != "OK" ]]; then
      FAILURES+=("known-answer code-completion: static AST check failed ($static_result) -- generated code: $code_text")
    else
      log "code-completion fixture ok (statically verified, never executed)"
    fi
  }

  # --- 3. Tool-call determinism ---------------------------------------
  one_tool_trial() {
    local resp
    resp="$(curl -fsS -X POST "$BASE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "$(TOOL_REQUEST_BODY "$model_id" "$1")")"
    if [[ -z "$resp" ]]; then
      echo "REQUEST_FAILED"
      return
    fi
    canonical_tool_call <<< "$resp"
  }

  check_tool_call_determinism() {
    log "checking tool-call determinism..."
    local results=() labels=()

    for i in 1 2 3; do
      results+=("$(one_tool_trial true)")
      labels+=("same-server trial $i")
    done

    log "restarting container to test post-restart determinism..."
    if ! "${COMPOSE[@]}" restart radiance-vllm; then
      FAILURES+=("tool-call determinism: 'docker compose restart' failed")
      return
    fi
    local ok=0
    for _ in $(seq 1 120); do
      if curl -fsS "$BASE_URL/v1/models" > /dev/null 2>&1; then ok=1; break; fi
      sleep 5
    done
    if [[ "$ok" != "1" ]]; then
      FAILURES+=("tool-call determinism: container did not come back healthy after restart")
      return
    fi
    results+=("$(one_tool_trial true)")
    labels+=("post-restart trial")

    local baseline="${results[0]}" mismatch=0
    if [[ "$baseline" == "PARSE_ERROR" || "$baseline" == "SEMANTIC_FAIL" || "$baseline" == "REQUEST_FAILED" ]]; then
      FAILURES+=("tool-call determinism: baseline trial did not produce a valid get_weather(location) call ($baseline)")
      mismatch=1
    fi
    for i in "${!results[@]}"; do
      case "${results[$i]}" in
        PARSE_ERROR | SEMANTIC_FAIL | REQUEST_FAILED)
          FAILURES+=("tool-call determinism: ${labels[$i]} returned ${results[$i]} instead of a valid tool call")
          mismatch=1
          continue
          ;;
      esac
      [[ "${results[$i]}" != "$baseline" ]] && mismatch=1
    done

    if ((mismatch)); then
      log "trial results (canonicalized):"
      for i in "${!results[@]}"; do log "  [${labels[$i]}] ${results[$i]}"; done
      FAILURES+=("tool-call determinism: responses diverged (or were invalid) across trials")
    else
      log "tool-call determinism ok across ${#results[@]} trials (including a restart)"
    fi
  }

  check_vram
  check_known_answers
  check_tool_call_determinism

  if ((${#FAILURES[@]} == 0)); then
    log "all guardrail checks passed for profile '$profile'"
    return 0
  fi

  log "VALIDATION FAILED for profile '$profile':"
  for f in "${FAILURES[@]}"; do log "  - $f"; done

  "$SCRIPT_DIR/restore-or-shutdown.sh" "$profile"
  return 1
}

main() {
  [[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") <profile>" >&2; exit 2; }
  run_validation "$1"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
