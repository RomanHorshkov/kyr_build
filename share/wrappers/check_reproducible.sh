#!/usr/bin/env bash
# check_reproducible.sh [--keep | --inputs-clean] — thin wrapper: the gate is the pinned kyr-build's (share/check_reproducible.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
for d in "${KYR_BUILD_DIR:-}" "${ROOT_DIR}/build/sysroot/share/kyr-build" /usr/local/share/kyr-build; do
    [[ -n "${d}" && -x "${d}/check_reproducible.sh" ]] && exec "${d}/check_reproducible.sh" "$@"
done
printf 'kyr-build not found: run ./utils/deps.sh sysroot\n' >&2
exit 1
