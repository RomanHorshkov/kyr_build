#!/usr/bin/env bash
# shellcheck shell=bash
# test.sh — the shared test steps behind the test wrappers (sourced by lib/build.sh): unit, integration, sanitizer and
# ThreadSanitizer runs, coverage reports and gates, the stress (benchmark) matrix, fuzzing and the package smoke test.
# Declarations come from the project file (utils/<name>_project.sh):
#
#   suites   KYR_UT_SUITES        build_UTs.sh (coverage profile) and build_UTs_release.sh (release profile, the shipped archive)
#            KYR_IT_SUITES        build_ITs.sh: every KYR_IT_PROFILES x KYR_IT_LINKAGES cell (default release x static),
#                                 then, with KYR_IT_COVERAGE=1, one coverage run reported under tests/results/ITs
#            KYR_COVERAGE_SUITES  the suites of the unit coverage run (default KYR_UT_SUITES)
#            KYR_SANITIZE_SUITES  build_sanitizer_tests.sh (default KYR_UT_SUITES and KYR_IT_SUITES)
#            KYR_TSAN_SUITES      build_tsan_tests.sh (default KYR_IT_SUITES)
#            KYR_STRESS_SUITES    build_stress.sh / run_stress.sh / run_benchmarks.sh: every source its own executable in every
#                                 KYR_STRESS_PROFILES x KYR_STRESS_LINKAGES cell (default release x static)
#   a suite  KYR_SUITE_<S>_SOURCES        quoted globs relative to the root (S: the suite name in upper case)
#            KYR_SUITE_<S>_EACH=1         one executable per source (default: one executable from every source)
#            KYR_SUITE_<S>_LINK=none      the sources include the library source themselves (white-box)
#            KYR_SUITE_<S>_CPPFLAGS       KYR_SUITE_<S>_CPPFLAGS_<RUN> (RUN: COVERAGE RELEASE IT SANITIZE TSAN STRESS)
#            KYR_SUITE_<S>_LDLIBS         default -lcmocka; the library's KYR_LIB_LDLIBS always follow it
#            KYR_SUITE_<S>_ENV KYR_SUITE_<S>_ARGS   environment and arguments of every run of its executables
#   hooks    KYR_TEST_HOOKS_CPPFLAGS      defines that turn the library's test seams on, for the library and every test source of
#                                         the runs listed in KYR_TEST_HOOKS_RUNS (default: coverage sanitize)
#   gates    KYR_UT_FAIL_UNDER_LINE/BRANCH, KYR_IT_FAIL_UNDER_LINE/BRANCH, KYR_COVERAGE_FAIL_UNDER_LINE/BRANCH (gcovr thresholds,
#            percent), KYR_COVERAGE_GCOVR_ARGS (default: --exclude tests/ --exclude app/extern/), KYR_STRESS_METRICS ("<bench>|<cost label>|<rate
#            label>": the mean read from each result file into the summary)
#   fuzzing  KYR_FUZZ_TARGETS     names; KYR_FUZZ_<T>_SOURCE the harness (LLVMFuzzerTestOneInput)
#            KYR_FUZZ_DRIVER      the standalone driver for a host without libFuzzer (main: <corpus dir> <seconds>)
#            KYR_FUZZ_LIB         sources (default: the library compiled with the fuzz flags) | archive (build/sanitize/lib<X>.a)
#            KYR_FUZZ_CPPFLAGS KYR_FUZZ_LDLIBS KYR_FUZZ_ENV KYR_FUZZ_ARGS (extra libFuzzer arguments)
#            corpus tests/fuzz/corpus[/<target>], crashes tests/fuzz/crashes/<target>-*, build/fuzz/.mode
#   smoke    KYR_SMOKE_SOURCE (tests/package/smoke.c) KYR_SMOKE_HEADER KYR_SMOKE_CPPFLAGS KYR_SMOKE_LDLIBS KYR_SMOKE_PREFIX
#
# Every executable's output is kept under tests/results/logs/<run>[/<profile>/<linkage>]/; reports under tests/results/UTs,
# tests/results/ITs/coverage, tests/results/coverage and tests/results/stress.
# Instrumented runs (coverage, sanitize, tsan) compile the library sources into the test with the run's profile, so the
# instrumentation covers the library; release cells link the archive or shared object kyr_build_lib built for the profile, the
# code that ships. Test sources always compile with -UNDEBUG after the profile flags: a test's own assert() always checks.
# A coverage run shares one library object set across its suites, so every suite's counters add up on the same sources.

KYR_TEST_RESULTS="${ROOT_DIR}/tests/results"
_KYR_EMPTY=()

