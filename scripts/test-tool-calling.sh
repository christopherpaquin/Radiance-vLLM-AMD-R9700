#!/usr/bin/env bash
# Repeatable tool-calling verification matrix against the currently running
# vLLM server. A model starting and serving /v1/models is not evidence tool
# calling actually works — this exists because this repo has already hit a
# real, documented case (qwen3_coder's runaway "!!!!" bug on long inputs)
# where a tool-call parser looked fine on a trivial request and broke on
# real agentic usage. Six scenarios, each checking for the specific failure
# modes that matter for OpenCode: malformed JSON in tool_calls[].function
# .arguments, a tool call leaking into message.content as plain text instead
# of the structured tool_calls field, an empty/missing tool_calls array when
# one was expected, and (for streaming) a call that never assembles into a
# complete, parseable tool_calls entry across chunks.
#
# Usage:
#   scripts/test-tool-calling.sh <model-profile>
#
# Requires: jq, curl
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

for tool in jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { log_fail "'$tool' is required but not found on PATH."; exit 1; }
done

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { log_fail "Usage: $(basename "$0") <model-profile>"; exit 1; }
PROFILE="$(resolve_profile_alias "$PROFILE")"
resolve_model_profile "$PROFILE" >/dev/null
export MODEL_PROFILE="$PROFILE"
load_env

url="$(api_base_url)"
if ! models_json="$(curl -fsS --max-time 10 "${url}/v1/models" 2>&1)"; then
  log_fail "vLLM API not reachable at ${url} (${models_json}). Is it running? scripts/start.sh ${PROFILE}"
  exit 1
fi
model_id="$(printf '%s' "$models_json" | jq -r '.data[0].id // empty')"
[[ -n "$model_id" ]] || { log_fail "Could not determine served model id from ${url}/v1/models"; exit 1; }
log_step "Testing tool calling against served model '${model_id}' at ${url}"

TOOLS_JSON='[
  {
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get the current weather for a city.",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {"type": "string", "description": "City name"},
          "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
        },
        "required": ["location"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "list_files",
      "description": "List files in a directory.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Directory path"}
        },
        "required": ["path"]
      }
    }
  }
]'

results_pass=0
results_fail=0
declare -a fail_names=()

# Sends one non-streaming chat completion. $1 = JSON messages array,
# $2 = "true"/"false" whether tools should be attached.
chat() {
  local messages="$1" with_tools="$2" tools_arg="null"
  [[ "$with_tools" == "true" ]] && tools_arg="$TOOLS_JSON"
  jq -n --arg m "$model_id" --argjson msgs "$messages" --argjson tools "$tools_arg" \
    '{model: $m, messages: $msgs, tools: $tools, tool_choice: (if $tools == null then null else "auto" end), max_tokens: 300, temperature: 0}' \
    | curl -fsS --max-time 60 -X POST "${url}/v1/chat/completions" -H 'Content-Type: application/json' -d @-
}

