#!/usr/bin/env bash
# Shared helpers for scripts/*.sh. Not meant to be executed directly.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Repo root, regardless of caller's cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

MODEL_PROFILE_DIR="${REPO_ROOT}/config/models"

# Repo-wide default profile when none is given on the command line. Override
# per-invocation with an explicit profile argument, or permanently via
# DEFAULT_MODEL_PROFILE in .env.
DEFAULT_MODEL_PROFILE_FALLBACK="qwen38-27b"
export DEFAULT_MODEL_PROFILE_FALLBACK

# Short, memorable names that map to the actual config/models/*.env
# filenames.
resolve_profile_alias() {
  case "$1" in
    qwen38 | qwen3.8 | qwen3.8-27b) echo "qwen38-27b" ;;
    qwen25-coder | qwen2.5-coder) echo "qwen25-coder-14b" ;;
    qwen3-coder) echo "qwen3-coder-30b-a3b" ;;
    radlight | qwen38-radlight) echo "qwen38-27b-radlight" ;;
    radlight-balanced) echo "qwen38-27b-radlight-balanced" ;;
    radlight-compat) echo "qwen38-27b-radlight-compat" ;;
    radlight-nospec) echo "qwen38-27b-radlight-nospec" ;;
    radlight-template) echo "qwen38-27b-radlight-template" ;;
    *) echo "$1" ;;
  esac
}

# --- stack flavor (radiance-baseline vs radlight) ----------------------------
#
# Two independently-pinned stacks (VERSIONS, docs/RADLIGHT-TUNABLES.md).
# Rather than requiring every caller to pass a separate --stack flag (an
# easy way to accidentally run a radlight profile through compose.yaml, or
# vice versa), the stack is DERIVED from the profile name: any profile
# whose file is config/models/*radlight*.env is the radlight stack, every
# other profile is the radiance-baseline stack. STACK_FLAVOR in .env
# records the currently-deployed stack for status.sh/audits, but deploy.sh
# always derives it fresh from the profile argument rather than trusting
# that recorded value.
stack_for_profile() {
  case "$1" in
    *radlight*) echo "radlight" ;;
    *) echo "radiance-baseline" ;;
  esac
}

# Compose file for a stack.
compose_file_for_stack() {
  case "$1" in
    radlight) echo "${REPO_ROOT}/compose.radlight.yaml" ;;
    radiance-baseline) echo "${REPO_ROOT}/compose.yaml" ;;
    *) log_fail "Unknown stack flavor: '$1' (expected 'radiance-baseline' or 'radlight')"; exit 1 ;;
  esac
}

# Compose service/container name for a stack -- both stacks use this same
# name for their service AND container_name (see compose.yaml/
# compose.radlight.yaml), so one lookup covers both `compose ps <name>` and
# `docker inspect <name>`.
container_name_for_stack() {
  case "$1" in
    radlight) echo "radlight-vllm" ;;
    radiance-baseline) echo "radiance-vllm" ;;
    *) log_fail "Unknown stack flavor: '$1' (expected 'radiance-baseline' or 'radlight')"; exit 1 ;;
  esac
}

# --- output helpers ---------------------------------------------------------

if [[ -t 1 ]]; then
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_BLUE=$'\033[34m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_RED=""; COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_RESET=""
fi

