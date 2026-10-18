#!/usr/bin/env bash
# check_warnings.sh <log | dir> ... — refuse any compiler, assembler or linker warning in build logs, for the tools that do not
# honour -Werror (a linker, lto-wrapper, a script compiling outside the profile): a line "<file>:<line>[:<col>]: warning: …" or
# "<tool>: warning: …" (gcc, cc1, ld, collect2, lto-wrapper, as, ar, dpkg-deb …). A directory is read for its *.log files (not
# warnings.log, this stage's own). One line per hit, "<log>:<n>: <line>", then "warnings: none" or "warnings: found" (exit 1).
# Runtime output (sanitizer and libFuzzer "WARNING:", a test's own messages) is not this shape and is not read as a warning.
set -uo pipefail
(( $# )) || { printf 'usage: check_warnings.sh <log | dir> ...\n' >&2; exit 2; }
RE='^([^[:space:]:]+:[0-9]+(:[0-9]+)?: warning: |[^[:space:]:]*(gcc|g\+\+|cc|c\+\+|cc1|cc1plus|clang|clang\+\+|ld|ld\.bfd|ld\.gold|collect2|lto-wrapper|lto1|as|ar|ranlib|dpkg-deb|objcopy|strip)(-[0-9.]+)?: ([^[:space:]][^:]*: )?warning: )'
logs=()
for a in "$@"; do
    if [[ -d "${a}" ]]; then
        while IFS= read -r -d '' f; do logs+=("${f}"); done < <(find "${a}" -maxdepth 1 -type f -name '*.log' ! -name warnings.log -print0 | LC_ALL=C sort -z)
    elif [[ -f "${a}" ]]; then logs+=("${a}")
    else printf 'check_warnings: no %s\n' "${a}" >&2; exit 2; fi
done
hits=0
for f in "${logs[@]}"; do
    while IFS= read -r line; do
        printf '  %s:%s\n' "${f##*/}" "$(cut -c1-200 <<< "${line}")"; hits=$((hits + 1))
    done < <(grep -nE -- "${RE}" "${f}")
done
(( hits )) && { printf 'warnings: found (%s lines in %s logs)\n' "${hits}" "${#logs[@]}"; exit 1; }
printf 'warnings: none (%s logs)\n' "${#logs[@]}"
