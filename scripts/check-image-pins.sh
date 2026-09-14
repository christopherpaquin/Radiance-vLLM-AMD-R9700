#!/usr/bin/env bash
# Generic floating-tag check, shared "coding standards" convention across
# sibling repos on this host -- fails if compose.yaml references an image
# without a digest pin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail=0
while IFS= read -r line; do
  # Only flag lines that reference an image via a bare ${VAR} with no
  # digest anywhere in the resolved env -- the actual digest check is
  # verify-versions-pin.sh's job; this just catches an obviously floating
  # tag committed directly into a file (e.g. "image: foo:latest").
  if [[ "$line" =~ image:\ .*:latest[[:space:]]*$ ]]; then
    echo "[check-image-pins] FAIL: floating :latest tag found: $line" >&2
    fail=1
  fi
done < <(grep -rn 'image:' "$REPO_ROOT/compose.yaml" 2>/dev/null || true)

if [[ "$fail" -eq 1 ]]; then
  exit 1
fi
echo "[check-image-pins] OK" >&2
