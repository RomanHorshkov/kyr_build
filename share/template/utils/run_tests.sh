#!/usr/bin/env bash
# run_tests.sh [profile] — run build/<profile>/tests/*; exit 1 on any failure.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${ROOT_DIR}"/utils/*_project.sh
source "${KYR_BUILD_DIR}/lib/build.sh"
kyr_run_tests "${1:-release}"
