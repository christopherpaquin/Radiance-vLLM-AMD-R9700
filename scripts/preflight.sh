#!/usr/bin/env bash
# Validates the host is ready to run Radiance vLLM before we try to start it.
# Read-only: never installs, modifies, or writes anything (state-dir creation
# in common.sh's save_current_profile is the only exception, and that's not
# called from here).
#
# Usage: scripts/preflight.sh [--cutover]
#   --cutover: also run the additional checks required before taking over
#              port 8080 from llama.cpp (plan §16 "New for this migration").
set -uo pipefail # not -e: individual checks must not abort the whole run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

EXPECTED_GFX="gfx1201"
CUTOVER_MODE=0
[[ "${1:-}" == "--cutover" ]] && CUTOVER_MODE=1

FAIL_COUNT=0
WARN_COUNT=0

pass() { log_pass "$*"; }
warn() { log_warn "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { log_fail "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

section() { printf '\n%s\n' "$*"; }

# --- OS ----------------------------------------------------------------------

section "Operating system"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    pass "Ubuntu detected (${PRETTY_NAME:-unknown version})"
  else
    warn "Not Ubuntu (detected: ${PRETTY_NAME:-${ID:-unknown}}) -- this deployment was designed on Ubuntu 24.04; other distros are untested"
  fi
else
  warn "/etc/os-release not found -- could not determine distro"
fi

# --- Docker (not Podman -- see plan §12.1: verified host convention) --------

section "Container runtime"
if command -v docker >/dev/null 2>&1; then
  ver="$(docker --version 2>/dev/null || true)"
  pass "Docker installed (${ver})"
  if docker info >/dev/null 2>&1; then
    pass "Docker daemon is reachable"
  else
    fail "Docker daemon is not reachable (is it running? is your user in the 'docker' group?)"
  fi
else
  fail "Docker is not installed or not on PATH"
fi

if docker compose version >/dev/null 2>&1; then
  pass "Docker Compose plugin available ($(docker compose version --short 2>/dev/null))"
elif command -v docker-compose >/dev/null 2>&1; then
  warn "Using standalone docker-compose ($(docker-compose --version 2>/dev/null)); the 'docker compose' plugin is preferred"
else
  fail "Neither 'docker compose' (plugin) nor 'docker-compose' (standalone) is available"
fi

if command -v podman >/dev/null 2>&1; then
  warn "podman is present on this host but this deployment uses Docker (matches host convention -- see plan §12.1). Ignore unless you intentionally switched runtimes."
fi

# --- GPU device nodes --------------------------------------------------------

section "GPU device nodes"
if [[ -e /dev/kfd ]]; then
  pass "/dev/kfd present"
else
  fail "/dev/kfd not present -- amdgpu/ROCm kernel driver does not appear to be loaded"
fi

if [[ -e /dev/dri ]]; then
  render_nodes=$(find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$render_nodes" -gt 0 ]]; then
    pass "/dev/dri present with ${render_nodes} render node(s)"
  else
    warn "/dev/dri present but no renderD* nodes found"
  fi
else
  fail "/dev/dri not present"
fi

section "Device permissions"
for dev in /dev/kfd /dev/dri; do
  [[ -e "$dev" ]] || continue
  owner_group="$(stat -c '%U:%G' "$dev" 2>/dev/null || echo 'unknown')"
  pass "${dev} owned by ${owner_group}"
done

if getent group video >/dev/null 2>&1; then
  video_gid="$(getent group video | cut -d: -f3)"
  pass "'video' group exists (gid ${video_gid})"
  if id -nG "${USER}" 2>/dev/null | grep -qw video; then
    pass "Current user (${USER}) is in the 'video' group"
  else
    warn "Current user (${USER}) is NOT in the 'video' group"
  fi
else
  warn "'video' group does not exist on this host"
fi

if getent group render >/dev/null 2>&1; then
  render_gid="$(getent group render | cut -d: -f3)"
  pass "'render' group exists (gid ${render_gid})"
else
  warn "'render' group does not exist on this host -- deploy.sh resolves GIDs numerically, but if this is unexpected, group_add name fallback will not work either (known failure mode, see docs/ROCM.md)"
fi

# --- ROCm userspace tools ----------------------------------------------------

section "ROCm userspace tools"
detected_gfx=""

if command -v rocminfo >/dev/null 2>&1; then
  pass "rocminfo found"
  rocminfo_out="$(rocminfo 2>/dev/null || true)"
  if [[ -n "$rocminfo_out" ]]; then
    detected_gfx="$(printf '%s\n' "$rocminfo_out" | grep -m1 -oE 'gfx[0-9a-fA-F]+' || true)"
    if [[ -n "$detected_gfx" ]]; then
      if [[ "$detected_gfx" == "$EXPECTED_GFX" ]]; then
        pass "Detected GPU architecture: ${detected_gfx} (matches expected ${EXPECTED_GFX})"
      else
        warn "Detected GPU architecture: ${detected_gfx} (expected ${EXPECTED_GFX} for Radeon AI PRO R9700) -- refusing to proceed with an unexpected GPU is the caller's responsibility (plan requirement: fail clearly rather than silently install an incompatible stack)"
      fi
    else
      warn "rocminfo ran but no gfx architecture string was found in its output"
    fi
  else
    warn "rocminfo produced no output"
  fi
else
  warn "rocminfo not found on host -- this only affects host-side diagnostics; the container brings its own ROCm userspace"
fi

if command -v rocm-smi >/dev/null 2>&1; then
  pass "rocm-smi found"
  if rocm_smi_out="$(rocm-smi --showmeminfo vram 2>/dev/null)"; then
    pass "rocm-smi VRAM query succeeded"
    printf '%s\n' "$rocm_smi_out" | sed 's/^/  /'
  else
    warn "rocm-smi found but VRAM query failed (permissions? driver mismatch?)"
  fi
else
  warn "rocm-smi not found on host -- same caveat as rocminfo above"
fi

# --- Disk space (plan §16: check /var/lib's filesystem, not / or /home) ----

section "Disk space"
load_env
hf_cache_dir="${HF_CACHE_DIR:-/var/lib/radiance-vllm/hf-cache}"
check_path="$hf_cache_dir"
[[ -d "$check_path" ]] || check_path="$(dirname "$check_path")"
[[ -d "$check_path" ]] || check_path="/var/lib"
avail_kb="$(df -Pk "$check_path" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "${avail_kb:-}" ]]; then
  avail_gb=$((avail_kb / 1024 / 1024))
  # 27B-class checkpoints + KV cache + bake-off candidates need more than a
  # single-model floor -- raised from the sibling vLLM repo's 30GiB warning.
  if [[ "$avail_gb" -lt 80 ]]; then
    warn "Only ${avail_gb} GiB free at ${check_path} -- a 27B bake-off (multiple candidate checkpoints, ~20GB each) plus the vLLM compile cache needs headroom"
  else
    pass "${avail_gb} GiB free at ${check_path}"
  fi
else
  warn "Could not determine free space at ${check_path}"
fi

# --- Hugging Face cache -------------------------------------------------------

section "Hugging Face cache"
if [[ -z "${HF_CACHE_DIR:-}" ]]; then
  warn "HF_CACHE_DIR not set (.env missing or not sourced) -- defaulting to ${hf_cache_dir}"
else
  pass "HF_CACHE_DIR=${HF_CACHE_DIR}"
fi
if [[ -d "$hf_cache_dir" ]]; then
  pass "HF cache directory exists: ${hf_cache_dir}"
else
  warn "HF cache directory does not exist yet: ${hf_cache_dir}"
fi

existing_cache="${HOME}/.cache/huggingface/hub"
if [[ -d "$existing_cache" ]] && [[ "$(ls -A "$existing_cache" 2>/dev/null)" ]]; then
  size="$(du -sh "$existing_cache" 2>/dev/null | cut -f1)"
  warn "Existing HF cache found at ${existing_cache} (${size:-unknown size}) from the earlier abandoned vLLM deployment -- consider migrating into ${hf_cache_dir} to avoid re-downloading the 14B/30B-A3B fallback profiles (plan §13, not automatic)"
fi

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  warn ".env not found -- run: cp .env-template .env"
fi

# --- Existing llama.cpp deployment (informational, always) ------------------

section "Existing llama.cpp deployment"
if docker inspect llamacpp >/dev/null 2>&1; then
  llamacpp_state="$(docker inspect llamacpp --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
  pass "llamacpp container exists (state: ${llamacpp_state}) -- rollback target is present"
else
  warn "llamacpp container not found -- nothing to roll back to if this deployment fails. If this is unexpected, stop and investigate before proceeding."
fi

# --- Dashboard (informational, non-blocking) --------------------------------

section "Dashboard"
if curl -fsS --max-time 3 http://127.0.0.1:8088/ >/dev/null 2>&1; then
  pass "Dashboard reachable at :8088"
else
  warn "Dashboard not reachable at :8088 (non-blocking -- dashboard changes are plan-radiance-observability.md's scope, not this one's)"
fi

# --- Cutover-specific checks (only with --cutover) ---------------------------

if [[ "$CUTOVER_MODE" -eq 1 ]]; then
  section "Cutover readiness (--cutover)"

  # Accept two valid pre-cutover states: llamacpp actively running on
  # :8080 (the originally-designed fully-concurrent staging scenario),
  # or llamacpp stopped-but-restart-enabled (this host's actual
  # situation -- a single 32GB R9700 can't hold both models resident
  # simultaneously, so llamacpp was deliberately stopped, not
  # crashed/missing, to free VRAM for staging validation -- see
  # docs/runbook.md). Either way, the container object itself existing
  # with a container-not-found state is what's actually unsafe.
  llamacpp_running="$(docker inspect llamacpp --format '{{.State.Running}}' 2>/dev/null || echo unknown)"
  llamacpp_restart_policy="$(docker inspect llamacpp --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo unknown)"
  if [[ "$llamacpp_running" == "true" ]]; then
    pass "Port 8080 is currently owned by the expected container (llamacpp, running)"
  elif [[ "$llamacpp_running" == "false" && "$llamacpp_restart_policy" != "no" ]]; then
    pass "llamacpp is stopped but autostart is still enabled (restart policy: ${llamacpp_restart_policy}) -- valid pre-cutover state on this host (VRAM contention, see docs/runbook.md), not a missing/broken rollback target"
  else
    fail "llamacpp container state ('${llamacpp_running}', restart policy '${llamacpp_restart_policy}') doesn't match either expected pre-cutover state -- refusing to proceed with an unverified cutover target. Investigate before running cutover.sh."
  fi

  port_owner="$(ss -ltnp 2>/dev/null | awk '$4 ~ /:8080$/ {print}')"
  if [[ -n "$port_owner" ]]; then
    log_info "  ss -ltnp for :8080 -> ${port_owner}"
  else
    log_info "  :8080 currently unbound (expected if llamacpp is stopped)"
  fi

  llamacpp_health="$(docker inspect llamacpp --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
  if [[ "$llamacpp_health" == "healthy" || "$llamacpp_running" == "false" ]]; then
    pass "llamacpp is a valid rollback target (health: ${llamacpp_health}, running: ${llamacpp_running})"
  else
    warn "llamacpp container health is '${llamacpp_health}' while running -- rollback target may itself be degraded; investigate before cutover"
  fi
fi

# --- Summary -------------------------------------------------------------

section "Summary"
echo "Failures: ${FAIL_COUNT}  Warnings: ${WARN_COUNT}"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  log_fail "Preflight found blocking issues. Resolve FAIL items above before starting Radiance vLLM."
  exit 1
elif [[ "$WARN_COUNT" -gt 0 ]]; then
  log_warn "Preflight passed with warnings. Review them above."
  exit 0
else
  log_pass "Preflight passed."
  exit 0
fi