# Checks a chat-completion response for a well-formed tool call.
# Fails on: no tool_calls when finish_reason=="tool_calls", tool_calls
# present but function.arguments isn't valid JSON, or content non-empty
# alongside tool_calls (a common parser-leak symptom: the call partially
# rendered as text instead of being fully extracted).
check_tool_call() {
  local resp="$1" min_calls="${2:-1}"
  local finish_reason n_calls content
  finish_reason="$(jq -r '.choices[0].finish_reason // empty' <<<"$resp")"
  n_calls="$(jq '.choices[0].message.tool_calls // [] | length' <<<"$resp")"
  content="$(jq -r '.choices[0].message.content // ""' <<<"$resp")"

  if [[ "$n_calls" -lt "$min_calls" ]]; then
    log_fail "  expected >=${min_calls} tool_calls, got ${n_calls}. finish_reason=${finish_reason}"
    log_fail "  content: $(printf '%s' "$content" | head -c 300)"
    return 1
  fi

  local i args
  for ((i = 0; i < n_calls; i++)); do
    args="$(jq -r ".choices[0].message.tool_calls[$i].function.arguments // \"\"" <<<"$resp")"
    if ! jq -e . >/dev/null 2>&1 <<<"$args"; then
      log_fail "  tool_calls[$i].function.arguments is not valid JSON: ${args}"
      return 1
    fi
    if [[ -z "$(jq -r ".choices[0].message.tool_calls[$i].function.name // \"\"" <<<"$resp")" ]]; then
      log_fail "  tool_calls[$i] has an empty function name"
      return 1
    fi
  done

  if [[ -n "$content" && "$content" != "null" ]]; then
    # A non-empty content alongside tool_calls isn't automatically wrong (some
    # models emit a short lead-in), but a content field that itself contains
    # what looks like a tool-call marker means the parser leaked raw text
    # instead of fully extracting it.
    if grep -qE '<tool_call>|function_call|"name"\s*:\s*"(get_weather|list_files)"' <<<"$content"; then
      log_fail "  tool call syntax leaked into message.content instead of tool_calls: $(printf '%s' "$content" | head -c 300)"
      return 1
    fi
  fi
  return 0
}

run_test() {
  local name="$1"; shift
  log_step "Scenario: ${name}"
  if "$@"; then
    log_pass "${name}"
    results_pass=$((results_pass + 1))
  else
    log_fail "${name}"
    results_fail=$((results_fail + 1))
    fail_names+=("$name")
  fi
}

# --- 1. Single tool call ------------------------------------------------
test_single_call() {
  local resp
  resp="$(chat '[{"role":"user","content":"What is the weather in Boston?"}]' true)" || return 1
  check_tool_call "$resp" 1
}

# --- 2. Tool call with specific arguments -------------------------------
test_call_with_args() {
  local resp args location unit
  resp="$(chat '[{"role":"user","content":"What is the weather in Paris, in celsius?"}]' true)" || return 1
  check_tool_call "$resp" 1 || return 1
  args="$(jq -r '.choices[0].message.tool_calls[0].function.arguments' <<<"$resp")"
  location="$(jq -r '.location // ""' <<<"$args")"
  unit="$(jq -r '.unit // ""' <<<"$args")"
  if [[ "$location" != *"Paris"* ]]; then
    log_fail "  expected location containing 'Paris', got '${location}'"
    return 1
  fi
  if [[ -n "$unit" && "$unit" != "celsius" ]]; then
    log_fail "  expected unit 'celsius' (or omitted), got '${unit}'"
    return 1
  fi
  return 0
}

# --- 3. Sequential tool calls (call -> tool result -> second call) ------
test_sequential_calls() {
  local resp1 call_id resp2 msgs2
  resp1="$(chat '[{"role":"user","content":"What is the weather in Boston, then list files in /tmp?"}]' true)" || return 1
  check_tool_call "$resp1" 1 || return 1
  call_id="$(jq -r '.choices[0].message.tool_calls[0].id' <<<"$resp1")"
  local call_name
  call_name="$(jq -r '.choices[0].message.tool_calls[0].function.name' <<<"$resp1")"

  msgs2="$(jq -n --argjson prior "$(jq '.choices[0].message' <<<"$resp1")" --arg id "$call_id" --arg name "$call_name" '
    [
      {role:"user", content:"What is the weather in Boston, then list files in /tmp?"},
      $prior,
      {role:"tool", tool_call_id:$id, name:$name, content:"72F and sunny"}
    ]')"
  resp2="$(chat "$msgs2" true)" || return 1
  # Accept either: model asks for the second tool now, or answers directly.
  local n_calls2 content2
  n_calls2="$(jq '.choices[0].message.tool_calls // [] | length' <<<"$resp2")"
  content2="$(jq -r '.choices[0].message.content // ""' <<<"$resp2")"
  if [[ "$n_calls2" -eq 0 && -z "$content2" ]]; then
    log_fail "  follow-up turn produced neither a tool call nor content"
    return 1
  fi
  if [[ "$n_calls2" -gt 0 ]]; then
    check_tool_call "$resp2" 1 || return 1
  fi
  return 0
}

# --- 4. Multiple tool calls requested in one turn -----------------------
test_multiple_calls_one_turn() {
  local resp
  resp="$(chat '[{"role":"user","content":"Get the weather in Boston AND list files in /tmp — call both tools now."}]' true)" || return 1
  # Some models legitimately serialize this as 1 call + a follow-up instead
  # of 2 parallel calls — treat >=1 well-formed call as a pass, but log the
  # count either way since >=2 is the interesting/desired case to watch for.
  local n_calls
  n_calls="$(jq '.choices[0].message.tool_calls // [] | length' <<<"$resp")"
  log_info "  received ${n_calls} tool_calls in this turn"
  check_tool_call "$resp" 1
}

# --- 5. Tool call followed by a normal (non-tool) response --------------
test_call_then_normal_response() {
  local resp1 call_id call_name msgs2 resp2 n_calls2 content2
  resp1="$(chat '[{"role":"user","content":"What is the weather in Boston?"}]' true)" || return 1
  check_tool_call "$resp1" 1 || return 1
  call_id="$(jq -r '.choices[0].message.tool_calls[0].id' <<<"$resp1")"
  call_name="$(jq -r '.choices[0].message.tool_calls[0].function.name' <<<"$resp1")"

  msgs2="$(jq -n --argjson prior "$(jq '.choices[0].message' <<<"$resp1")" --arg id "$call_id" --arg name "$call_name" '
    [
      {role:"user", content:"What is the weather in Boston?"},
      $prior,
      {role:"tool", tool_call_id:$id, name:$name, content:"72F and sunny"}
    ]')"
  resp2="$(chat "$msgs2" true)" || return 1
  n_calls2="$(jq '.choices[0].message.tool_calls // [] | length' <<<"$resp2")"
  content2="$(jq -r '.choices[0].message.content // ""' <<<"$resp2")"
  if [[ "$n_calls2" -ne 0 ]]; then
    log_fail "  expected a plain-text answer after the tool result, got ${n_calls2} more tool_calls"
    return 1
  fi
  if [[ -z "$content2" || "$content2" == "null" ]]; then
    log_fail "  expected non-empty content after the tool result, got none"
    return 1
  fi
  return 0
}

# --- 6. Streaming tool call -----------------------------------------------
test_streaming_call() {
  local payload sse names_json args_concat has_finish
  payload="$(jq -n --arg m "$model_id" --argjson tools "$TOOLS_JSON" \
    '{model:$m, messages:[{role:"user",content:"What is the weather in Boston?"}], tools:$tools, tool_choice:"auto", max_tokens:300, temperature:0, stream:true}')"
  sse="$(curl -fsS --max-time 60 -X POST "${url}/v1/chat/completions" -H 'Content-Type: application/json' -d "$payload")" || return 1

  # Assemble tool_calls across SSE chunks: vLLM streams function.name once
  # and function.arguments incrementally, indexed by tool_calls[].index.
  names_json="$(printf '%s\n' "$sse" | grep -oE '^data: .*' | sed 's/^data: //' | grep -v '^\[DONE\]$' \
    | jq -s '[.[] | .choices[0].delta.tool_calls[]? | select(.function.name != null) | .function.name] | unique')"
  args_concat="$(printf '%s\n' "$sse" | grep -oE '^data: .*' | sed 's/^data: //' | grep -v '^\[DONE\]$' \
    | jq -s -r '[.[] | .choices[0].delta.tool_calls[]? | .function.arguments // ""] | join("")')"
  has_finish="$(printf '%s\n' "$sse" | grep -oE '^data: .*' | sed 's/^data: //' | grep -v '^\[DONE\]$' \
    | jq -s '[.[] | select(.choices[0].finish_reason == "tool_calls")] | length')"

  if [[ "$(jq 'length' <<<"$names_json")" -eq 0 ]]; then
    log_fail "  no tool_calls[].function.name seen anywhere in the SSE stream"
    return 1
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$args_concat"; then
    log_fail "  concatenated streamed arguments did not assemble into valid JSON: ${args_concat}"
    return 1
  fi
  if [[ "$has_finish" -eq 0 ]]; then
    log_fail "  stream never emitted finish_reason=\"tool_calls\""
    return 1
  fi
  return 0
}

run_test "1. single tool call"                     test_single_call
run_test "2. tool call with arguments"              test_call_with_args
run_test "3. sequential tool calls"                 test_sequential_calls
run_test "4. multiple tool calls in one turn"       test_multiple_calls_one_turn
run_test "5. tool call followed by normal response" test_call_then_normal_response
run_test "6. streaming tool call"                   test_streaming_call

echo
log_step "Results: ${results_pass} passed, ${results_fail} failed (model: ${model_id}, profile: ${PROFILE})"
if [[ "$results_fail" -gt 0 ]]; then
  log_fail "Failed scenarios: ${fail_names[*]}"
  exit 1
fi
log_pass "All tool-calling scenarios passed."
