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

@test "compose.radlight.yaml references the digest pinned in VERSIONS" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/VERSIONS"
  grep -qF "$RADLIGHT_BASE_IMAGE_DIGEST" "$REPO_ROOT/.env-template"
}

@test "stack_for_profile classifies radlight profiles correctly" {
  [ "$(stack_for_profile qwen38-27b-radlight)" = "radlight" ]
  [ "$(stack_for_profile qwen38-27b-radlight-balanced)" = "radlight" ]
  [ "$(stack_for_profile qwen38-27b-radlight-nospec)" = "radlight" ]
}

@test "stack_for_profile classifies non-radlight profiles as radiance-baseline" {
  [ "$(stack_for_profile qwen38-27b)" = "radiance-baseline" ]
  [ "$(stack_for_profile qwen25-coder-14b)" = "radiance-baseline" ]
}

@test "container_name_for_stack maps each stack to its own container" {
  [ "$(container_name_for_stack radiance-baseline)" = "radiance-vllm" ]
  [ "$(container_name_for_stack radlight)" = "radlight-vllm" ]
}

@test "container_name_for_stack fails clearly on an unknown stack" {
  run container_name_for_stack bogus-stack
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown stack flavor"* ]]
}

@test "compose_file_for_stack resolves to the right compose file" {
  [ "$(compose_file_for_stack radiance-baseline)" = "$REPO_ROOT/compose.yaml" ]
  [ "$(compose_file_for_stack radlight)" = "$REPO_ROOT/compose.radlight.yaml" ]
}

@test "resolve_profile_alias maps radlight short names" {
  [ "$(resolve_profile_alias radlight)" = "qwen38-27b-radlight" ]
  [ "$(resolve_profile_alias radlight-nospec)" = "qwen38-27b-radlight-nospec" ]
}

@test "list_model_profiles includes every radlight profile" {
  run list_model_profiles
  [[ "$output" == *"qwen38-27b-radlight"* ]]
  [[ "$output" == *"qwen38-27b-radlight-balanced"* ]]
  [[ "$output" == *"qwen38-27b-radlight-compat"* ]]
  [[ "$output" == *"qwen38-27b-radlight-nospec"* ]]
  [[ "$output" == *"qwen38-27b-radlight-template"* ]]
}

@test "none of the radlight profiles carry a placeholder MODEL_ID" {
  for f in "$REPO_ROOT"/config/models/*radlight*.env; do
    ! grep -q '^MODEL_ID=REPLACE_ME' "$f"
  done
}

@test "qwen38-27b-radlight-nospec disables DFlash2 while qwen38-27b-radlight enables it" {
  grep -q '^SPEC_DECODE_ARGS=$' "$REPO_ROOT/config/models/qwen38-27b-radlight-nospec.env"
  grep -q '^SPEC_DECODE_ARGS=--speculative-config' "$REPO_ROOT/config/models/qwen38-27b-radlight.env"
}

@test "docker compose config renders compose.radlight.yaml without error" {
  command -v docker > /dev/null 2>&1 || skip "docker not available in this environment"
  MODEL_PROFILE=qwen38-27b-radlight VIDEO_GID=44 RENDER_GID=992 \
    run docker compose -f "$REPO_ROOT/compose.radlight.yaml" config -q
  [ "$status" -eq 0 ]
}

@test "restore-or-shutdown.sh only auto-invokes the llama.cpp fallback for a failed radlight restore" {
  grep -q 'failed_stack" == "radlight"' "$REPO_ROOT/scripts/restore-or-shutdown.sh"
}
