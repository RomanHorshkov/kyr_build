#!/usr/bin/env bash
# build_tests.sh [profile] — one cmocka executable per tests/UTs/*.c under build/<profile>/tests/.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${ROOT_DIR}"/utils/*_project.sh
source "${KYR_BUILD_DIR}/lib/build.sh"
kyr_build_tests "${1:-release}"
