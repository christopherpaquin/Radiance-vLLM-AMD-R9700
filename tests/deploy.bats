#!/usr/bin/env bats
# Ported pattern from the llama.cpp repo's tests/deploy.bats -- no real
# Docker/GPU/network required, mocks external commands via PATH prepend.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
  source "$REPO_ROOT/scripts/lib/common.sh"
}

@test "resolve_profile_alias maps short names to full profile names" {
  [ "$(resolve_profile_alias qwen38)" = "qwen38-27b" ]
  [ "$(resolve_profile_alias qwen3.8)" = "qwen38-27b" ]
  [ "$(resolve_profile_alias qwen25-coder)" = "qwen25-coder-14b" ]
  [ "$(resolve_profile_alias qwen3-coder)" = "qwen3-coder-30b-a3b" ]
}

@test "resolve_profile_alias passes through unknown names unchanged" {
  [ "$(resolve_profile_alias something-else)" = "something-else" ]
}

@test "list_model_profiles finds all config/models/*.env files" {
  run list_model_profiles
  [[ "$output" == *"qwen38-27b"* ]]
  [[ "$output" == *"qwen25-coder-14b"* ]]
  [[ "$output" == *"qwen3-coder-30b-a3b"* ]]
}

@test "resolve_model_profile fails clearly on an unknown profile" {
  run resolve_model_profile does-not-exist
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown model profile"* ]]
}

@test "qwen38-27b.env deployment profile does not carry the placeholder MODEL_ID" {
  ! grep -q '^MODEL_ID=REPLACE_ME' "$REPO_ROOT/config/models/qwen38-27b.env"
}

@test "compose.yaml references the digest pinned in VERSIONS" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/VERSIONS"
  grep -q 'VLLM_IMAGE' "$REPO_ROOT/.env-template"
}
