#!/usr/bin/env bash
# pipeline.sh — the one pipeline every repository runs through its utils/run_pipeline.sh wrapper (which resolves the sysroot
# first). Each stage logs to build/pipeline/<stage>.log; the run keeps going past a failure (KYR_PIPELINE_FAIL_FAST=1 stops at
# the first) and ends GREEN only when no stage failed. A stage runs when the repository has the wrapper it needs, the same
# detection cicd's c-quality.yml makes, so the local pipeline and CI run the same gates:
#
#   deps-tiers   template   format (with the pinned clang-format major, else SKIP)   vendor (app/extern)   [checks]
#   abi (abi/layout.txt)   build:<p> (build_libs.sh)   build-bin:<p> (build_bin.sh)   abi-exports   [build]
#   unit-tests-release unit-tests integration integration-release sanitizers tsan stress-build stress-run (the suite wrappers)
#   tests-build:<p> tests:<p> (build_tests.sh, run_tests.sh)   coverage   ITs (run_ITs.sh)   fuzz-smoke   benchmarks   [tests]
#   package (build_deb.sh)   package-smoke (smoke_test_package.sh against the built debs extracted into build/smoke)
#   reproducible (check_reproducible.sh, when the build inputs are committed)   [post]
#
# [point] is the extra-stage hook: KYR_PIPELINE_EXTRA in the project file, entries "<point>|<label>|<command>", point one of
# checks, build, tests, post; the command runs with bash -c from the root, e.g. "checks|core-neutral|./utils/check_core_neutral.sh".
# Knobs: KYR_PIPELINE_PROFILES (build profiles; default KYR_LIB_PROFILES, else the catalog's), KYR_TEST_PROFILES (default audit
# sanitize release), KYR_FUZZ_SECONDS (10), KYR_CLANG_FORMAT_MAJOR (18), GCC_BUILD_ENABLE_TSAN=1 for the tsan stage.
set -uo pipefail
ROOT_DIR="${ROOT_DIR:?run through utils/run_pipeline.sh}"
cd -- "${ROOT_DIR}"
# shellcheck source=/dev/null
source "${ROOT_DIR}/utils/gcc_build_profiles.sh" || exit 1
# shellcheck source=lib/kyr.sh
source "${KYR_BUILD_DIR}/lib/kyr.sh"
LOG_DIR="${ROOT_DIR}/build/pipeline"
rm -rf "${LOG_DIR}"; mkdir -p "${LOG_DIR}"
RESULTS=()
FAILED=0

stage() {
    local label="$1" log rc; shift
    log="${LOG_DIR}/${label//[^A-Za-z0-9_.-]/_}.log"
    printf '== %s\n' "${label}"
    ( "$@" ) > "${log}" 2>&1; rc=$?
    if (( rc == 0 )); then
        printf '   ok  (%s)\n' "${log#"${ROOT_DIR}"/}"; RESULTS+=("ok   ${label}")
    else
        printf '   FAIL (exit %s) -> %s\n' "${rc}" "${log}"; tail -n 15 "${log}" | sed 's/^/      /'
        RESULTS+=("FAIL ${label}"); FAILED=1
        if [[ "${KYR_PIPELINE_FAIL_FAST:-0}" == 1 ]]; then summary; exit 1; fi
    fi
}
skip() { printf '== %s\n   SKIP: %s\n' "$1" "$2"; RESULTS+=("SKIP $1 ($2)"); }
has() { [[ -x "${ROOT_DIR}/utils/$1" ]]; }
hook() {
    local point="$1" entry p label cmd
    declare -p KYR_PIPELINE_EXTRA > /dev/null 2>&1 || return 0
    for entry in "${KYR_PIPELINE_EXTRA[@]}"; do
        IFS='|' read -r p label cmd <<< "${entry}"
        [[ "${p}" == "${point}" ]] || continue
        [[ -n "${label}" && -n "${cmd}" ]] || { RESULTS+=("FAIL bad KYR_PIPELINE_EXTRA entry '${entry}'"); FAILED=1; continue; }
        stage "${label}" bash -c "${cmd}"
    done
}
summary() {
    local r
    printf '\n== summary\n'
    for r in "${RESULTS[@]}"; do printf '   %s\n' "${r}"; done
    [[ -f build/debs/SHA256SUMS ]] && { printf '\n== debs (build/debs/SHA256SUMS)\n'; sed 's/^/   /' build/debs/SHA256SUMS; }
}

clang_format_pinned() {  # prints the clang-format binary of the pinned major, if any
    local major="${KYR_CLANG_FORMAT_MAJOR:-18}" c
    if [[ -n "${CLANG_FORMAT:-}" ]]; then command -v "${CLANG_FORMAT}" > /dev/null && printf '%s\n' "${CLANG_FORMAT}"; return; fi
    for c in "clang-format-${major}" clang-format; do
        command -v "${c}" > /dev/null 2>&1 || continue
        [[ "$("${c}" --version)" =~ version\ ${major}\. ]] && { printf '%s\n' "${c}"; return; }
    done
}

