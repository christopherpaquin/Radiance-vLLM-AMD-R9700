#!/usr/bin/env bash
# Asserts VERSIONS and .env-template/.env never silently drift apart.
# Run as a pre-commit hook scoped to ^(VERSIONS|compose\.yaml|\.env.*)$.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/VERSIONS"

fail=0
check_ref_in_file() {
  local file="$1" ref="$2"
  [[ -f "$file" ]] || return 0
  if ! grep -qF "$ref" "$file"; then
    echo "[verify-versions-pin] FAIL: ${ref} not found in ${file} -- VERSIONS and ${file} have drifted" >&2
    fail=1
  fi
}

check_ref_in_file "$REPO_ROOT/.env-template" "$VLLM_IMAGE_DIGEST"
if [[ -f "$REPO_ROOT/.env" ]]; then
  check_ref_in_file "$REPO_ROOT/.env" "$VLLM_IMAGE_DIGEST"
fi

# --- Radlight stack pins -----------------------------------------------------
# scripts/sync-radlight.sh and sync-radlight-models.sh read their pins
# straight from VERSIONS at runtime (no separate copy to drift) -- the only
# literal duplicate worth checking here is .env-template/.env's own
# RADLIGHT_BASE_IMAGE line, which a careless edit could desync from
# VERSIONS' RADLIGHT_BASE_IMAGE_DIGEST.
check_ref_in_file "$REPO_ROOT/.env-template" "$RADLIGHT_BASE_IMAGE_DIGEST"
if [[ -f "$REPO_ROOT/.env" ]]; then
  check_ref_in_file "$REPO_ROOT/.env" "$RADLIGHT_BASE_IMAGE_DIGEST"
fi

if [[ "$fail" -eq 1 ]]; then
  echo "[verify-versions-pin] Re-check VERSIONS against .env-template/.env before committing." >&2
  exit 1
fi
echo "[verify-versions-pin] OK -- image digest pin consistent." >&2
