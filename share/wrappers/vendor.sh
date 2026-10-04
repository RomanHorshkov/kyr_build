#!/usr/bin/env bash
# vendor.sh — thin wrapper: the tool is the pinned kyr-build's (deps.txt), never a copy in this repository.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
for d in "${KYR_BUILD_DIR:-}" "${ROOT_DIR}/build/sysroot/share/kyr-build" /usr/local/share/kyr-build; do
    [[ -n "${d}" && -x "${d}/vendor.sh" ]] && exec "${d}/vendor.sh" "$@"
done
printf 'kyr-build not found: run ./utils/deps.sh sysroot\n' >&2
exit 1
