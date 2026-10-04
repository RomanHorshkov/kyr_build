#!/usr/bin/env bash
# run_ITs.sh — every KYR_IT_SCRIPTS script (default tests/ITs/*.sh); exit 77 skips, any other failure fails (kyr-build lib/test.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${KYR_BUILD_DIR}/lib/kyr.sh"
kyr_run_it_scripts "$@"
