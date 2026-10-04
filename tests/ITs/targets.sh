#!/usr/bin/env bash
# Several targets from one project file: binaries linked against the archive, the shared object or nothing; a vendored source
# compiled with -w; per-profile tests with a support source, a shared variant, a white-box test that keeps the archive, an
# expected failure, an environment and a reset path; the coverage profile with its gate; a fuzz target in the standalone mode
# (and libFuzzer where clang has it); the integration scripts with exit 77 as a skip.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
for w in coverage.sh build_fuzz.sh run_fuzz_smoke.sh; do cp "${SCRATCH}/kb/usr/local/share/kyr-build/wrappers/${w}" utils/; done
mkdir -p app/extern/tiny app/cli tests/support tests/fuzz/corpus tests/ITs
printf 'int tiny_twice(int x) { int unused; return x * 2; }\n' > app/extern/tiny/tiny.c
cat > app/src/word.c <<'EOF'
#include "kyr/word/word.h"

#include <string.h>

int tiny_twice(int x);

size_t kyr_word_len(const char* s)
{
    return s ? (size_t)tiny_twice((int)strlen(s)) / 2 : 0;
}
EOF
printf '#include <stdio.h>\n#include "kyr/word/word.h"\nint main(void) { printf("%%zu\\n", kyr_word_len("abc")); return 0; }\n' > app/cli/main.c
printf 'int support_value(void) { return 7; }\n' > tests/support/support.c
printf 'int tiny_twice(int x);\nint support_value(void);\nint main(void) { return tiny_twice(support_value()) == 14 ? 0 : 1; }\n' > app/cli/tool.c
cat > tests/UTs/env_tests.c <<'EOF'
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cmocka.h>

#include "kyr/word/word.h"

int support_value(void);

static void env_support_reset(void** state)
{
    (void)state;
    assert_string_equal(getenv("WORD_MODE"), "test");
    assert_int_equal(support_value(), 7);
    assert_int_equal(kyr_word_len("ab"), 2);
    FILE* f = fopen("scratch_state/marker", "r");
    assert_null(f); /* removed before every run */
    f = fopen("scratch_state/marker", "w");
    if (f) fclose(f);
}

int main(void)
{
    const struct CMUnitTest tests[] = {cmocka_unit_test(env_support_reset)};
    return cmocka_run_group_tests(tests, NULL, NULL);
}
EOF
printf 'int main(void) { return 1; }\n' > tests/UTs/must_fail_tests.c
cat > tests/fuzz/fuzz_len.c <<'EOF'
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "kyr/word/word.h"

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    char buf[64];
    size_t n = size < sizeof buf - 1 ? size : sizeof buf - 1;
    memcpy(buf, data, n);
    buf[n] = '\0';
    return kyr_word_len(buf) <= n ? 0 : 1;
}
EOF
cat > tests/fuzz/driver.c <<'EOF'
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

int main(int argc, char** argv)
{
    (void)argc;
    printf("standalone over %s for %s s\n", argv[1], argv[2]);
    return LLVMFuzzerTestOneInput((const uint8_t*)"seed", 4);
}
EOF
printf 'seed' > tests/fuzz/corpus/one
printf '#!/usr/bin/env bash\nexit 77\n' > tests/ITs/skip_me.sh
cat >> utils/kyr_word_project.sh <<'EOF'
mkdir -p "${ROOT_DIR}/scratch_state"
KYR_LIB_VENDOR_SOURCES=(app/extern/tiny/tiny.c)
KYR_BINS=(word-cli word-cli-shared word-tool)
KYR_BIN_WORD_CLI_SOURCES=(app/cli/main.c)
KYR_BIN_WORD_CLI_SHARED_SOURCES=(app/cli/main.c)
KYR_BIN_WORD_CLI_SHARED_LINK=shared
KYR_BIN_WORD_TOOL_SOURCES=(app/cli/tool.c app/extern/tiny/tiny.c tests/support/support.c)
KYR_BIN_WORD_TOOL_LINK=none
KYR_BIN_WORD_TOOL_CPPFLAGS=(-w)
KYR_TEST_SOURCES=(tests/UTs/word_tests.c tests/UTs/env_tests.c tests/UTs/must_fail_tests.c)
KYR_TEST_SUPPORT_SOURCES=(tests/support/support.c)
KYR_TEST_LINKAGES=(static shared)
KYR_TEST_WHITEBOX='must_fail'
KYR_TEST_EXPECT_FAIL=(must_fail_tests)
KYR_TEST_ENV=(WORD_MODE=test)
KYR_TEST_RESET=(scratch_state/marker)
KYR_COVERAGE_FAIL_UNDER_LINE=90
KYR_FUZZ_TARGETS=(len)
KYR_FUZZ_LEN_SOURCE=tests/fuzz/fuzz_len.c
KYR_FUZZ_DRIVER=tests/fuzz/driver.c
EOF
sed -i 's/^KYR_BIN=""//' utils/kyr_word_project.sh
./utils/deps.sh sysroot > /dev/null

