#!/usr/bin/env bash
# run_pipeline.sh — the whole gate, in order: deps and tiers, format, the ABI (when abi/layout.txt exists), every profile, tests,
# ITs, package. Exit 1 on any failure.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
LOG_DIR="${ROOT_DIR}/build/pipeline"; mkdir -p "${LOG_DIR}"
FAILED=0
stage() {
    local label="$1"; shift
    local log="${LOG_DIR}/${label//[^A-Za-z0-9_.-]/_}.log"
    printf '== %s\n' "${label}"
    if "$@" > "${log}" 2>&1; then printf '   ok  (%s)\n' "${log}"; else printf '   FAIL (exit %s) -> %s\n' "$?" "${log}"; tail -n 15 "${log}" | sed 's/^/      /'; FAILED=1; fi
}
eval "$(./utils/deps.sh sysroot | grep '^export')" || exit 1
source ./utils/gcc_build_profiles.sh
stage "deps-tiers"   ./utils/deps.sh check --tiers
stage "template"     "${KYR_BUILD_DIR}/template_check.sh" "${ROOT_DIR}"
if command -v "${CLANG_FORMAT:-clang-format}" >/dev/null 2>&1; then stage "format" ./utils/format.sh --check; fi
[[ -d app/extern ]] && stage "vendor" ./utils/vendor.sh verify
[[ -f abi/layout.txt ]] && stage "abi" ./utils/check_abi.sh
for p in "${GCC_BUILD_PROFILES[@]}"; do stage "build:${p}" ./utils/build_libs.sh "${p}"; done
[[ -f abi/layout.txt ]] && stage "abi-exports" ./utils/check_abi.sh --exports
for p in audit sanitize release; do
    stage "tests-build:${p}" ./utils/build_tests.sh "${p}"
    stage "tests:${p}" ./utils/run_tests.sh "${p}"
done
stage "ITs"          ./utils/run_ITs.sh
stage "package"      ./utils/build_deb.sh
(( FAILED )) && { printf 'pipeline FAILED\n'; exit 1; }
printf 'pipeline GREEN\n'
