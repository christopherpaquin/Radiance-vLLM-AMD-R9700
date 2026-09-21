#!/usr/bin/env bash
# Idempotent, pinned acquisition of the Radlight source graph
# (https://codeberg.org/hifi/vllm-radlight + its libr4d and
# radiance-vllm-mxfp4 submodules) into a dedicated host path OUTSIDE this
# Git repo. Radlight is never vendored/copied into this repository -- it
# has no top-level LICENSE file (verified against the pinned commit below;
# see docs/RADLIGHT-TUNABLES.md "Licensing"), so this script clones it to
# disk and pins it by commit hash instead of redistributing its source.
#
# Fails closed on any pin mismatch. Never fast-forwards to a branch tip --
# every checkout is an exact commit hash from VERSIONS, fetched fresh and
# verified before use every time this script runs, whether or not the
# clone already exists.
#
# Usage: scripts/sync-radlight.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# shellcheck source=/dev/null
VERSIONS_FILE="${REPO_ROOT}/VERSIONS"
get_pin() { grep "^${1}=" "$VERSIONS_FILE" | head -1 | cut -d= -f2- | tr -d '"'; }

RADLIGHT_REPO="$(get_pin RADLIGHT_REPO)"
RADLIGHT_COMMIT="$(get_pin RADLIGHT_COMMIT)"
LIBR4D_COMMIT="$(get_pin RADLIGHT_SUBMODULE_LIBR4D_COMMIT)"
MXFP4_COMMIT="$(get_pin RADLIGHT_SUBMODULE_MXFP4_COMMIT)"
DEST="$(get_pin RADLIGHT_LOCAL_PATH)"

for v in RADLIGHT_REPO RADLIGHT_COMMIT LIBR4D_COMMIT MXFP4_COMMIT DEST; do
  if [[ -z "${!v}" ]]; then
    log_fail "Missing pin: ${v} not found in VERSIONS. Refusing to proceed with an unpinned checkout."
    exit 1
  fi
done

log_step "Radlight pins (from VERSIONS):"
log_info "  repo:            ${RADLIGHT_REPO}"
log_info "  commit:          ${RADLIGHT_COMMIT}"
log_info "  libr4d:          ${LIBR4D_COMMIT}"
log_info "  radiance-mxfp4:  ${MXFP4_COMMIT}"
log_info "  dest:            ${DEST}"

mkdir -p "$(dirname "$DEST")"

if [[ ! -d "${DEST}/.git" ]]; then
  log_step "No existing clone at ${DEST} -- cloning fresh"
  git clone --recursive "$RADLIGHT_REPO" "$DEST"
else
  log_step "Existing clone found at ${DEST} -- fetching (never fast-forwarding to a branch tip)"
  git -C "$DEST" fetch --recurse-submodules=no origin
fi

log_step "Checking out pinned top-level commit"
if ! git -C "$DEST" cat-file -e "${RADLIGHT_COMMIT}^{commit}" 2>/dev/null; then
  log_fail "Pinned commit ${RADLIGHT_COMMIT} is not reachable in ${DEST} after fetch. Refusing to proceed -- this could mean the pin is wrong, the commit was force-removed upstream, or the fetch failed silently."
  exit 1
fi
git -C "$DEST" -c advice.detachedHead=false checkout "$RADLIGHT_COMMIT"

log_step "Syncing submodules to their pinned commits"
git -C "$DEST" submodule sync --recursive
git -C "$DEST" submodule update --init --recursive

verify_submodule_pin() {
  local path="$1" expected="$2" actual
  actual="$(git -C "$DEST" rev-parse "HEAD:${path}" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    log_fail "Submodule pin mismatch for '${path}': expected ${expected}, got '${actual:-<missing>}'. Refusing to proceed with an unverified submodule."
    exit 1
  fi
  log_pass "Submodule '${path}' pinned at ${actual} (verified)"
}
verify_submodule_pin "libr4d" "$LIBR4D_COMMIT"
verify_submodule_pin "radiance-vllm-mxfp4" "$MXFP4_COMMIT"

actual_top="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$actual_top" != "$RADLIGHT_COMMIT" ]]; then
  log_fail "Top-level commit mismatch after checkout: expected ${RADLIGHT_COMMIT}, got ${actual_top}."
  exit 1
fi
log_pass "vllm-radlight pinned at ${actual_top} (verified)"

if find "$DEST" "$DEST/libr4d" "$DEST/radiance-vllm-mxfp4" -maxdepth 1 \
  \( -iname 'LICEN*' -o -iname 'COPYING*' \) 2>/dev/null | grep -q .; then
  log_warn "A LICENSE/COPYING file was found -- docs/RADLIGHT-TUNABLES.md's licensing note may be stale, review it."
else
  log_info "No top-level LICENSE/COPYING file in vllm-radlight or either submodule (expected -- see docs/RADLIGHT-TUNABLES.md 'Licensing')."
fi

log_step "Setting the checkout read-only-friendly (the container mounts this path :ro; .git needs to stay readable, not writable, for 'git rev-parse' inside the entrypoint)"
find "$DEST" -type d -exec chmod u+rwx,go+rx {} +
find "$DEST" -type f -exec chmod u+rw,go+r {} +
find "$DEST" -name '*.sh' -exec chmod u+x {} + 2>/dev/null || true

log_pass "Radlight source graph ready at ${DEST}, pinned and verified."