_kyr_upper() { local s="${1^^}"; printf '%s\n' "${s//[^A-Z0-9]/_}"; }

# _kyr_arr <var>: KYR_REPLY=(its values), empty when undeclared
_kyr_arr() {
    KYR_REPLY=()
    declare -p "$1" > /dev/null 2>&1 || return 0
    local -n _kyr_ref="$1"
    KYR_REPLY=("${_kyr_ref[@]}")
}

# _kyr_list <var> <default var>: KYR_REPLY=(the list, or the default's when the first is undeclared)
_kyr_list() {
    if declare -p "$1" > /dev/null 2>&1; then _kyr_arr "$1"; else _kyr_arr "$2"; fi
}

_kyr_suite_sources() {
    local s pat f out=()
    s="$(_kyr_upper "$1")"
    _kyr_arr "KYR_SUITE_${s}_SOURCES"
    for pat in "${KYR_REPLY[@]}"; do
        while IFS= read -r f; do [[ -n "${f}" ]] && out+=("${f}"); done < <(cd "${ROOT_DIR}" && compgen -G "${pat}" | LC_ALL=C sort)
    done
    (( ${#out[@]} )) || kyr_die "suite $1: KYR_SUITE_${s}_SOURCES matches no file"
    KYR_REPLY=("${out[@]}")
}

# _kyr_test_profile <run> <profile>: the profile's flags plus what the run adds; KYR_TEST_HOOKS_ACTIVE for the run
_kyr_test_profile() {
    local run="$1" r
    kyr_select_profile "$2"
    if [[ "${run}" == tsan ]]; then KYR_CFLAGS+=(-fno-pie); KYR_LDFLAGS+=(-no-pie); fi
    KYR_TEST_HOOKS_ACTIVE=()
    _kyr_list KYR_TEST_HOOKS_RUNS _KYR_TEST_HOOKS_RUNS_DEFAULT
    for r in "${KYR_REPLY[@]}"; do
        [[ "${r}" == "${run}" ]] || continue
        _kyr_arr KYR_TEST_HOOKS_CPPFLAGS; KYR_TEST_HOOKS_ACTIVE=("${KYR_REPLY[@]}")
    done
    return 0
}
_KYR_TEST_HOOKS_RUNS_DEFAULT=(coverage sanitize)

# _kyr_test_lib_objects <dir>: the library sources compiled with the selected profile and the run's hooks -> KYR_TEST_LIB_OBJS
_kyr_test_lib_objects() {
    local dir="$1/lib" src obj
    KYR_TEST_LIB_OBJS=()
    mkdir -p "${dir}"
    for src in "${KYR_LIB_SOURCES[@]}"; do
        obj="${dir}/${src//\//__}.o"
        printf 'CC %s\n' "${src}"
        "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${KYR_TEST_HOOKS_ACTIVE[@]}" "${KYR_CFLAGS[@]}" -c "${src}" -o "${obj}" || kyr_die "compile failed"
        KYR_TEST_LIB_OBJS+=("${obj}")
    done
}

# _kyr_suite_build <run> <suite> <dir> <objects|static|shared> [libdir]: appends the executables to KYR_TEST_EXES and their
# suite to KYR_TEST_EXE_SUITES
_kyr_suite_build() {
    local run="$1" suite="$2" dir="$3/$2" linkage="$4" libdir="${5:-}" S R src obj link each
    S="$(_kyr_upper "${suite}")"; R="$(_kyr_upper "${run}")"
    _kyr_suite_sources "${suite}"; local srcs=("${KYR_REPLY[@]}")
    _kyr_arr "KYR_SUITE_${S}_CPPFLAGS"; local cpp=("${KYR_REPLY[@]}")
    _kyr_arr "KYR_SUITE_${S}_CPPFLAGS_${R}"; cpp+=("${KYR_REPLY[@]}" "${KYR_TEST_HOOKS_ACTIVE[@]}")
    [[ "${run}" == stress ]] || cpp+=(-UNDEBUG)
    local ldlibs=(-lcmocka)
    if declare -p "KYR_SUITE_${S}_LDLIBS" > /dev/null 2>&1; then _kyr_arr "KYR_SUITE_${S}_LDLIBS"; ldlibs=("${KYR_REPLY[@]}"); fi
    link="${linkage}"
    _kyr_arr "KYR_SUITE_${S}_LINK"; [[ "${KYR_REPLY[0]:-}" == none ]] && link=none
    _kyr_arr "KYR_SUITE_${S}_EACH"; each="${KYR_REPLY[0]:-0}"
    [[ "${run}" == stress ]] && each=1
    local lib=()
    case "${link}" in
        none) ;;
        objects) lib=("${KYR_TEST_LIB_OBJS[@]}") ;;
        static) lib=("${libdir}/lib${KYR_LIB}.a") ;;
        shared) lib=("${libdir}/lib${KYR_LIB}.so" "-Wl,-rpath,${libdir}") ;;
        *) kyr_die "unknown linkage ${link}" ;;
    esac
    mkdir -p "${dir}"
    local objs=()
    for src in "${srcs[@]}"; do
        obj="${dir}/${src//\//__}.o"
        printf 'CC %s\n' "${src}"
        "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" "${KYR_CFLAGS[@]}" -c "${src}" -o "${obj}" || kyr_die "compile failed"
        objs+=("${obj}")
    done
    if [[ "${each}" == 1 ]]; then
        local i
        for i in "${!objs[@]}"; do
            _kyr_link_test "${suite}" "${dir}/$(basename "${srcs[i]}" .c)" "${objs[i]}" "${lib[@]}" "${KYR_LIB_LDLIBS[@]}" "${ldlibs[@]}"
        done
    else
        _kyr_link_test "${suite}" "${dir}/${suite}" "${objs[@]}" "${lib[@]}" "${KYR_LIB_LDLIBS[@]}" "${ldlibs[@]}"
    fi
}

