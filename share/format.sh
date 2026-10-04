#!/usr/bin/env bash
# format.sh [--check] — clang-format every C source and header under app/ and tests/ (vendored trees excluded) with the
# repository's .clang-format; --check exits non-zero if any file would change (the gate). CLANG_FORMAT overrides the binary (CI
# pins a major so the gate does not drift with the runner image). Runs through the repository's utils/format.sh wrapper.
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(pwd -P)}"
cd -- "${ROOT_DIR}"
CLANG_FORMAT="${CLANG_FORMAT:-clang-format}"
command -v "${CLANG_FORMAT}" > /dev/null 2>&1 || { printf 'format.sh: %s not found (apt install clang-format)\n' "${CLANG_FORMAT}" >&2; exit 1; }
[[ -f .clang-format ]] || { printf 'format.sh: .clang-format missing at repository root\n' >&2; exit 1; }
dirs=()
for d in app tests; do [[ -d "${d}" ]] && dirs+=("${d}"); done
(( ${#dirs[@]} )) || { printf 'format.sh: no app/ or tests/\n' >&2; exit 1; }
mapfile -t FILES < <(find "${dirs[@]}" -type f \( -name '*.c' -o -name '*.h' \) -not -path '*/extern/*' -not -path '*/third_party/*' -not -path 'tests/results/*' | LC_ALL=C sort)
(( ${#FILES[@]} )) || { printf 'format.sh: no C sources found under app/ or tests/\n' >&2; exit 1; }
if [[ "${1:-}" == --check ]]; then
    "${CLANG_FORMAT}" --style=file --dry-run -Werror "${FILES[@]}"
    printf 'format check passed: %d file(s) already canonical (%s)\n' "${#FILES[@]}" "$("${CLANG_FORMAT}" --version | head -1)"
else
    "${CLANG_FORMAT}" --style=file -i "${FILES[@]}"
    printf 'formatted %d file(s)\n' "${#FILES[@]}"
fi
