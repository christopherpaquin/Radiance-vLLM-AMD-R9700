#!/usr/bin/env bash
# Reports AMD GPU / ROCm state: model, gfx arch, VRAM, utilization, clocks,
# temperature, power. Degrades gracefully if rocm-smi/rocminfo aren't on the
# host (the container has its own ROCm userspace regardless).
#
# Usage: scripts/gpu-info.sh [--brief]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

BRIEF=0
[[ "${1:-}" == "--brief" ]] && BRIEF=1

if ! command -v rocm-smi >/dev/null 2>&1; then
  log_warn "rocm-smi not found on host — cannot report live GPU state here."
  log_info "This does not affect the container; ROCm tooling lives inside the vLLM image."
  exit 0
fi

if [[ "$BRIEF" -eq 1 ]]; then
  # One-line-per-metric summary for embedding in status.sh.
  rocm-smi --showproductname --showuse --showmeminfo vram --showtemp --showpower 2>/dev/null \
    | grep -E 'Card series|GPU use|Total Memory|Used Memory|Temperature|Average Graphics Package Power' \
    || rocm-smi 2>&1
  exit 0
fi

log_step "GPU product / architecture"
rocm-smi --showproductname 2>&1 || true
if command -v rocminfo >/dev/null 2>&1; then
  rocminfo 2>/dev/null | grep -m1 -oE 'gfx[0-9a-fA-F]+' | sed 's/^/Architecture: /' || true
fi

log_step "VRAM usage"
rocm-smi --showmeminfo vram 2>&1 || true

log_step "GPU utilization"
rocm-smi --showuse 2>&1 || true

log_step "Clocks"
rocm-smi --showclocks 2>&1 || true

log_step "Temperature"
rocm-smi --showtemp 2>&1 || true

log_step "Power"
rocm-smi --showpower 2>&1 || true
