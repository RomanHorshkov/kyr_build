#!/usr/bin/env bash
# template_check.sh [repo-root] — refuse drift from the kyr-build template (plan 2.2, D38). One line per check, then
# "template: no drift" or "template: drift found" (exit 1).
#
#   utils/      every tracked (or new, unignored) entry is one of:
#                 a kyr-build wrapper (share/wrappers/<name>)   byte-identical, else DRIFT
#                 the project file utils/<name>_project.sh      declarations only: no function, no compiler or packager call
#                 a linker version script utils/*.map
#                 a repository gate the project file lists in KYR_REPO_GATES (a file or a directory under utils/)
#               anything else is DRIFT: a build_*, run_* or build_deb script that is not the wrapper is copied machinery
#   required    VERSION deps.txt LICENSE README.md and utils/deps.sh; with C anywhere in the tree (build/ aside) also
#               .clang-format (kyr-build's, ending in a newline), .github/workflows/quality.yml, utils/gcc_build_profiles.sh and
#               utils/check_hardening.sh, utils/check_abi.sh with abi/layout.txt, utils/vendor.sh with app/extern
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${1:-${ROOT_DIR:-$(pwd -P)}}" && pwd -P)"
WRAPPERS="${SCRIPT_DIR}/wrappers"
rc=0
ok() { printf '  ok      %s\n' "$*"; }
drift() { printf '  DRIFT   %s\n' "$*"; rc=1; }
missing() { printf '  MISSING %s\n' "$*"; rc=1; }

HAS_C=0
if find "${ROOT_DIR}" -path "${ROOT_DIR}/build" -prune -o -path "${ROOT_DIR}/.git" -prune -o -path '*/node_modules' -prune -o \
    -name '*.c' -print -quit | grep -q .; then HAS_C=1; fi
(( HAS_C )) || printf '  note    no C sources: the catalog, the gate, .clang-format and quality.yml are not required\n'

# The utils/ entries a commit would carry.
if git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    mapfile -t ENTRIES < <(cd "${ROOT_DIR}" && { git ls-files -- utils; git ls-files --others --exclude-standard -- utils; } | sed -n 's|^utils/||p' | LC_ALL=C sort -u)
else
    mapfile -t ENTRIES < <(cd "${ROOT_DIR}/utils" 2> /dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
fi

mapfile -t PROJECTS < <(printf '%s\n' "${ENTRIES[@]}" | grep -E '^[^/]+_project\.sh$' || true)
(( ${#PROJECTS[@]} <= 1 )) || drift "several project files: ${PROJECTS[*]}"
GATES=()
if (( ${#PROJECTS[@]} )); then
    p="${ROOT_DIR}/utils/${PROJECTS[0]}"
    funcs="$(grep -nE '^[[:space:]]*(function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\))' "${p}" || true)"
    tools="$(grep -nE '^[[:space:]]*("?\$\{?(CC|AR)\}?"?|gcc|cc|clang|ar|ld|strip|dpkg-deb|fakeroot)[[:space:]]' "${p}" || true)"
    if [[ -n "${funcs}" ]]; then drift "utils/${PROJECTS[0]} defines functions (the project file declares, kyr-build does): $(head -c 200 <<< "${funcs//$'\n'/; }")"
    elif [[ -n "${tools}" ]]; then drift "utils/${PROJECTS[0]} calls a compiler or packager: $(head -c 200 <<< "${tools//$'\n'/; }")"
    else ok "utils/${PROJECTS[0]} (project file, declarations only)"; fi
    mapfile -t GATES < <(cd "${ROOT_DIR}" && ROOT_DIR="${ROOT_DIR}" KYR_BUILD_DIR="${SCRIPT_DIR}" bash -c '
        source utils/gcc_build_profiles.sh > /dev/null 2>&1; source "utils/$1" > /dev/null 2>&1
        declare -p KYR_REPO_GATES > /dev/null 2>&1 && printf "%s\n" "${KYR_REPO_GATES[@]}"' _ "${PROJECTS[0]}" 2> /dev/null)
fi

is_gate() {
    local g
    for g in "${GATES[@]}"; do [[ -n "${g}" && ( "$1" == "${g}" || "$1" == "${g%/}/"* ) ]] && return 0; done
    return 1
}

for e in "${ENTRIES[@]}"; do
    [[ -n "${e}" && -e "${ROOT_DIR}/utils/${e}" ]] || continue
    if [[ "${e}" != */* && -f "${WRAPPERS}/${e}" ]]; then
        if cmp -s "${WRAPPERS}/${e}" "${ROOT_DIR}/utils/${e}"; then ok "utils/${e}"
        else drift "utils/${e} differs from the kyr-build wrapper (share/wrappers/${e})"; fi
    elif [[ "${e}" != */* && "${e}" == *_project.sh ]]; then
        :
    elif [[ "${e}" != */* && "${e}" == *.map ]]; then
        ok "utils/${e} (linker version script)"
    elif is_gate "${e}"; then
        ok "utils/${e} (repository gate, KYR_REPO_GATES)"
    else
        drift "utils/${e} is neither a kyr-build wrapper, the project file, a linker map nor a gate listed in KYR_REPO_GATES"
    fi
done

REQUIRED=(VERSION deps.txt LICENSE README.md utils/deps.sh)
if (( HAS_C )); then
    REQUIRED+=(.github/workflows/quality.yml utils/gcc_build_profiles.sh utils/check_hardening.sh)
    [[ -f "${ROOT_DIR}/abi/layout.txt" ]] && REQUIRED+=(utils/check_abi.sh)
    [[ -d "${ROOT_DIR}/app/extern" ]] && REQUIRED+=(utils/vendor.sh)
    if [[ ! -f "${ROOT_DIR}/.clang-format" ]]; then missing .clang-format
    elif [[ -n "$(tail -c 1 "${ROOT_DIR}/.clang-format")" ]]; then drift ".clang-format does not end with a newline"
    elif ! cmp -s "${SCRIPT_DIR}/.clang-format" "${ROOT_DIR}/.clang-format"; then drift ".clang-format differs from kyr-build's"
    else ok .clang-format; fi
fi
for f in "${REQUIRED[@]}"; do
    if [[ -f "${ROOT_DIR}/${f}" ]]; then [[ "${f}" == utils/* ]] || ok "${f}"
    else missing "${f}"; fi
done
(( rc == 0 )) && printf 'template: no drift\n' || printf 'template: drift found\n'
exit "${rc}"
