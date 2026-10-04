#!/usr/bin/env bash
# build_tests.sh [profile] — one cmocka executable per KYR_TEST_SOURCES entry under build/<profile>/tests/; default release (kyr-build lib/build.sh).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${KYR_BUILD_DIR}/lib/kyr.sh"
kyr_each_profile kyr_build_tests release "$@"
