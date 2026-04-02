#!/usr/bin/env bash
# Ensures CI jobs use GitHub-hosted runners (not third-party like WarpBuild/Depot).
# Adapted from upstream's WarpBuild guard for our fork.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
for file in "$ROOT_DIR"/.github/workflows/*.yml; do
  basename="$(basename "$file")"
  while IFS= read -r line; do
    if echo "$line" | grep -qE 'warp-|depot-'; then
      echo "FAIL: $basename contains third-party runner: $(echo "$line" | xargs)"
      fail=1
    fi
  done < <(grep -n 'runs-on\|os:' "$file" 2>/dev/null || true)
done

if [ "$fail" -eq 1 ]; then
  exit 1
fi
echo "PASS: all workflows use GitHub-hosted runners"
