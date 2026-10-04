#!/usr/bin/env bash
# The symbol-version ceiling: an executable bound by .symver to GLIBC_2.40 and a library needing GLIBCXX_3.4.34 (stub libraries
# define those nodes; the gate reads version names, whatever library defines them) fail both the full gate and --ceiling-only;
# a plain hardened executable passes; KYR_TARGET_GLIBC_MAX raises the ceiling deliberately; --ceiling-only skips objects and
# non-ELF files.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
CH="${SCRATCH}/kb/usr/local/share/kyr-build/check_hardening.sh"
cd "${SCRATCH}"
HARD=(-O2 -fPIE -pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack)
stub() {  # <soname> <node> <symbol>: stub/<soname> defining <symbol>@@<node>
    mkdir -p stub
    printf 'void %s(void) {}\n' "$3" > "stub/$3.c"
    printf '%s { global: %s; local: *; };\n' "$2" "$3" > "stub/$3.map"
    gcc -shared -fPIC -Wl,-soname,"$1" -Wl,--version-script="stub/$3.map" -o "stub/$1" "stub/$3.c"
}
stub libkyr_fixture.so.1 GLIBC_2.40 kyr_fixture_new
stub libkyr_fixturexx.so.1 GLIBCXX_3.4.34 kyr_fixture_cxx
printf 'void kyr_fixture_new(void);\n__asm__(".symver kyr_fixture_new, kyr_fixture_new@GLIBC_2.40");\nint main(void) { kyr_fixture_new(); return 0; }\n' > too_new.c
gcc "${HARD[@]}" -o too_new too_new.c stub/libkyr_fixture.so.1
printf 'void kyr_fixture_cxx(void);\nvoid user_f(void) { kyr_fixture_cxx(); }\n' > cxx.c
gcc -shared -fPIC -O2 -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-soname,libcxxuser.so.1 -o libcxxuser.so.1 cxx.c stub/libkyr_fixturexx.so.1
printf '#include <stdio.h>\nint main(void) { char b[8]; snprintf(b, sizeof b, "%%d", 1); puts(b); return 0; }\n' > ok.c
gcc "${HARD[@]}" -o ok ok.c
readelf -VW too_new | grep -q 'Name: GLIBC_2.40' || fail "the fixture does not need GLIBC_2.40"

out="$("${CH}" too_new 2>&1)" && fail "GLIBC_2.40 passed the full gate"
grep -q 'GLIBC_2.40>GLIBC_2.39' <<< "${out}" || { printf '%s\n' "${out}"; fail "no ceiling failure for GLIBC_2.40"; }
grep -q 'HARD failure(s)' <<< "${out}" && [[ "$(grep -c '✗' <<< "${out}")" == 1 ]] || { printf '%s\n' "${out}"; fail "the full gate failed on more than the ceiling"; }
out="$("${CH}" --ceiling-only too_new 2>&1)" && fail "GLIBC_2.40 passed --ceiling-only"
out="$("${CH}" --ceiling-only libcxxuser.so.1 2>&1)" && fail "GLIBCXX_3.4.34 passed --ceiling-only"
grep -q 'GLIBCXX_3.4.34>GLIBCXX_3.4.33' <<< "${out}" || { printf '%s\n' "${out}"; fail "no ceiling failure for GLIBCXX_3.4.34"; }
"${CH}" ok > /dev/null || fail "a plain hardened executable failed"
KYR_TARGET_GLIBC_MAX=2.40 "${CH}" --ceiling-only too_new > /dev/null || fail "KYR_TARGET_GLIBC_MAX=2.40 did not admit GLIBC_2.40"
gcc -c -fPIC ok.c -o ok.o
out="$("${CH}" --ceiling-only ok ok.o ok.c 2>&1)" || fail "--ceiling-only failed on an object or a source file"
grep -q '^check_hardening: 1 ELF' <<< "${out}" || { printf '%s\n' "${out}"; fail "--ceiling-only counted objects or sources"; }
printf 'ceiling: %s\n' "$(tail -1 <<< "${out}")"
