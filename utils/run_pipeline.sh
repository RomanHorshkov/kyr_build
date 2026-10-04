#!/usr/bin/env bash
# run_pipeline.sh — the kyr_build gate: every script parses, the template's wrappers are the catalog's, every header compiles as
# C and C++, the debs build, the integration tests prove the shipped tooling from the deb. Exit 1 on any failure.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
LOG_DIR="${ROOT_DIR}/build/pipeline"; mkdir -p "${LOG_DIR}"
source share/lib/root.sh
if kyr_root_identity > /dev/null; then printf '== build root %s\n' "$(kyr_root_identity)"
else export KYR_ALLOW_HOST_BUILD="${KYR_ALLOW_HOST_BUILD:-1}"; printf '== host build: development only (Build-Root: none)\n'; fi
FAILED=0
stage() {
    local label="$1"; shift
    local log="${LOG_DIR}/${label//[^A-Za-z0-9_.-]/_}.log" rc
    printf '== %s\n' "${label}"
    "$@" > "${log}" 2>&1; rc=$?
    if (( rc == 0 )); then printf '   ok  (%s)\n' "${log}"; else printf '   FAIL (exit %s) -> %s\n' "${rc}" "${log}"; tail -n 15 "${log}" | sed 's/^/      /'; FAILED=1; fi
}
shell_syntax() {
    local f rc=0
    while IFS= read -r f; do bash -n "${f}" || { printf 'syntax: %s\n' "${f}"; rc=1; }; done < <(find share utils tests -name '*.sh' | sort)
    return "${rc}"
}
header_syntax() {
    local h rc=0
    for h in app/include/kyr/util/*.h; do
        gcc -std=c11 -fsyntax-only -Wall -Wextra -Wpedantic -Iapp/include -x c "${h}" || rc=1
        g++ -std=c++17 -fsyntax-only -Wall -Wextra -Iapp/include -x c++ "${h}" || rc=1
        printf 'checked %s\n' "${h}"
    done
    return "${rc}"
}
wrappers_sync() {  # the template's utils/ copies are the wrapper catalog's, byte for byte
    local f rc=0
    for f in share/template/utils/*; do
        [[ -f "share/wrappers/${f##*/}" ]] || continue
        cmp "share/wrappers/${f##*/}" "${f}" || rc=1
        printf 'checked %s\n' "${f}"
    done
    return "${rc}"
}
stage "shell-syntax"   shell_syntax
stage "wrappers-sync"  wrappers_sync
stage "headers-syntax" header_syntax
stage "package"        ./utils/build_deb.sh
stage "ITs"            ./utils/run_ITs.sh
(( FAILED )) && { printf 'pipeline FAILED\n'; exit 1; }
printf 'pipeline GREEN\n'
