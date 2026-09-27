#!/usr/bin/env bash
# template_check.sh [repo-root] — refuse drift from the repository template (plan 2.2): the thin wrappers and
# .clang-format must be byte-identical to the template shipped with this kyr-build, and the fixed layout must exist.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${1:-${ROOT_DIR:-$(pwd -P)}}"
TEMPLATE="${SCRIPT_DIR}/template"
rc=0
# A repository with no C under app/ (a web shell, a manifest) keeps only the deps.sh wrapper: the catalog, the gate,
# .clang-format and quality.yml exist for compiled code.
HAS_C=0
if [[ -d "${ROOT_DIR}/app" ]] && find "${ROOT_DIR}/app" -name '*.c' -print -quit | grep -q .; then HAS_C=1; fi
WRAPPERS=(utils/gcc_build_profiles.sh utils/check_hardening.sh utils/deps.sh utils/vendor.sh .clang-format)
REQUIRED=(VERSION deps.txt LICENSE README.md .github/workflows/quality.yml)
if (( ! HAS_C )); then
    printf '  note    no app/**/*.c: only utils/deps.sh, VERSION, deps.txt, LICENSE and README.md are required\n'
    WRAPPERS=(utils/deps.sh utils/vendor.sh)
    REQUIRED=(VERSION deps.txt LICENSE README.md)
fi
for f in "${WRAPPERS[@]}"; do
    if [[ "${f}" == utils/vendor.sh && ! -d "${ROOT_DIR}/app/extern" && ! -f "${ROOT_DIR}/${f}" ]]; then continue; fi
    src="${TEMPLATE}/${f}"
    [[ "${f}" == .clang-format ]] && src="${SCRIPT_DIR}/.clang-format"
    if cmp -s "${src}" "${ROOT_DIR}/${f}"; then printf '  ok      %s\n' "${f}"
    else printf '  DRIFT   %s differs from the kyr-build template\n' "${f}"; rc=1; fi
done
for f in "${REQUIRED[@]}"; do
    if [[ -f "${ROOT_DIR}/${f}" ]]; then printf '  ok      %s\n' "${f}"
    else printf '  MISSING %s\n' "${f}"; rc=1; fi
done
(( rc == 0 )) && printf 'template: no drift\n' || printf 'template: drift found\n'
exit "${rc}"
