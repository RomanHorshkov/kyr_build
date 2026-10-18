#!/usr/bin/env bash
# The strict set from the built deb: every profile's CFLAGS carry -Werror and every flag of the strict set, every link
# -Wl,--fatal-warnings; on a template repository one planted warning, in the library or in a test, fails that build in every
# profile (the tests' builds included), and a vendored source is built under its repository's listed flags, never -w.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
CAT="${SCRATCH}/kb/usr/local/share/kyr-build/gcc_build_profiles.sh"
STRICT=(-Wall -Wextra -Wpedantic -Wformat=2 -Wformat-signedness -Wshadow -Wundef -Wconversion -Wsign-conversion -Wcast-qual
    -Wcast-align=strict -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations -Wold-style-definition -Wredundant-decls
    -Wnested-externs -Wnull-dereference -Wdouble-promotion -Wfloat-equal -Wswitch-enum -Wswitch-default -Wimplicit-fallthrough=5
    -Wvla -Walloca -Wwrite-strings -Wpointer-arith -Wbad-function-cast -Wduplicated-cond -Wduplicated-branches -Wlogical-op
    -Wjump-misses-init -Winit-self -Wshift-overflow=2 -Wbidi-chars=any -Wmissing-format-attribute -Wunused-macros -Werror)
PROFILES=(debug audit sanitize release native extreme tsan coverage)
arr() { ROOT_DIR="${SCRATCH}" bash -c 'source "$1" > /dev/null && n="$2[@]" && printf " %s" "${!n}"; printf " \n"' _ "${CAT}" "$1"; }
for p in "${PROFILES[@]}"; do
    flags="$(arr "CFLAGS_${p^^}")"
    for f in "${STRICT[@]}"; do [[ "${flags}" == *" ${f} "* ]] || fail "profile ${p} lacks ${f}"; done
    [[ "${flags}" != *" -w "* && "${flags}" != *" -Wno-"* ]] || fail "profile ${p} turns a warning off"
    [[ "$(arr "LDFLAGS_${p^^}")" == *" -Wl,--fatal-warnings "* ]] || fail "profile ${p} links without --fatal-warnings"
done
[[ "$(arr LDFLAGS_SHARED)" == *" -Wl,--fatal-warnings "* ]] || fail "LDFLAGS_SHARED without --fatal-warnings"
for p in debug audit release native extreme; do [[ "$(arr "CFLAGS_${p^^}")" == *" -Wstack-usage="* ]] || fail "profile ${p} has no stack bound"; done

A="${SCRATCH}/kyr_zstrict"; instantiate "${A}"
cd "${A}"
./utils/deps.sh sysroot > /dev/null
for p in debug release; do ./utils/build_libs.sh "${p}" > /dev/null 2>&1 || fail "the clean template does not build ${p}"; done
cp app/src/word.c "${SCRATCH}/word.c"
printf 'int kyr_word_narrow(long v);\nint kyr_word_narrow(long v) { return v; }\n' >> app/src/word.c
for p in "${PROFILES[@]}"; do
    [[ "${p}" == tsan ]] && continue
    if ./utils/build_libs.sh "${p}" > "${SCRATCH}/out" 2>&1; then fail "a -Wconversion warning passed the ${p} library build"; fi
    grep -q 'error: conversion from' "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "${p}: not refused as an error"; }
done
cp "${SCRATCH}/word.c" app/src/word.c
./utils/build_libs.sh release > /dev/null 2>&1 || fail "the restored library does not build"
printf 'static int unused_helper(void) { return 0; }\n' >> tests/UTs/word_tests.c
for p in audit sanitize release; do
    if ./utils/build_tests.sh "${p}" > "${SCRATCH}/out" 2>&1; then fail "an unused function passed the ${p} test build"; fi
    grep -q "error: .unused_helper. defined but not used" "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "${p} tests: not refused as an error"; }
done
git checkout -q tests/UTs/word_tests.c

# Vendored code: built under KYR_LIB_VENDOR_CFLAGS, never -w; a warning it does not list fails like any other.
mkdir -p app/extern/up
printf 'int up_sum(int a, int b);\nint up_sum(int a, int b) { int unused_local; return a + b; }\n' > app/extern/up/up.c
printf 'KYR_LIB_VENDOR_SOURCES=(app/extern/up/up.c)\n' >> utils/kyr_word_project.sh
./utils/build_libs.sh release > "${SCRATCH}/out" 2>&1 || { cat "${SCRATCH}/out" >&2; fail "a vendored source with no listed flags failed"; }
printf 'KYR_LIB_VENDOR_CFLAGS=(-Wall)\n' >> utils/kyr_word_project.sh
if ./utils/build_libs.sh release > "${SCRATCH}/out" 2>&1; then fail "a vendored warning under its listed -Wall passed"; fi
grep -q "error: unused variable .unused_local." "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "the vendored warning is not an error"; }
printf '#warning vendored\nint up_sum(int a, int b);\nint up_sum(int a, int b) { return a + b; }\n' > app/extern/up/up.c
if ./utils/build_libs.sh release > "${SCRATCH}/out" 2>&1; then fail "a vendored #warning passed (built with -w?)"; fi
grep -q "error: #warning vendored" "${SCRATCH}/out" || { cat "${SCRATCH}/out" >&2; fail "the vendored #warning is not an error"; }
