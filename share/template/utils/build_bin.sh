#!/usr/bin/env bash
# build_bin.sh [profile] — build/<profile>/<bin> when the project declares KYR_BIN.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${ROOT_DIR}"/utils/*_project.sh
source "${KYR_BUILD_DIR}/lib/build.sh"
kyr_build_bin "${1:-release}"
