#!/usr/bin/env bash
# The pragmas gate from the built deb (check_pragmas.sh): a clean repository and the gate's own files pass; each off-switch,
# planted in a scratch copy, is refused at its line with its rule; an allow entry with a reason keeps exactly its site; an entry
# without a reason, an entry that keeps nothing and a hit beside a kept one are refused; app/extern is not read; a bare -w counts
# in the project file only. The switches are spelled in two pieces here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
KB="${SCRATCH}/kb/usr/local/share/kyr-build"
CHECK="${KB}/check_pragmas.sh"
[[ -x "${CHECK}" ]] || fail "kyr-build lacks check_pragmas.sh"

R="${SCRATCH}/repo"; mkdir -p "${R}/app" "${R}/utils"
( cd "${R}" && git init -q -b master && printf 'int f(int a) { return a; }\n' > app/f.c && printf 'KYR_LIB=f\n' > utils/f_project.sh && git add -A )
run() { KYR_BUILD_DIR="${KB}" "${CHECK}" "${R}" > "${SCRATCH}/out" 2>&1; local rc=$?; cat "${SCRATCH}/out"; return "${rc}"; }
refused() { # <what> <text the output must hold>
    local out rc=0; out="$(run)" || rc=$?
    (( rc == 1 )) || { printf '%s\n' "${out}" >&2; fail "accepted (exit ${rc}): $1"; }
    grep -qF -- "$2" <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "refused without \"$2\": $1"; }
}
passes() { run > /dev/null || { cat "${SCRATCH}/out" >&2; fail "refused: $1"; }; }

passes "a clean repository"
mkdir -p "${R}/gate" && cp "${CHECK}" "${R}/gate/" && git -C "${R}" add -A
passes "the gate's own file"

P='#pragma GCC diag''nostic'
SAMPLES=(
    "app/f.c|${P} ignored \"-Wconversion\"|pragma-off"
    "app/f.c|#pragma clang diag""nostic ignored \"-Wshadow\"|pragma-off"
    "app/f.c|${P} warning \"-Wshadow\"|pragma-off"
    "app/f.c|#pragma GCC system""_header|system-header"
    "app/f.c|static int g __attribute__((un""used));|unused-attr"
    "app/f.c|static int h __attribute__((noinline, __un""used__));|unused-attr"
    "app/f.c|[[maybe_un""used]] static int k;|unused-attr"
    "app/f.c|int x = __ext""ension__ 1;|extension"
    "utils/f_project.sh|KYR_TEST_CPPFLAGS=(-W""no-unused-parameter)|wno"
    "utils/build.mk|CFLAGS += -W""no-error|wno"
    "utils/f_project.sh|KYR_LIB_CPPFLAGS=(-w)|w-flag"
)
for s in "${SAMPLES[@]}"; do
    IFS='|' read -r path text rule <<< "${s}"
    cp "${R}/${path}" "${SCRATCH}/keep" 2> /dev/null || : > "${SCRATCH}/keep"
    printf '%s\n' "${text}" >> "${R}/${path}"; git -C "${R}" add -A
    n="$(wc -l < "${R}/${path}")"
    refused "${rule} planted in ${path}" "${path}:${n}: ${rule}:"
    cp "${SCRATCH}/keep" "${R}/${path}"; [[ -s "${R}/${path}" ]] || rm -f "${R}/${path}"; git -C "${R}" add -A
done
passes "every sample removed"

printf 'curl -w "%%{http_code}" -o /dev/null http://x\n' > "${R}/probe.sh" && git -C "${R}" add -A
passes "a -w outside the project file (a curl option)"
mkdir -p "${R}/app/extern/up" && printf '%s ignored "-Wall"\n' "${P}" > "${R}/app/extern/up/up.c" && git -C "${R}" add -A
passes "vendored code under app/extern"

printf '%s ignored "-Wanalyzer-fd-leak"\nint y;\n' "${P}" > "${R}/app/keep.c" && git -C "${R}" add -A
refused "an off-switch before its allow entry" "app/keep.c:1: pragma-off:"
printf '# kept sites\napp/keep.c | ignored "-Wanalyzer-fd-leak" | the benchmark keeps its log fd open for the process lifetime\n' \
    > "${R}/pragmas.allow" && git -C "${R}" add -A
passes "an allow entry with its reason"
printf '%s ignored "-Wconversion"\n' "${P}" >> "${R}/app/keep.c" && git -C "${R}" add -A
refused "a second switch beside a kept one" "app/keep.c:3: pragma-off:"
printf '%s ignored "-Wanalyzer-fd-leak"\nint y;\n' "${P}" > "${R}/app/keep.c" && git -C "${R}" add -A
cp "${R}/pragmas.allow" "${SCRATCH}/allow"
printf 'app/keep.c | -Wanalyzer-fd-leak |\n' >> "${R}/pragmas.allow"
refused "an entry without a reason" "pragmas.allow:3:"
cp "${SCRATCH}/allow" "${R}/pragmas.allow"; printf 'app/gone.c | ignored | it went away\n' >> "${R}/pragmas.allow"
refused "an entry that keeps nothing" "app/gone.c | ignored keeps nothing"
cp "${SCRATCH}/allow" "${R}/pragmas.allow"
passes "the allow file restored"

cp -a "${KB}" "${SCRATCH}/kb2"; printf '# -W%s\n' "no-shadow" >> "${SCRATCH}/kb2/wrappers/deps.sh"
cp "${SCRATCH}/kb2/wrappers/deps.sh" "${R}/utils/deps.sh" && git -C "${R}" add -A
KYR_BUILD_DIR="${SCRATCH}/kb2" "${SCRATCH}/kb2/check_pragmas.sh" "${R}" > "${SCRATCH}/out" 2>&1 || { cat "${SCRATCH}/out" >&2; fail "a kyr-build wrapper equal to the pinned one was read"; }
printf '\n' >> "${R}/utils/deps.sh"
if KYR_BUILD_DIR="${SCRATCH}/kb2" "${SCRATCH}/kb2/check_pragmas.sh" "${R}" > "${SCRATCH}/out" 2>&1; then fail "a kyr-build wrapper changed by hand passed"; fi
grep -qF 'utils/deps.sh:' "${SCRATCH}/out" || fail "the changed wrapper is not named"
