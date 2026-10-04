#!/usr/bin/env bash
# A foundation-shaped library on the suite wrappers alone: unit suites under coverage (one shared object set, the 100% gate,
# test hooks in the coverage run only) and against the release archive (tests keep their asserts), the integration matrix plus
# its coverage run, sanitizers, the stress manifest with its metrics, the package smoke test against the built debs, and the
# pipeline's extra-stage hook (a declared repository gate runs; a failing one fails the pipeline).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
for w in build_UTs.sh build_UTs_release.sh build_ITs.sh build_sanitizer_tests.sh build_stress.sh run_stress.sh; do
    cp "${SCRATCH}/kb/usr/local/share/kyr-build/wrappers/${w}" utils/
done
cat > app/src/word.c <<'EOF'
#include "kyr/word/word.h"

#include <string.h>

size_t kyr_word_len(const char* s)
{
    return s ? strlen(s) : 0;
}

#ifdef KYR_WORD_TESTING
int kyr_word_test_seam(void)
{
    return 42;
}
#endif
EOF
mkdir -p tests/ITs tests/stress tests/package
cat > tests/UTs/suite_tests.c <<'EOF'
#include <assert.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include <cmocka.h>

#include "kyr/word/word.h"

#ifdef NDEBUG
#    error "a test compiles without NDEBUG"
#endif

#ifdef KYR_WORD_TESTING
int kyr_word_test_seam(void);
#endif

static void len_counts(void** state)
{
    (void)state;
    assert(kyr_word_len("kyr") == 3);
    assert_int_equal(kyr_word_len(NULL), 0);
#ifdef KYR_WORD_TESTING
    assert_int_equal(kyr_word_test_seam(), 42);
#endif
}

int main(void)
{
    const struct CMUnitTest tests[] = {cmocka_unit_test(len_counts)};
    return cmocka_run_group_tests(tests, NULL, NULL);
}
EOF
cat > tests/ITs/word_it.c <<'EOF'
#include <stdio.h>

#include "kyr/word/word.h"

int main(void)
{
    FILE* f = fopen("tests/results/ITs/it_ran.txt", "w");
    if(!f)
    {
        return 2;
    }
    fprintf(f, "%zu\n", kyr_word_len("four"));
    fclose(f);
    return kyr_word_len("four") == 4 ? 0 : 1;
}
EOF
cat > tests/stress/bench.c <<'EOF'
#include <stdio.h>

#include "kyr/word/word.h"

int main(void)
{
    printf("cost per op\n  mean: %zu.5\nthroughput\n  mean: 80\n", kyr_word_len("123456789012"));
    return 0;
}
EOF
cat >> utils/kyr_word_project.sh <<'EOF'
KYR_TEST_HOOKS_CPPFLAGS=(-DKYR_WORD_TESTING)
KYR_UT_SUITES=(ut)
KYR_SUITE_UT_SOURCES=(tests/UTs/suite_tests.c)
KYR_UT_FAIL_UNDER_LINE=100
KYR_UT_FAIL_UNDER_BRANCH=100
KYR_IT_SUITES=(it)
KYR_SUITE_IT_SOURCES=(tests/ITs/word_it.c)
KYR_SUITE_IT_LDLIBS=()
KYR_IT_PROFILES=(release debug)
KYR_IT_LINKAGES=(static shared)
KYR_IT_COVERAGE=1
KYR_STRESS_SUITES=(bench)
KYR_SUITE_BENCH_SOURCES=(tests/stress/bench.c)
KYR_SUITE_BENCH_LDLIBS=()
KYR_STRESS_METRICS=("bench|cost per op|throughput")
KYR_REPO_GATES=(check_word.sh)
KYR_PIPELINE_EXTRA=("checks|word-gate|./utils/check_word.sh")
EOF
printf '#!/usr/bin/env bash\necho gate ran > build/word_gate.txt\n' > utils/check_word.sh; chmod +x utils/check_word.sh
g() { git -c user.name=it -c user.email=it@localhost "$@" > /dev/null; }
g add -A; g commit -q -m suites
./utils/deps.sh sysroot > /dev/null

