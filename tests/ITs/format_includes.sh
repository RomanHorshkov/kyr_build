#!/usr/bin/env bash
# The shipped .clang-format keeps <cmocka.h> after the C headers it needs (stdarg.h, stddef.h, setjmp.h) and leaves every other
# include order as Google's categories sort it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CF=""
for c in "clang-format-${KYR_CLANG_FORMAT_MAJOR:-18}" clang-format; do command -v "${c}" > /dev/null 2>&1 && { CF="${c}"; break; }; done
[[ -n "${CF}" ]] || { printf 'SKIP: no clang-format\n'; exit 0; }
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/x"
cfg="${SCRATCH}/x/usr/local/share/kyr-build/template/.clang-format"
cmp -s "${cfg}" "${SCRATCH}/x/usr/local/share/kyr-build/.clang-format" || fail "the template's .clang-format is not kyr-build's"
cat > "${SCRATCH}/fixture.c" <<'EOF'
#include <cmocka.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdint.h>
#include <setjmp.h>
#include "kyr/word/word.h"

#include <stdio.h>
#include <assert.h>
#include <signal.h>
#include <errno.h>
#include <stdarg.h>
EOF
cat > "${SCRATCH}/expected.c" <<'EOF'
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <cmocka.h>
#include "kyr/word/word.h"

#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
EOF
diff -u "${SCRATCH}/expected.c" <("${CF}" --style=file:"${cfg}" "${SCRATCH}/fixture.c") || fail "include order (${CF})"
diff -u "${SCRATCH}/expected.c" <("${CF}" --style=file:"${cfg}" "${SCRATCH}/expected.c") || fail "the expected order is not a fixed point"
printf 'checked with %s\n' "$("${CF}" --version)"