_kyr_link_test() {  # <suite> <exe> <inputs ...>
    local suite="$1" exe="$2"; shift 2
    printf 'LD %s\n' "${exe}"
    "${CC}" "${KYR_LDFLAGS[@]}" "$@" -o "${exe}" || kyr_die "link failed"
    KYR_TEST_EXES+=("${exe}")
    KYR_TEST_EXE_SUITES+=("${suite}")
}

# _kyr_exec <suite> <exe> <log>: runs one executable from the root with the suite's environment and arguments and the selected
# profile's runtime options; output kept in <log>
_kyr_exec() {
    local S pre=() envs=()
    S="$(_kyr_upper "$1")"
    case "${KYR_PROFILE}" in
        sanitize) envs=(ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 LSAN_OPTIONS=exitcode=1) ;;
        tsan)
            envs=(TSAN_OPTIONS=halt_on_error=1:history_size=7)
            # TSan's fixed shadow layout collides with large mmap randomisation on recent kernels; setarch -R turns ASLR off for
            # the child only, no privileges needed.
            pre=(timeout --signal=TERM "${KYR_TSAN_TIMEOUT:-300}")
            command -v setarch > /dev/null 2>&1 && pre+=(setarch "$(uname -m)" -R)
            ;;
    esac
    _kyr_arr "KYR_SUITE_${S}_ENV"; envs+=("${KYR_REPLY[@]}")
    _kyr_arr "KYR_SUITE_${S}_ARGS"; local args=("${KYR_REPLY[@]}")
    mkdir -p "$(dirname "$3")"
    local rc=0
    ( cd "${ROOT_DIR}" && "${pre[@]}" env "${envs[@]}" "$2" "${args[@]}" ) > "$3" 2>&1 || rc=$?
    cat "$3"
    return "${rc}"
}

# _kyr_run_exes <results dir>: every executable of KYR_TEST_EXES runs; fails when one failed
_kyr_run_exes() {
    local results="$1" i rc=0 one exe
    mkdir -p "${results}" "${KYR_TEST_RESULTS}/UTs" "${KYR_TEST_RESULTS}/ITs"
    for i in "${!KYR_TEST_EXES[@]}"; do
        exe="${KYR_TEST_EXES[i]}"
        printf 'RUN %s\n' "${exe#"${ROOT_DIR}"/}"
        one=0
        _kyr_exec "${KYR_TEST_EXE_SUITES[i]}" "${exe}" "${results}/${exe##*/}.txt" || one=$?
        if (( one )); then printf 'FAIL %s (exit %d)\n' "${exe##*/}" "${one}"; rc=1; fi
    done
    return "${rc}"
}

