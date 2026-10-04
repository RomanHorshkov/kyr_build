#!/usr/bin/env bash
# run_fuzz_smoke.sh [seconds] — a bounded fuzz pass over every target, the budget split evenly; default 60 (kyr-build lib/test.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${KYR_BUILD_DIR}/lib/kyr.sh"
kyr_fuzz_smoke "${1:-60}"