./utils/build_libs.sh release > "${SCRATCH}/lib.log" 2>&1 || { tail -20 "${SCRATCH}/lib.log"; fail "library with a vendored source"; }
grep -q 'tiny.c (vendored)' "${SCRATCH}/lib.log" || fail "vendored source not compiled as vendored"
grep -q 'warning' "${SCRATCH}/lib.log" && fail "a vendored source warned"
./utils/build_bin.sh release > "${SCRATCH}/bin.log" 2>&1 || { tail -20 "${SCRATCH}/bin.log"; fail "binaries"; }
[[ "$(build/release/word-cli)" == 3 ]] || fail "word-cli"
readelf -d build/release/word-cli | grep -q 'NEEDED.*libkyr_word' && fail "word-cli must link the archive"
readelf -d build/release/word-cli-shared | grep -q 'NEEDED.*libkyr_word.so.0' || fail "word-cli-shared must link the shared object"
[[ "$(LD_LIBRARY_PATH=build/release build/release/word-cli-shared)" == 3 ]] || fail "word-cli-shared"
build/release/word-tool || fail "word-tool (no library)"

./utils/build_tests.sh release > "${SCRATCH}/t.log" 2>&1 || { tail -20 "${SCRATCH}/t.log"; fail "tests build"; }
[[ -x build/release/tests/env_tests && -x build/release/tests/shared/env_tests ]] || fail "static and shared test variants"
readelf -d build/release/tests/shared/env_tests | grep -q 'NEEDED.*libkyr_word.so.0' || fail "shared variant"
readelf -d build/release/tests/shared/must_fail_tests | grep -q 'NEEDED.*libkyr_word' && fail "a white-box test keeps the archive"
touch scratch_state/marker
./utils/run_tests.sh release > "${SCRATCH}/r.log" 2>&1 || { tail -20 "${SCRATCH}/r.log"; fail "tests run (env, support, reset, expected failure)"; }
[[ "$(grep -c 'failed as expected' "${SCRATCH}/r.log")" == 2 ]] || fail "expected failures not reported"
KYR_TEST_EXPECT_FAIL='' bash -c 'source utils/gcc_build_profiles.sh; source "${KYR_BUILD_DIR}/lib/kyr.sh"; KYR_TEST_EXPECT_FAIL=(); kyr_run_tests release' \
    > /dev/null 2>&1 && fail "a failing test passed"

./utils/coverage.sh > "${SCRATCH}/cov.log" 2>&1 || { tail -20 "${SCRATCH}/cov.log"; fail "coverage profile"; }
[[ -f tests/results/coverage/coverage-summary.json ]] || fail "coverage report"
sed -i 's/^KYR_COVERAGE_FAIL_UNDER_LINE=90/KYR_COVERAGE_FAIL_UNDER_LINE=101/' utils/kyr_word_project.sh
./utils/coverage.sh > /dev/null 2>&1 && fail "the coverage gate passed at 101%"

./utils/run_fuzz_smoke.sh 2 > "${SCRATCH}/fuzz.log" 2>&1 || { tail -20 "${SCRATCH}/fuzz.log"; fail "fuzz smoke"; }
mode="$(cat build/fuzz/.mode)"
if [[ "${mode}" == standalone ]]; then grep -q 'standalone over .*corpus for 2 s' "${SCRATCH}/fuzz.log" || fail "standalone driver"
else [[ "${mode}" == libfuzzer ]] || fail "fuzz mode ${mode}"; fi

./utils/run_ITs.sh > "${SCRATCH}/its.log" 2>&1 || { tail -20 "${SCRATCH}/its.log"; fail "ITs with a skip"; }
grep -q '^   skip$' "${SCRATCH}/its.log" || fail "exit 77 not reported as a skip"