if declare -p KYR_PIPELINE_PROFILES > /dev/null 2>&1; then PROFILES=("${KYR_PIPELINE_PROFILES[@]}")
elif declare -p KYR_LIB_PROFILES > /dev/null 2>&1; then PROFILES=("${KYR_LIB_PROFILES[@]}")
else PROFILES=("${GCC_BUILD_PROFILES[@]}"); fi
TEST_PROFILES=(audit sanitize release)
declare -p KYR_TEST_PROFILES > /dev/null 2>&1 && TEST_PROFILES=("${KYR_TEST_PROFILES[@]}")
kyr_bin_names; BINS=("${KYR_REPLY[@]}")

stage deps-tiers ./utils/deps.sh check --tiers
stage template "${KYR_BUILD_DIR}/template_check.sh" "${ROOT_DIR}"
if has format.sh; then
    CF="$(clang_format_pinned)"
    if [[ -n "${CF}" ]]; then stage format env CLANG_FORMAT="${CF}" ./utils/format.sh --check
    else skip format "clang-format ${KYR_CLANG_FORMAT_MAJOR:-18} not installed (the major CI pins)"; fi
fi
[[ -d app/extern ]] && has vendor.sh && stage vendor ./utils/vendor.sh verify
hook checks
[[ -f abi/layout.txt ]] && stage abi ./utils/check_abi.sh
if has build_libs.sh && [[ -n "${KYR_LIB:-}" ]]; then
    for p in "${PROFILES[@]}"; do stage "build:${p}" ./utils/build_libs.sh "${p}"; done
fi
if has build_bin.sh && (( ${#BINS[@]} )); then
    for p in "${PROFILES[@]}"; do stage "build-bin:${p}" ./utils/build_bin.sh "${p}"; done
fi
[[ -f abi/layout.txt ]] && stage abi-exports ./utils/check_abi.sh --exports
hook build
has build_UTs_release.sh && stage unit-tests-release ./utils/build_UTs_release.sh
has build_UTs.sh && stage unit-tests ./utils/build_UTs.sh
has build_ITs.sh && stage integration ./utils/build_ITs.sh
has build_ITs_release.sh && stage integration-release ./utils/build_ITs_release.sh
has build_sanitizer_tests.sh && stage sanitizers ./utils/build_sanitizer_tests.sh
if has build_tsan_tests.sh; then
    if [[ "${GCC_BUILD_ENABLE_TSAN:-0}" == 1 ]]; then stage tsan ./utils/build_tsan_tests.sh
    else skip tsan "GCC_BUILD_ENABLE_TSAN=1 runs it (CI runs it on its own runner)"; fi
fi
has build_stress.sh && stage stress-build ./utils/build_stress.sh
has run_stress.sh && stage stress-run ./utils/run_stress.sh
if has run_tests.sh && declare -p KYR_TEST_SOURCES > /dev/null 2>&1 && (( ${#KYR_TEST_SOURCES[@]} )); then
    for p in "${TEST_PROFILES[@]}"; do
        has build_tests.sh && stage "tests-build:${p}" ./utils/build_tests.sh "${p}"
        stage "tests:${p}" ./utils/run_tests.sh "${p}"
    done
fi
has coverage.sh && stage coverage ./utils/coverage.sh
has run_ITs.sh && stage ITs ./utils/run_ITs.sh
has run_fuzz_smoke.sh && stage fuzz-smoke ./utils/run_fuzz_smoke.sh "${KYR_FUZZ_SECONDS:-10}"
has run_benchmarks.sh && stage benchmarks ./utils/run_benchmarks.sh
hook tests
has build_deb.sh && stage package ./utils/build_deb.sh
if has smoke_test_package.sh && [[ "${RESULTS[-1]:-}" == "ok   package" ]]; then
    # the installed-package test against the debs just built, extracted into build/smoke instead of /usr/local
    stage package-smoke bash -c 'rm -rf build/smoke && mkdir -p build/smoke && for d in build/debs/*.deb; do dpkg-deb -x "${d}" build/smoke; done &&
        KYR_SMOKE_PREFIX="${PWD}/build/smoke/usr/local" ./utils/smoke_test_package.sh'
fi
if has check_reproducible.sh; then
    if ./utils/check_reproducible.sh --inputs-clean; then stage reproducible ./utils/check_reproducible.sh
    else skip reproducible "uncommitted build inputs"; fi
fi
hook post
summary
(( FAILED )) && { printf 'pipeline FAILED\n'; exit 1; }
printf 'pipeline GREEN\n'