log_info()  { printf '%s\n' "$*" >&2; }
log_pass()  { printf '%s[PASS]%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; }
log_fail()  { printf '%s[FAIL]%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*"; }
log_step()  { printf '%s==>%s %s\n' "${COLOR_BLUE}" "${COLOR_RESET}" "$*" >&2; }

# --- .env loading ------------------------------------------------------------

# Loads .env into the current shell (export). Does not fail if .env is
# missing -- callers that require it should check for themselves.
load_env() {
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
  fi
}

require_env_file() {
  if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    log_fail ".env not found. Run: cp .env-template .env"
    exit 1
  fi
}

# --- model profiles ----------------------------------------------------------

list_model_profiles() {
  local f
  for f in "${MODEL_PROFILE_DIR}"/*.env; do
    [[ -e "$f" ]] || continue
    basename "$f" .env
  done
}

# Prints the resolved path to a profile's env file, or fails with a helpful
# message listing valid profiles.
resolve_model_profile() {
  local profile
  profile="$(resolve_profile_alias "$1")"
  local path="${MODEL_PROFILE_DIR}/${profile}.env"
  if [[ -z "$profile" ]]; then
    log_fail "No model profile given."
    log_info "Available profiles:"
    list_model_profiles | sed 's/^/  - /' >&2
    exit 1
  fi
  if [[ ! -f "$path" ]]; then
    log_fail "Unknown model profile: '${profile}'"
    log_info "Available profiles:"
    list_model_profiles | sed 's/^/  - /' >&2
    exit 1
  fi
  printf '%s\n' "$path"
}

# --- current-profile state ---------------------------------------------------

# docker compose needs MODEL_PROFILE set (to resolve config/models/*.env via
# env_file) for every subcommand, not just up -- including down/ps/logs. We
# remember the last profile start.sh used so stop.sh/status.sh don't require
# the caller to repeat it. Lives under the system state dir (not the repo),
# same convention as the llama.cpp repo's state/current-profile.
STATE_DIR="/var/lib/radiance-vllm/state"
CURRENT_PROFILE_FILE="${STATE_DIR}/current-profile"
CURRENT_STACK_FILE="${STATE_DIR}/current-stack"

# Records both the profile AND its stack flavor -- the two-level rollback
# chain (radlight -> radiance-baseline -> llama.cpp) needs to know which
# compose file/container name a "prior known-good" profile actually runs
# under, not just its name.
save_current_profile() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$CURRENT_PROFILE_FILE"
  printf '%s\n' "$(stack_for_profile "$1")" > "$CURRENT_STACK_FILE"
}

# Prints the remembered profile, or empty if none.
load_current_profile() {
  [[ -f "$CURRENT_PROFILE_FILE" ]] && cat "$CURRENT_PROFILE_FILE"
  return 0
}

# Prints the remembered stack for the current profile, or derives it from
# the profile name if the state file predates this field (upgrade path).
load_current_stack() {
  if [[ -f "$CURRENT_STACK_FILE" ]]; then
    cat "$CURRENT_STACK_FILE"
  else
    local p
    p="$(load_current_profile)"
    [[ -n "$p" ]] && stack_for_profile "$p"
  fi
  return 0
}

# --- docker compose -----------------------------------------------------------

# Echoes the compose command to use ("docker compose" or "docker-compose").
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    log_fail "Neither 'docker compose' nor 'docker-compose' is available."
    exit 1
  fi
}

# Runs docker compose in the repo root with MODEL_PROFILE and API_PORT
# exported, so env_file: config/models/${MODEL_PROFILE}.env and the port
# mapping resolve correctly. Uses -f to select compose.yaml or
# compose.radlight.yaml based on STACK_FLAVOR (set by the caller --
# ideally via `export STACK_FLAVOR="$(stack_for_profile "$PROFILE")"` right
# after resolving the profile, so this never has to guess).
compose() {
  local cmd file
  cmd="$(compose_cmd)"
  file="$(compose_file_for_stack "${STACK_FLAVOR:-radiance-baseline}")"
  (cd "${REPO_ROOT}" && MODEL_PROFILE="${MODEL_PROFILE:-}" $cmd -f "$file" "$@")
}

# --- GPU group GIDs -----------------------------------------------------------

# Resolves numeric video/render GIDs from the host. group_add by NAME only
# works if the container image's own /etc/group happens to define the same
# names, which is not guaranteed (verified failure on this exact image
# family per docs/ROCM.md) -- numeric GIDs match the host device files'
# owning group regardless of the container's own /etc/group contents.
resolve_gpu_gids() {
  local video_gid render_gid
  video_gid="$(getent group video 2>/dev/null | cut -d: -f3 || true)"
  render_gid="$(getent group render 2>/dev/null | cut -d: -f3 || true)"
  [[ -z "$video_gid" ]] && log_warn "host 'video' group not found -- GPU device access may fail"
  [[ -z "$render_gid" ]] && log_warn "host 'render' group not found -- GPU device access may fail"
  export VIDEO_GID="$video_gid"
  export RENDER_GID="$render_gid"
}

# --- misc ---------------------------------------------------------------------

api_base_url() {
  load_env
  local host="${API_BIND_ADDRESS:-127.0.0.1}"
  # 0.0.0.0 isn't dereferenceable from the client side; use localhost instead.
  [[ "$host" == "0.0.0.0" ]] && host="localhost"
  printf 'http://%s:%s\n' "$host" "${API_PORT:-8081}"
}