./utils/build_UTs.sh > "${SCRATCH}/ut.log" 2>&1 || { tail -30 "${SCRATCH}/ut.log"; fail "coverage run"; }
grep -q 'coverage gate: line 100%, branch 100%' "${SCRATCH}/ut.log" || fail "the gate was not applied"
[[ -f tests/results/UTs/coverage-summary.json && -f tests/results/UTs/UTs_coverage.html ]] || fail "unit coverage report"
nm build/UTs/lib/*.o | grep -q kyr_word_test_seam || fail "the coverage run's library has no hooks"
./utils/build_UTs_release.sh > "${SCRATCH}/rel.log" 2>&1 || { tail -30 "${SCRATCH}/rel.log"; fail "release unit run (a test compiled with NDEBUG?)"; }
nm build/release/libkyr_word.a | grep -q kyr_word_test_seam && fail "the release archive carries a test hook"

./utils/build_ITs.sh > "${SCRATCH}/it.log" 2>&1 || { tail -30 "${SCRATCH}/it.log"; fail "integration matrix"; }
[[ "$(grep -c '^RUN ' "${SCRATCH}/it.log")" == 5 ]] || fail "4 cells and one coverage run expected"
[[ -f tests/results/ITs/coverage/coverage-summary.json && -f tests/results/ITs/it_ran.txt ]] || fail "integration coverage report"
readelf -d build/ITs/release/shared/it/it | grep -q 'NEEDED.*libkyr_word.so.0' || fail "shared cell not linked against the shared object"

./utils/build_sanitizer_tests.sh > "${SCRATCH}/san.log" 2>&1 || { tail -30 "${SCRATCH}/san.log"; fail "sanitizer run"; }
./utils/build_stress.sh > "${SCRATCH}/sb.log" 2>&1 && ./utils/run_stress.sh > "${SCRATCH}/sr.log" 2>&1 || { tail -30 "${SCRATCH}/sb.log" "${SCRATCH}/sr.log"; fail "stress"; }
grep -qP '^PASS\trelease\tstatic\tbench\t12\.5\t80\t' tests/results/stress/stress_summary.tsv || { cat tests/results/stress/stress_summary.tsv; fail "stress metrics"; }

# The gate fails a run below it.
printf 'int kyr_word_never_called(int x)\n{\n    return x > 1 ? x : -x;\n}\n' >> app/src/word.c
./utils/build_UTs.sh > "${SCRATCH}/ut2.log" 2>&1 && fail "coverage below 100% passed the gate"
g checkout -q app/src/word.c

# A failing test fails the run, and every executable still runs.
sed -i 's/kyr_word_len("four") == 4/kyr_word_len("four") == 5/' tests/ITs/word_it.c
./utils/build_ITs.sh > "${SCRATCH}/it2.log" 2>&1 && fail "a failing integration test passed"
[[ "$(grep -c '^FAIL ' "${SCRATCH}/it2.log")" == 5 ]] || fail "every cell must run and report"
g checkout -q tests/ITs/word_it.c

./utils/run_pipeline.sh > "${SCRATCH}/pipeline.log" 2>&1 || { tail -40 "${SCRATCH}/pipeline.log"; fail "pipeline"; }
for s in word-gate unit-tests-release unit-tests integration sanitizers stress-build stress-run package package-smoke; do
    grep -q "^== ${s}$" "${SCRATCH}/pipeline.log" || fail "pipeline stage ${s} missing"
done
[[ -f build/word_gate.txt ]] || fail "the extra stage did not run"
printf '#!/usr/bin/env bash\nexit 3\n' > utils/check_word.sh
./utils/run_pipeline.sh > "${SCRATCH}/pipeline2.log" 2>&1 && fail "a failing extra stage left the pipeline green"
grep -q '^   FAIL word-gate' "${SCRATCH}/pipeline2.log" || fail "the failing extra stage is not in the summary"
