#!/usr/bin/env bash
# Attach only the CLI/relay artifacts; existing release assets are immutable.
set -euo pipefail

if [[ "${GITHUB_REF:-}" != refs/tags/v* ]]; then
  echo "CLI/relay publication requires a v* tag." >&2
  exit 1
fi
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

cd "${1:-dist}"
artifacts=(
  arveil-linux-x86_64 arveil-relay-linux-x86_64
  arveil-macos-aarch64 arveil-relay-macos-aarch64
)
# Check both build outputs before creating the combined, separately named list.
shasum -a 256 --check SHA256SUMS-linux-x86_64.txt SHA256SUMS-macos-aarch64.txt
shasum -a 256 "${artifacts[@]}" > SHA256SUMS-cli-relay.txt
# No wildcard upload or --clobber: unrelated files stay local, and a duplicate
# asset fails instead of silently replacing a previously distributed binary.
gh release upload "${GITHUB_REF#refs/tags/}" "${artifacts[@]}" \
  SHA256SUMS-cli-relay.txt --repo "$GITHUB_REPOSITORY"
