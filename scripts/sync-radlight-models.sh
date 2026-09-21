#!/usr/bin/env bash
# Downloads the Radlight candidate model checkpoints at their exact pinned
# Hugging Face revisions (VERSIONS) into plain local directories under
# HF_CACHE_DIR/radlight-models/ -- NOT the hub blob/snapshot cache layout,
# a flat directory per checkpoint, which vLLM/transformers load directly
# from a local path just as well. Deliberately independent of the
# huggingface_hub Python package (not installed on this host) -- uses only
# curl/jq/python3, matching this repo's existing script conventions.
#
# Every file is fetched from the immutable
# https://huggingface.co/<repo>/resolve/<revision>/<path> URL (revision is
# a commit hash, never a branch name) and verified after download: LFS
# files by their published sha256, small non-LFS files by recomputing the
# git blob hash of the downloaded bytes. A mismatch is fatal -- this script
# never silently keeps a corrupt or wrong-revision file.
#
# Idempotent: a file already present with the correct verified size is not
# re-downloaded (re-verified instead, cheap).
#
# Usage: scripts/sync-radlight-models.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
require_env_file
load_env

VERSIONS_FILE="${REPO_ROOT}/VERSIONS"
get_pin() { grep "^${1}=" "$VERSIONS_FILE" | head -1 | cut -d= -f2- | tr -d '"'; }

HF_TOKEN_HEADER=()
if [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
  HF_TOKEN_HEADER=(-H "Authorization: Bearer ${HUGGING_FACE_HUB_TOKEN}")
fi

MODELS_ROOT="${HF_CACHE_DIR:-/var/lib/radiance-vllm/hf-cache}/radlight-models"
mkdir -p "$MODELS_ROOT"

# git-blob sha1 of a file's content, for verifying small non-LFS files
# fetched from the HF tree API (their "oid" is the git blob hash, not a
# content sha256).
git_blob_sha1() {
  local f="$1" size
  size="$(stat -c%s "$f")"
  { printf 'blob %s\0' "$size"; cat "$f"; } | sha1sum | cut -d' ' -f1
}

sync_repo() {
  local repo="$1" revision="$2" dest_name="$3"
  local dest="${MODELS_ROOT}/${dest_name}"
  mkdir -p "$dest"

  log_step "Syncing ${repo}@${revision} -> ${dest}"

  local tree_json
  tree_json="$(curl -fsS "${HF_TOKEN_HEADER[@]}" --max-time 30 \
    "https://huggingface.co/api/models/${repo}/tree/${revision}?recursive=true")" \
    || { log_fail "Could not list files for ${repo}@${revision}"; return 1; }

  # One TSV line per file: path<TAB>type<TAB>size<TAB>sha256-or-empty
  local entries
  entries="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for e in d:
    if e.get('type') != 'file':
        continue
    path = e['path']
    size = e.get('size') or e.get('lfs', {}).get('size') or 0
    sha256 = (e.get('lfs') or {}).get('oid', '')
    print(f\"{path}\t{e.get('oid','')}\t{size}\t{sha256}\")
" <<<"$tree_json")"

  local path oid size sha256
  while IFS=$'\t' read -r path oid size sha256; do
    [[ -n "$path" ]] || continue
    local out="${dest}/${path}"
    mkdir -p "$(dirname "$out")"

    if [[ -f "$out" ]]; then
      local existing_size
      existing_size="$(stat -c%s "$out" 2>/dev/null || echo 0)"
      if [[ "$existing_size" == "$size" ]]; then
        log_info "  already present, size matches: ${path} (${size} bytes) -- skipping download"
        continue
      fi
      log_warn "  ${path}: existing size ${existing_size} != expected ${size} -- re-downloading"
      rm -f "$out"
    fi

    log_info "  downloading ${path} (${size} bytes)"
    curl -fsSL "${HF_TOKEN_HEADER[@]}" --max-time 3600 \
      "https://huggingface.co/${repo}/resolve/${revision}/${path}" -o "$out"

    local actual_size
    actual_size="$(stat -c%s "$out")"
    if [[ -n "$size" && "$size" != "0" && "$actual_size" != "$size" ]]; then
      log_fail "  size mismatch for ${path}: expected ${size}, got ${actual_size}. Deleting corrupt file."
      rm -f "$out"
      return 1
    fi

    if [[ -n "$sha256" ]]; then
      local actual_sha256
      actual_sha256="$(sha256sum "$out" | cut -d' ' -f1)"
      if [[ "$actual_sha256" != "$sha256" ]]; then
        log_fail "  sha256 mismatch for ${path}: expected ${sha256}, got ${actual_sha256}. Deleting corrupt file."
        rm -f "$out"
        return 1
      fi
    else
      # Small non-LFS file -- verify against the git blob hash instead.
      local actual_blob_sha1
      actual_blob_sha1="$(git_blob_sha1 "$out")"
      if [[ -n "$oid" && "$actual_blob_sha1" != "$oid" ]]; then
        log_fail "  git-blob sha1 mismatch for ${path}: expected ${oid}, got ${actual_blob_sha1}. Deleting corrupt file."
        rm -f "$out"
        return 1
      fi
    fi
  done <<<"$entries"

  # Pin the resolved revision alongside the files for status.sh/audits.
  printf '%s\n' "$revision" > "${dest}/.radlight-pinned-revision"
  log_pass "${repo}@${revision} fully synced and verified at ${dest}"
}

sync_repo "$(get_pin RADLIGHT_TARGET_MODEL_ID)" "$(get_pin RADLIGHT_TARGET_MODEL_REVISION)" "Qwen3.8-27B-Quark-AWQ-MXFP4"
sync_repo "$(get_pin RADLIGHT_DRAFTER_MODEL_ID)" "$(get_pin RADLIGHT_DRAFTER_MODEL_REVISION)" "Qwen3.8-27B-DFlash2-FP8"

log_pass "All Radlight model checkpoints synced under ${MODELS_ROOT}"
