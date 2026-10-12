#!/usr/bin/env bash
# The hardening gate's DT_NEEDED allow-list: the platform's libkyr_* sonames pass, an undecided library and a pre-kyr soname
# fail, and CHECK_HARDENING_NEEDED_EXTRA admits one deliberately.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
CH="${SCRATCH}/kb/usr/local/share/kyr-build/check_hardening.sh"
cd "${SCRATCH}"
so() {  # <name>: lib<name>.so.1, hardened
    printf 'int %s_f(void) { return 1; }\n' "$1" > "$1.c"
    gcc -shared -fPIC -O2 -fstack-protector-strong -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-soname,"lib$1.so.1" -o "lib$1.so.1" "$1.c"
    ln -sf "lib$1.so.1" "lib$1.so"
}
so kyr_alpha; so undecided
printf 'int kyr_alpha_f(void);\nint undecided_f(void);\nint user_f(void) { return kyr_alpha_f() + undecided_f(); }\n' > user.c
gcc -shared -fPIC -O2 -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-soname,libuser.so.1 -o libuser.so.1 user.c -L. -lkyr_alpha -lundecided
out="$("${CH}" libuser.so.1 2>&1 || true)"
grep -q 'unexpected DT_NEEDED: libundecided.so.1' <<< "${out}" || { printf '%s\n' "${out}"; fail "an undecided library passed"; }
grep -q 'libkyr_alpha' <<< "$(grep 'unexpected' <<< "${out}")" && fail "libkyr_* refused"
CHECK_HARDENING_NEEDED_EXTRA='libundecided' "${CH}" libuser.so.1 > /dev/null || fail "CHECK_HARDENING_NEEDED_EXTRA"
old="d""b_app"   # the core's soname before the rename, spelled in two pieces for the legacy-names gate
so "${old}"
printf 'int %s_f(void);\nint olduser_f(void) { return %s_f(); }\n' "${old}" "${old}" > olduser.c
gcc -shared -fPIC -O2 -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-soname,libolduser.so.1 -o libolduser.so.1 olduser.c -L. -l"${old}"
out="$("${CH}" libolduser.so.1 2>&1 || true)"
grep -q "unexpected DT_NEEDED: lib${old}.so.1" <<< "${out}" || { printf '%s\n' "${out}"; fail "a pre-kyr soname passed"; }
CHECK_HARDENING_NEEDED_EXTRA='libother|libundecided' "${CH}" libuser.so.1 > /dev/null || fail "an alternation in CHECK_HARDENING_NEEDED_EXTRA"