# _kyr_coverage_report <name> <results dir> <line%> <branch%> <object dir ...>: gcovr html/xml/txt/json-summary; a threshold
# that is set is a gate
_kyr_coverage_report() {
    local name="$1" out="$2" line="$3" branch="$4"; shift 4
    command -v gcovr > /dev/null 2>&1 || kyr_die "gcovr not found"
    cd "${ROOT_DIR}"
    local args=(-r "${ROOT_DIR}" --gcov-ignore-parse-errors negative_hits.warn_once_per_file) gate=()
    _kyr_list KYR_COVERAGE_GCOVR_ARGS _KYR_COVERAGE_GCOVR_ARGS_DEFAULT; args+=("${KYR_REPLY[@]}")
    [[ -n "${line}" ]] && gate+=(--fail-under-line "${line}")
    [[ -n "${branch}" ]] && gate+=(--fail-under-branch "${branch}")
    rm -rf "${out}"; mkdir -p "${out}"
    gcovr "${args[@]}" --html --html-details -o "${out}/${name}_coverage.html" "$@"
    gcovr "${args[@]}" --xml -o "${out}/${name}_coverage.xml" "$@"
    gcovr "${args[@]}" --txt -o "${out}/${name}_coverage.txt" "$@"
    cat "${out}/${name}_coverage.txt"
    printf 'coverage report: %s\n' "${out}/${name}_coverage.html"
    (( ${#gate[@]} )) && printf 'coverage gate: line %s%%, branch %s%%\n' "${line:-none}" "${branch:-none}"
    gcovr "${args[@]}" --json-summary -o "${out}/coverage-summary.json" "${gate[@]}" "$@"
}
_KYR_COVERAGE_GCOVR_ARGS_DEFAULT=(--exclude 'tests/' --exclude 'app/extern/')

# kyr_tests_objects <run> <profile> <dir> <suite ...>: one instrumented run: the library and every suite compiled with the
# profile into <dir>, then run
kyr_tests_objects() {
    local run="$1" profile="$2" dir="$3" suite; shift 3
    cd "${ROOT_DIR}"
    _kyr_test_profile "${run}" "${profile}"
    rm -rf "${dir}"; mkdir -p "${dir}"
    KYR_TEST_EXES=(); KYR_TEST_EXE_SUITES=()
    _kyr_test_lib_objects "${dir}"
    for suite in "$@"; do _kyr_suite_build "${run}" "${suite}" "${dir}" objects; done
    _kyr_run_exes "${KYR_TEST_RESULTS}/logs/${run}"
}

# kyr_tests_cell <run> <profile> <static|shared> <libdir> <dir> <suite ...>: suites linked against a built library, then run
kyr_tests_cell() {
    local run="$1" profile="$2" linkage="$3" libdir="$4" dir="$5" suite; shift 5
    cd "${ROOT_DIR}"
    _kyr_test_profile "${run}" "${profile}"
    rm -rf "${dir}"; mkdir -p "${dir}"
    KYR_TEST_EXES=(); KYR_TEST_EXE_SUITES=()
    for suite in "$@"; do _kyr_suite_build "${run}" "${suite}" "${dir}" "${linkage}" "${libdir}"; done
    _kyr_run_exes "${KYR_TEST_RESULTS}/logs/${run}/${profile}/${linkage}"
}

_kyr_need_suites() {  # <what> <suite ...>
    local what="$1"; shift
    (( $# )) && return 0
    printf '%s: no suites declared in the project file, nothing to do\n' "${what}"
    return 1
}

# kyr_ut_coverage: the unit coverage run (KYR_COVERAGE_SUITES, default KYR_UT_SUITES), report tests/results/UTs, gate
kyr_ut_coverage() {
    _kyr_list KYR_COVERAGE_SUITES KYR_UT_SUITES; local suites=("${KYR_REPLY[@]}")
    _kyr_need_suites "unit coverage" "${suites[@]}" || return 0
    local dir="${ROOT_DIR}/build/UTs" rc=0
    kyr_tests_objects coverage coverage "${dir}" "${suites[@]}" || rc=1
    _kyr_coverage_report UTs "${KYR_TEST_RESULTS}/UTs" "${KYR_UT_FAIL_UNDER_LINE:-}" "${KYR_UT_FAIL_UNDER_BRANCH:-}" "${dir}" || rc=1
    return "${rc}"
}

# kyr_ut_release: KYR_UT_SUITES against the release archive (built first), the code that ships
kyr_ut_release() {
    _kyr_list KYR_UT_SUITES _KYR_EMPTY; local suites=("${KYR_REPLY[@]}")
    _kyr_need_suites "unit tests (release)" "${suites[@]}" || return 0
    kyr_build_lib release
    kyr_tests_cell release release static "${ROOT_DIR}/build/release" "${ROOT_DIR}/build/UTs_release" "${suites[@]}"
}

# kyr_its: KYR_IT_SUITES in every KYR_IT_PROFILES x KYR_IT_LINKAGES cell, then the coverage run when KYR_IT_COVERAGE=1.
# When the it run carries hooks (KYR_TEST_HOOKS_RUNS), the cells link libraries built with them under build/ITs/libs.
kyr_its() {
    _kyr_list KYR_IT_SUITES _KYR_EMPTY; local suites=("${KYR_REPLY[@]}")
    _kyr_need_suites "integration tests" "${suites[@]}" || return 0
    _kyr_list KYR_IT_PROFILES _KYR_IT_PROFILES_DEFAULT; local profiles=("${KYR_REPLY[@]}")
    _kyr_list KYR_IT_LINKAGES _KYR_IT_LINKAGES_DEFAULT; local linkages=("${KYR_REPLY[@]}")
    local profile linkage libroot="${ROOT_DIR}/build" rc=0 hooks=()
    _kyr_test_profile it release; hooks=("${KYR_TEST_HOOKS_ACTIVE[@]}")
    (( ${#hooks[@]} )) && libroot="${ROOT_DIR}/build/ITs/libs"
    for profile in "${profiles[@]}"; do
        kyr_build_lib "${profile}" "${libroot}" "${hooks[@]}"
        for linkage in "${linkages[@]}"; do
            printf '\n[ITs %s/%s]\n' "${profile}" "${linkage}"
            kyr_tests_cell it "${profile}" "${linkage}" "${libroot}/${profile}" "${ROOT_DIR}/build/ITs/${profile}/${linkage}" "${suites[@]}" || rc=1
        done
    done
    if [[ "${KYR_IT_COVERAGE:-0}" == 1 ]]; then
        printf '\n[ITs coverage]\n'
        local dir="${ROOT_DIR}/build/ITs/coverage"
        kyr_tests_objects it coverage "${dir}" "${suites[@]}" || rc=1
        _kyr_coverage_report ITs "${KYR_TEST_RESULTS}/ITs/coverage" "${KYR_IT_FAIL_UNDER_LINE:-}" "${KYR_IT_FAIL_UNDER_BRANCH:-}" "${dir}" || rc=1
    fi
    return "${rc}"
}
_KYR_IT_PROFILES_DEFAULT=(release)
_KYR_IT_LINKAGES_DEFAULT=(static)

# kyr_sanitize: KYR_SANITIZE_SUITES (default UT + IT suites) under ASan, UBSan and LSan
kyr_sanitize() {
    local suites=()
    if declare -p KYR_SANITIZE_SUITES > /dev/null 2>&1; then _kyr_arr KYR_SANITIZE_SUITES; suites=("${KYR_REPLY[@]}")
    else _kyr_arr KYR_UT_SUITES; suites=("${KYR_REPLY[@]}"); _kyr_arr KYR_IT_SUITES; suites+=("${KYR_REPLY[@]}"); fi
    _kyr_need_suites "sanitizer tests" "${suites[@]}" || return 0
    kyr_tests_objects sanitize sanitize "${ROOT_DIR}/build/sanitizers" "${suites[@]}"
}

# kyr_tsan: KYR_TSAN_SUITES (default IT suites) under ThreadSanitizer
kyr_tsan() {
    _kyr_list KYR_TSAN_SUITES KYR_IT_SUITES; local suites=("${KYR_REPLY[@]}")
    _kyr_need_suites "ThreadSanitizer tests" "${suites[@]}" || return 0
    kyr_tests_objects tsan tsan "${ROOT_DIR}/build/tsan" "${suites[@]}"
}

# kyr_stress_build: every source of KYR_STRESS_SUITES as its own executable in every KYR_STRESS_PROFILES x KYR_STRESS_LINKAGES
# cell (default release x static), build/stress/<profile>/<linkage>/<suite>/<bench>; build/stress/manifest.tsv lists them
kyr_stress_build() {
    _kyr_list KYR_STRESS_SUITES _KYR_EMPTY; local suites=("${KYR_REPLY[@]}")
    _kyr_need_suites "stress build" "${suites[@]}" || return 0
    _kyr_list KYR_STRESS_PROFILES _KYR_IT_PROFILES_DEFAULT; local profiles=("${KYR_REPLY[@]}")
    _kyr_list KYR_STRESS_LINKAGES _KYR_IT_LINKAGES_DEFAULT; local linkages=("${KYR_REPLY[@]}")
    local manifest="${ROOT_DIR}/build/stress/manifest.tsv" profile linkage suite i
    rm -rf "${ROOT_DIR}/build/stress"; mkdir -p "${ROOT_DIR}/build/stress"
    printf '# profile\tlinkage\tsuite\tbenchmark\texecutable\n' > "${manifest}"
    for profile in "${profiles[@]}"; do
        kyr_build_lib "${profile}"
        for linkage in "${linkages[@]}"; do
            cd "${ROOT_DIR}"
            _kyr_test_profile stress "${profile}"
            KYR_TEST_EXES=(); KYR_TEST_EXE_SUITES=()
            for suite in "${suites[@]}"; do
                _kyr_suite_build stress "${suite}" "${ROOT_DIR}/build/stress/${profile}/${linkage}" "${linkage}" "${ROOT_DIR}/build/${profile}"
            done
            for i in "${!KYR_TEST_EXES[@]}"; do
                printf '%s\t%s\t%s\t%s\t%s\n' "${profile}" "${linkage}" "${KYR_TEST_EXE_SUITES[i]}" "${KYR_TEST_EXES[i]##*/}" "${KYR_TEST_EXES[i]}" >> "${manifest}"
            done
        done
    done
    printf 'stress manifest: %s\n' "${manifest}"
}

# kyr_stress_run: every manifest row; output tests/results/stress/<profile>/<linkage>/<bench>_result.txt, summary
# tests/results/stress/stress_summary.tsv with the means KYR_STRESS_METRICS names; fails when a benchmark failed
kyr_stress_run() {
    local manifest="${ROOT_DIR}/build/stress/manifest.tsv" results="${KYR_TEST_RESULTS}/stress"
    if [[ ! -f "${manifest}" ]]; then
        _kyr_list KYR_STRESS_SUITES _KYR_EMPTY; _kyr_need_suites "stress run" "${KYR_REPLY[@]}" || return 0
        kyr_die "no ${manifest} (run build_stress.sh first)"
    fi
    local summary="${results}/stress_summary.tsv" profile linkage suite bench exe out rc=0 one cost rate m mb mc mr
    rm -rf "${results}"; mkdir -p "${results}"
    printf '# status\tprofile\tlinkage\tbenchmark\tmean_cost\tmean_rate\tresult\n' > "${summary}"
    while IFS=$'\t' read -r profile linkage suite bench exe; do
        [[ -z "${profile}" || "${profile}" == \#* ]] && continue
        out="${results}/${profile}/${linkage}/${bench}_result.txt"
        printf '\n[%s/%s/%s]\n' "${profile}" "${linkage}" "${bench}"
        KYR_PROFILE=stress one=0
        _kyr_exec "${suite}" "${exe}" "${out}" || one=$?
        cost=NA; rate=NA
        _kyr_arr KYR_STRESS_METRICS
        for m in "${KYR_REPLY[@]}"; do
            IFS='|' read -r mb mc mr <<< "${m}"
            [[ "${mb}" == "${bench}" ]] || continue
            cost="$(_kyr_stress_mean "${mc}" "${out}")"; rate="$(_kyr_stress_mean "${mr}" "${out}")"
        done
        if (( one )); then printf 'FAIL\t' >> "${summary}"; rc=1; printf 'FAIL %s (exit %d)\n' "${bench}" "${one}"; else printf 'PASS\t' >> "${summary}"; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${profile}" "${linkage}" "${bench}" "${cost:-NA}" "${rate:-NA}" "${out#"${ROOT_DIR}"/}" >> "${summary}"
    done < "${manifest}"
    printf '\n[stress summary] %s\n' "${summary}"
    column -t -s $'\t' "${summary}" 2> /dev/null || cat "${summary}"
    return "${rc}"
}

_kyr_stress_mean() {  # <label> <file>: the "  mean: <v>" line under the section titled <label>
    awk -v want="$1" '$0 == want { s = 1; next } s && /^  mean:/ { print $2; exit } s && /^[^ ]/ { s = 0 }' "$2"
}

# kyr_coverage: the coverage profile end to end for a repository with per-profile tests (build_tests.sh): library and tests at
# the coverage profile, run, report under tests/results/coverage, KYR_COVERAGE_FAIL_UNDER_LINE/BRANCH as the gate
kyr_coverage() {
    local rc=0
    [[ -n "${KYR_LIB:-}" ]] && kyr_build_lib coverage
    kyr_build_tests coverage
    kyr_run_tests coverage || rc=1
    _kyr_coverage_report coverage "${KYR_TEST_RESULTS}/coverage" "${KYR_COVERAGE_FAIL_UNDER_LINE:-}" "${KYR_COVERAGE_FAIL_UNDER_BRANCH:-}" \
        "${ROOT_DIR}/build/coverage" || rc=1
    return "${rc}"
}

_kyr_has_libfuzzer() {
    command -v clang > /dev/null 2>&1 || return 1
    local t; t="$(mktemp -d)"
    printf '#include <stddef.h>\n#include <stdint.h>\nint LLVMFuzzerTestOneInput(const uint8_t* d, size_t n) { (void)d; (void)n; return 0; }\n' > "${t}/p.c"
    clang -fsanitize=fuzzer "${t}/p.c" -o "${t}/p" > /dev/null 2>&1
    local rc=$?
    rm -rf "${t}"
    return "${rc}"
}

# kyr_fuzz_build: every KYR_FUZZ_TARGETS harness as build/fuzz/<target>: libFuzzer with ASan and UBSan when clang supports it,
# otherwise the gcc sanitize profile with KYR_FUZZ_DRIVER; build/fuzz/.mode says which
kyr_fuzz_build() {
    _kyr_list KYR_FUZZ_TARGETS _KYR_EMPTY; local targets=("${KYR_REPLY[@]}") t src mode lib=() v
    _kyr_need_suites "fuzz build" "${targets[@]}" || return 0
    cd "${ROOT_DIR}"
    _kyr_arr KYR_FUZZ_CPPFLAGS; local cpp=("${KYR_REPLY[@]}")
    _kyr_arr KYR_FUZZ_LDLIBS; local ldlibs=("${KYR_REPLY[@]}")
    local out="${ROOT_DIR}/build/fuzz" vendor=()
    declare -p KYR_LIB_VENDOR_SOURCES > /dev/null 2>&1 && vendor=("${KYR_LIB_VENDOR_SOURCES[@]}")
    rm -rf "${out}"; mkdir -p "${out}"
    if [[ "${KYR_FUZZ_LIB:-sources}" == archive ]]; then kyr_build_lib sanitize; lib=("${ROOT_DIR}/build/sanitize/lib${KYR_LIB}.a")
    else lib=("${KYR_LIB_SOURCES[@]}"); fi
    if _kyr_has_libfuzzer; then mode=libfuzzer; else mode=standalone; fi
    if [[ "${mode}" == libfuzzer && "${KYR_FUZZ_LIB:-sources}" != archive ]]; then lib+=("${vendor[@]}"); fi
    printf '%s\n' "${mode}" > "${out}/.mode"
    for t in "${targets[@]}"; do
        v="KYR_FUZZ_$(_kyr_upper "${t}")_SOURCE"; src="${!v:-}"
        [[ -n "${src}" ]] || kyr_die "fuzz target ${t}: ${v} is not set"
        printf 'FUZZ %s (%s)\n' "${t}" "${mode}"
        if [[ "${mode}" == libfuzzer ]]; then
            clang -g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer,address,undefined "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" \
                "${lib[@]}" "${src}" "${KYR_LIB_LDLIBS[@]}" "${ldlibs[@]}" -o "${out}/${t}" || kyr_die "link failed"
        else
            [[ -n "${KYR_FUZZ_DRIVER:-}" ]] || kyr_die "no libFuzzer here and no KYR_FUZZ_DRIVER for the standalone mode"
            kyr_select_profile sanitize
            local objs=() s
            mkdir -p "${out}/obj"
            if [[ "${KYR_FUZZ_LIB:-sources}" != archive ]]; then
                for s in "${KYR_LIB_SOURCES[@]}"; do
                    "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" "${KYR_CFLAGS[@]}" -c "${s}" -o "${out}/obj/${s//\//__}.o" || kyr_die "compile failed"
                    objs+=("${out}/obj/${s//\//__}.o")
                done
                for s in "${vendor[@]}"; do
                    "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" "${KYR_CFLAGS[@]}" -w -c "${s}" -o "${out}/obj/${s//\//__}.o" || kyr_die "compile failed"
                    objs+=("${out}/obj/${s//\//__}.o")
                done
            else
                objs=("${lib[@]}")
            fi
            "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" "${KYR_CFLAGS[@]}" "${src}" "${KYR_FUZZ_DRIVER}" "${objs[@]}" \
                "${KYR_LDFLAGS[@]}" "${KYR_LIB_LDLIBS[@]}" "${ldlibs[@]}" -o "${out}/${t}" || kyr_die "link failed"
        fi
    done
}

# kyr_fuzz_smoke [seconds]: a bounded pass over every target (the budget split evenly, at least one second each)
kyr_fuzz_smoke() {
    local total="${1:-60}" t per corpus rc=0 one
    kyr_fuzz_build || return 1
    _kyr_list KYR_FUZZ_TARGETS _KYR_EMPTY; local targets=("${KYR_REPLY[@]}")
    (( ${#targets[@]} )) || return 0
    per=$(( total / ${#targets[@]} )); (( per >= 1 )) || per=1
    local mode; mode="$(cat "${ROOT_DIR}/build/fuzz/.mode")"
    _kyr_arr KYR_FUZZ_ENV; local envs=("${KYR_REPLY[@]}")
    _kyr_arr KYR_FUZZ_ARGS; local args=("${KYR_REPLY[@]}")
    mkdir -p "${ROOT_DIR}/tests/fuzz/crashes"
    for t in "${targets[@]}"; do
        corpus="${ROOT_DIR}/tests/fuzz/corpus"; [[ -d "${corpus}/${t}" ]] && corpus="${corpus}/${t}"
        printf '\n[fuzz %s: %s s, %s]\n' "${t}" "${per}" "${mode}"
        one=0
        if [[ "${mode}" == libfuzzer ]]; then
            mkdir -p "${ROOT_DIR}/build/fuzz/work_${t}"
            ( cd "${ROOT_DIR}" && env "${envs[@]}" "build/fuzz/${t}" -max_total_time="${per}" -artifact_prefix="tests/fuzz/crashes/${t}-" \
                -print_final_stats=1 "${args[@]}" "build/fuzz/work_${t}" "${corpus}" ) || one=$?
        else
            ( cd "${ROOT_DIR}" && env ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "${envs[@]}" \
                "build/fuzz/${t}" "${corpus}" "${per}" ) || one=$?
        fi
        (( one )) && { printf 'FAIL fuzz %s (exit %d)\n' "${t}" "${one}"; rc=1; }
    done
    return "${rc}"
}

# kyr_run_it_scripts: every KYR_IT_SCRIPTS script (quoted globs, default tests/ITs/*.sh) with bash, from the root, with ROOT_DIR,
# KYR_BUILD_DIR, KYR_BUILD_OUT (build/release) and KYR_IT_ENV exported; exit 77 is a skip. KYR_IT_BUILD_FIRST=1 builds the
# release library and binaries first.
kyr_run_it_scripts() {
    local pats=('tests/ITs/*.sh') pat t rc=0 one n=0
    declare -p KYR_IT_SCRIPTS > /dev/null 2>&1 && pats=("${KYR_IT_SCRIPTS[@]}")
    if [[ "${KYR_IT_BUILD_FIRST:-0}" == 1 ]]; then
        [[ -n "${KYR_LIB:-}" ]] && kyr_build_lib release
        kyr_bin_names; (( ${#KYR_REPLY[@]} )) && kyr_build_bin release
    fi
    _kyr_arr KYR_IT_ENV; local envs=("${KYR_REPLY[@]}")
    export ROOT_DIR KYR_BUILD_DIR KYR_BUILD_OUT="${ROOT_DIR}/build/release"
    for pat in "${pats[@]}"; do
        while IFS= read -r t; do
            [[ -f "${ROOT_DIR}/${t}" ]] || continue
            n=$((n + 1)); one=0
            printf '== %s\n' "${t}"
            ( cd "${ROOT_DIR}" && env "${envs[@]}" bash "${t}" ) || one=$?
            case "${one}" in 0) printf '   ok\n' ;; 77) printf '   skip\n' ;; *) printf '   FAIL (exit %d)\n' "${one}"; rc=1 ;; esac
        done < <(cd "${ROOT_DIR}" && compgen -G "${pat}" | LC_ALL=C sort)
    done
    (( n )) || printf 'run_ITs: no integration script matched %s\n' "${pats[*]}"
    return "${rc}"
}

# kyr_smoke_package: compiles KYR_SMOKE_SOURCE (default tests/package/smoke.c) against the INSTALLED package only
# (${KYR_SMOKE_PREFIX:-/usr/local}: include/, lib/), never the build tree, and runs it. KYR_SMOKE_HEADER (default KYR_LIB_HEADER
# below app/include or app) must be installed; KYR_SMOKE_CPPFLAGS and KYR_SMOKE_LDLIBS add to the compile and the link.
kyr_smoke_package() {
    local prefix="${KYR_SMOKE_PREFIX:-/usr/local}" src="${ROOT_DIR}/${KYR_SMOKE_SOURCE:-tests/package/smoke.c}" header work rc=0
    header="${KYR_LIB_HEADER:-${KYR_LIB}.h}"; header="${header#app/include/}"; header="${KYR_SMOKE_HEADER:-${header#app/}}"
    [[ -f "${prefix}/include/${header}" ]] || kyr_die "${prefix}/include/${header} not found: install the debs first"
    [[ -f "${src}" ]] || kyr_die "no smoke program ${src}"
    _kyr_arr KYR_SMOKE_CPPFLAGS; local cpp=("${KYR_REPLY[@]}")
    _kyr_arr KYR_SMOKE_LDLIBS; local ldlibs=("${KYR_REPLY[@]}")
    work="$(mktemp -d)"
    if "${CC}" -std=c11 -Wall -Wextra -Werror "${cpp[@]}" -I"${prefix}/include" "${src}" \
        -L"${prefix}/lib" -Wl,-rpath,"${prefix}/lib" -l"${KYR_LIB}" "${ldlibs[@]}" -o "${work}/smoke"; then
        "${work}/smoke" || rc=$?
    else
        rc=1
    fi
    rm -rf "${work}"
    return "${rc}"
}
