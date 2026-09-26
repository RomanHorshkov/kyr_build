#!/usr/bin/env bash
# build_libs.sh [profile ...] — build/<profile>/lib<name>.{a,so}; default: every profile in the catalog.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${ROOT_DIR}"/utils/*_project.sh
source "${KYR_BUILD_DIR}/lib/build.sh"
PROFILES=("$@"); (( $# )) || PROFILES=("${GCC_BUILD_PROFILES[@]}")
for profile in "${PROFILES[@]}"; do kyr_build_lib "${profile}"; done
