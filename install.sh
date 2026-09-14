#!/usr/bin/env bash
# Top-level installer: creates system directories (sudo, scoped to
# /var/lib/radiance-vllm only -- plan §25), copies .env-template -> .env if
# missing, runs preflight. Does NOT deploy a model -- that's
# scripts/deploy.sh, run explicitly once a profile's MODEL_ID is resolved.
#
# Usage: ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

log_step "Creating system directories under /var/lib/radiance-vllm"
sudo mkdir -p /var/lib/radiance-vllm/{hf-cache,vllm-cache,state,benchmarks,logs}
sudo chown -R "$(id -u):$(id -g)" /var/lib/radiance-vllm
log_pass "Directories ready."

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  log_step "Creating .env from .env-template"
  cp "${REPO_ROOT}/.env-template" "${REPO_ROOT}/.env"
  log_pass ".env created. Review it before deploying (HUGGING_FACE_HUB_TOKEN, etc.)."
else
  log_info ".env already exists, leaving it alone."
fi

existing_cache="${HOME}/.cache/huggingface/hub"
if [[ -d "$existing_cache" ]] && [[ "$(ls -A "$existing_cache" 2>/dev/null)" ]]; then
  log_warn "Existing HF cache found at ${existing_cache} (from the earlier abandoned vLLM deployment)."
  log_warn "Not migrated automatically (plan §13 -- moving files out of your home dir needs a visible, explicit step)."
  log_info "To migrate and avoid re-downloading the 14B/30B-A3B fallback profiles:"
  log_info "  rsync -av --remove-source-files ${existing_cache}/ /var/lib/radiance-vllm/hf-cache/hub/"
fi

log_step "Running preflight"
"${SCRIPT_DIR}/scripts/preflight.sh" || log_warn "Preflight reported issues -- review above before deploying."

log_pass "Install complete."
log_info "Next: resolve a model profile's MODEL_ID (see config/models/qwen38-27b.env), then:"
log_info "  scripts/deploy.sh <profile>"
