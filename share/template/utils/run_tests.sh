#!/usr/bin/env bash
# run_tests.sh [profile] — runs build/<profile>/tests/*; exit 1 on any failure; default release (kyr-build lib/build.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${KYR_BUILD_DIR}/lib/kyr.sh"
kyr_each_profile kyr_run_tests release "$@"
