#!/usr/bin/env bash
# shellcheck shell=bash
# build.sh — the shared build steps a repository's thin utils/ wrappers call (through lib/kyr.sh). Source the profile catalog and
# the repository's utils/<name>_project.sh first; that file declares (only what applies):
#
#   library   KYR_LIB                 lib<KYR_LIB>.so.<ver>, lib<KYR_LIB>.a
#             KYR_LIB_SOURCES         C sources, relative to ROOT_DIR
#             KYR_LIB_VENDOR_SOURCES  vendored sources (app/extern): the profile's flags without its warnings and without
#                                     KYR_VENDOR_DROP_CFLAGS (default -fanalyzer), then KYR_LIB_VENDOR_CFLAGS, the warning flags
#                                     the vendored code is built under (default none: GCC's own); -Werror holds, never -w
#             KYR_LIB_CPPFLAGS        include and define flags (default -I<root>/app/include)
#             KYR_LIB_LDLIBS          what the shared link needs
#             KYR_LIB_MAP             version script; its <NODE>_<n> node must name VERSION's major
#             KYR_LIB_PROFILES        what build_libs.sh builds without arguments (default: every catalog profile)
#   binaries  KYR_BINS                names; per binary KYR_BIN_<B>_SOURCES, _CPPFLAGS, _LDLIBS, _LINK (static | shared | none;
#                                     default static with a library, none without) (B: the name in upper case, - and . as _)
#             KYR_BIN                 one binary, the older form: KYR_BIN_SOURCES, KYR_BIN_LDLIBS, linked against the archive
#   tests     KYR_TEST_SOURCES        one cmocka executable each, build/<profile>/tests/<name>, compiled with -UNDEBUG
#             KYR_TEST_SUPPORT_SOURCES  compiled once per profile with the test flags, linked into every test
#             KYR_TEST_CPPFLAGS       test and support compiles     KYR_TEST_LDLIBS   extra libraries for the tests
#             KYR_TEST_LIB_LDLIBS     replaces KYR_LIB_LDLIBS on the test link (a test that links the core's archive, say)
#             KYR_TEST_LINKAGES       static (default) and/or shared: build/<profile>/tests/shared/<name> against the .so
#             KYR_TEST_WHITEBOX       an ERE: a test whose source matches it links the archive in the shared variant too
#             KYR_TEST_EXPECT_FAIL    test names whose non-zero exit is the pass
#             KYR_TEST_ENV            VAR=value pairs for every test run     KYR_TEST_RESET   paths removed before each test
#
#   kyr_build_lib <profile> [out-root] [cppflags ...]   <out-root>/<profile>/lib<X>.{a,so.<ver>} + soname and linker links;
#                                                       release and native gated by check_hardening.sh
#   kyr_build_libs [profile ...]  every named profile, default KYR_LIB_PROFILES
#   kyr_build_bin <profile>     every binary, build/<profile>/<name>, PIE, release and native gated
#   kyr_build_tests <profile>   build/<profile>/tests/<name> for every test source, nothing else left there
#   kyr_run_tests <profile>     runs them from the root; a failing test fails the call
#
# Profiles are the catalog's plus coverage (debug at -O0 with gcov). Objects are -fPIC (one object set serves the archive and the
# shared object); the archive is deterministic (GCC_BUILD_ARFLAGS); the shared link takes LDFLAGS_SHARED plus the profile's
# non--pie extras. lib/test.sh (suites, coverage, stress, fuzzing, the package smoke test) is sourced at the end.

ROOT_DIR="${ROOT_DIR:-$(pwd -P)}"
KYR_BUILD_DIR="${KYR_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CC="${CC:-gcc}"
AR="${AR:-ar}"
KYR_LIB_CPPFLAGS=("${KYR_LIB_CPPFLAGS[@]:--I${ROOT_DIR}/app/include}")
# shellcheck source=epoch.sh
source "${KYR_BUILD_DIR}/lib/epoch.sh"
kyr_epoch_init "${ROOT_DIR}"   # again, now that the project file may have extended KYR_BUILD_INPUTS

kyr_die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

kyr_version() {
    KYR_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
    KYR_MAJOR="${KYR_VERSION%%.*}"
    [[ "${KYR_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || kyr_die "VERSION '${KYR_VERSION}' is not MAJOR.MINOR.PATCH"
}

# kyr_select_profile <profile>: fills KYR_CPPFLAGS KYR_CFLAGS KYR_LDFLAGS KYR_LDFLAGS_SO
kyr_select_profile() {
    local profile="$1" cpp c ld
    cpp="$(_profile_to_cpparray_name "${profile}")" || kyr_die "unknown profile: ${profile}"
    c="$(_profile_to_carray_name "${profile}")"
    ld="$(_profile_to_ldarray_name "${profile}")"
    local -n _cpp="${cpp}" _c="${c}" _ld="${ld}"
    KYR_CPPFLAGS=("${_cpp[@]}")
    KYR_CFLAGS=("${_c[@]}")
    KYR_LDFLAGS=("${_ld[@]}")
    KYR_LDFLAGS_SO=("${LDFLAGS_SHARED[@]}")
    local flag
    for flag in "${_ld[@]}"; do [[ "${flag}" == -pie ]] || KYR_LDFLAGS_SO+=("${flag}"); done
    KYR_PROFILE="${profile}"
    KYR_BUILD_OUT="${ROOT_DIR}/build/${profile}"
}

kyr_compile() {  # <obj_dir> <src ...> -> KYR_OBJECTS
    local obj_dir="$1"; shift
    local src obj
    KYR_OBJECTS=()
    mkdir -p "${obj_dir}"
    for src in "$@"; do
        obj="${obj_dir}/${src//\//__}.o"
        printf 'CC %s\n' "${src}"
        "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${KYR_EXTRA_CPPFLAGS[@]}" "${KYR_CFLAGS[@]}" "${CFLAGS_SHARED[@]}" \
            -c "${ROOT_DIR}/${src}" -o "${obj}" || kyr_die "compile failed"
        KYR_OBJECTS+=("${obj}")
    done
}
KYR_EXTRA_CPPFLAGS=()

# kyr_vendor_cflags: KYR_REPLY=(the selected profile's flags without its warning options (-Werror kept) and without
# KYR_VENDOR_DROP_CFLAGS, then KYR_LIB_VENDOR_CFLAGS): a vendored file is its upstream's, byte for byte (vendor.sh), built under
# the warnings its repository lists for it, never silenced
kyr_vendor_cflags() {
    local flag drop keep drops=(-fanalyzer)
    declare -p KYR_VENDOR_DROP_CFLAGS > /dev/null 2>&1 && drops=("${KYR_VENDOR_DROP_CFLAGS[@]}")
    KYR_REPLY=()
    for flag in "${KYR_CFLAGS[@]}"; do
        [[ "${flag}" == -W* && "${flag}" != -Werror ]] && continue
        keep=1
        for drop in "${drops[@]}"; do [[ "${flag}" == "${drop}" ]] && keep=0; done
        (( keep )) && KYR_REPLY+=("${flag}")
    done
    declare -p KYR_LIB_VENDOR_CFLAGS > /dev/null 2>&1 && KYR_REPLY+=("${KYR_LIB_VENDOR_CFLAGS[@]}")
    return 0
}

# kyr_compile_vendor <obj_dir> <src ...>: appends to KYR_OBJECTS
kyr_compile_vendor() {
    local obj_dir="$1" src obj; shift
    kyr_vendor_cflags; local cflags=("${KYR_REPLY[@]}")
    mkdir -p "${obj_dir}"
    for src in "$@"; do
        obj="${obj_dir}/${src//\//__}.o"
        printf 'CC %s (vendored)\n' "${src}"
        "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${KYR_EXTRA_CPPFLAGS[@]}" "${cflags[@]}" "${CFLAGS_SHARED[@]}" \
            -c "${ROOT_DIR}/${src}" -o "${obj}" || kyr_die "compile failed"
        KYR_OBJECTS+=("${obj}")
    done
}

kyr_gate() {  # release-grade artifacts must carry the hardening the profile promises
    [[ "${KYR_PROFILE}" == release || "${KYR_PROFILE}" == native ]] || return 0
    printf 'CHECK %s\n' "$*"
    "${KYR_BUILD_DIR}/check_hardening.sh" "$@" || kyr_die "hardening gate failed: $*"
}

# kyr_check_map: a version script with a <NODE>_<n> node must carry VERSION's major as <n> (the soname major)
kyr_check_map() {
    [[ -n "${KYR_LIB_MAP:-}" ]] || return 0
    local nodes
    nodes="$(sed -n -E 's/^[[:space:]]*[A-Za-z][A-Za-z0-9_]*_([0-9]+)[[:space:]]*\{.*/\1/p' "${ROOT_DIR}/${KYR_LIB_MAP}" | sort -u)"
    [[ -z "${nodes}" || "${nodes}" == "${KYR_MAJOR}" ]] \
        || kyr_die "${KYR_LIB_MAP}: version node major $(tr '\n' ' ' <<< "${nodes}")is not VERSION's major ${KYR_MAJOR}"
}

kyr_build_lib() {
    local profile="$1" root="${2:-${ROOT_DIR}/build}"
    kyr_version; kyr_select_profile "${profile}"
    KYR_EXTRA_CPPFLAGS=("${@:3}")
    [[ -n "${KYR_LIB:-}" ]] || kyr_die "KYR_LIB is not set"
    kyr_check_map
    KYR_BUILD_OUT="${root}/${profile}"
    local out="${KYR_BUILD_OUT}" real="lib${KYR_LIB}.so.${KYR_VERSION}" soname="lib${KYR_LIB}.so.${KYR_MAJOR}"
    rm -rf "${out}/obj"; mkdir -p "${out}"
    kyr_compile "${out}/obj" "${KYR_LIB_SOURCES[@]}"
    declare -p KYR_LIB_VENDOR_SOURCES > /dev/null 2>&1 && kyr_compile_vendor "${out}/obj" "${KYR_LIB_VENDOR_SOURCES[@]}"
    KYR_EXTRA_CPPFLAGS=()
    printf 'AR %s\n' "${out}/lib${KYR_LIB}.a"
    rm -f "${out}/lib${KYR_LIB}.a"
    "${AR}" "${GCC_BUILD_ARFLAGS[@]}" "${out}/lib${KYR_LIB}.a" "${KYR_OBJECTS[@]}" || kyr_die "archive failed"
    printf 'LD %s\n' "${out}/${real}"
    local map=()
    [[ -n "${KYR_LIB_MAP:-}" ]] && map=(-Wl,--version-script,"${ROOT_DIR}/${KYR_LIB_MAP}")
    "${CC}" "${KYR_LDFLAGS_SO[@]}" -Wl,-soname,"${soname}" "${map[@]}" -o "${out}/${real}" "${KYR_OBJECTS[@]}" "${KYR_LIB_LDLIBS[@]}" || kyr_die "link failed"
    ln -sfn "${real}" "${out}/${soname}"
    ln -sfn "${real}" "${out}/lib${KYR_LIB}.so"
    kyr_gate "${out}/${real}" "${out}/lib${KYR_LIB}.a"
}

# kyr_build_libs [profile ...]: every named profile, default KYR_LIB_PROFILES (else the catalog's)
kyr_build_libs() {
    local profiles=() p
    for p in "$@"; do [[ "${p}" == --profile ]] || profiles+=("${p}"); done
    if (( ! ${#profiles[@]} )); then
        if declare -p KYR_LIB_PROFILES > /dev/null 2>&1; then profiles=("${KYR_LIB_PROFILES[@]}"); else profiles=("${GCC_BUILD_PROFILES[@]}"); fi
    fi
    for p in "${profiles[@]}"; do kyr_build_lib "${p}"; done
}

_kyr_bin_var() { local b="${1^^}"; b="${b//[^A-Z0-9]/_}"; printf 'KYR_BIN_%s_%s\n' "${b}" "$2"; }

# kyr_bin_names: KYR_REPLY=(every declared binary)
kyr_bin_names() {
    KYR_REPLY=()
    if declare -p KYR_BINS > /dev/null 2>&1; then KYR_REPLY=("${KYR_BINS[@]}"); fi
    [[ -n "${KYR_BIN:-}" ]] && KYR_REPLY+=("${KYR_BIN}")
    return 0
}

# _kyr_bin_arr <name> <field>: KYR_REPLY=(the binary's declared array, empty when undeclared)
_kyr_bin_arr() {
    local v; v="$(_kyr_bin_var "$1" "$2")"
    KYR_REPLY=()
    declare -p "${v}" > /dev/null 2>&1 || return 0
    local -n _kyr_b="${v}"
    KYR_REPLY=("${_kyr_b[@]}")
}

_kyr_build_one_bin() {  # <name>
    local name="$1" out="${KYR_BUILD_OUT}" link srcs=() cpp=() ldlibs=() lib=()
    if [[ -n "${KYR_BIN:-}" && "${name}" == "${KYR_BIN}" ]] && ! declare -p "$(_kyr_bin_var "${name}" SOURCES)" > /dev/null 2>&1; then
        srcs=("${KYR_BIN_SOURCES[@]}"); ldlibs=("${KYR_BIN_LDLIBS[@]}"); link=static
    else
        _kyr_bin_arr "${name}" SOURCES; srcs=("${KYR_REPLY[@]}")
        _kyr_bin_arr "${name}" CPPFLAGS; cpp=("${KYR_REPLY[@]}")
        _kyr_bin_arr "${name}" LDLIBS; ldlibs=("${KYR_REPLY[@]}")
        _kyr_bin_arr "${name}" LINK; link="${KYR_REPLY[0]:-}"
        [[ -n "${link}" ]] || { if [[ -n "${KYR_LIB:-}" ]]; then link=static; else link=none; fi; }
    fi
    (( ${#srcs[@]} )) || kyr_die "binary ${name}: no sources declared"
    case "${link}" in
        static) lib=("${out}/lib${KYR_LIB}.a" "${KYR_LIB_LDLIBS[@]}") ;;
        shared) lib=(-L"${out}" -l"${KYR_LIB}" "${KYR_LIB_LDLIBS[@]}") ;;
        none) ;;
        *) kyr_die "binary ${name}: unknown link '${link}'" ;;
    esac
    local objs=() src obj
    mkdir -p "${out}/obj_bin/${name}"
    for src in "${srcs[@]}"; do
        obj="${out}/obj_bin/${name}/${src//\//__}.o"
        printf 'CC %s\n' "${src}"
        "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" "${KYR_CFLAGS[@]}" -c "${ROOT_DIR}/${src}" -o "${obj}" || kyr_die "compile failed"
        objs+=("${obj}")
    done
    printf 'LD %s\n' "${out}/${name}"
    "${CC}" "${KYR_LDFLAGS[@]}" -o "${out}/${name}" "${objs[@]}" "${lib[@]}" "${ldlibs[@]}" || kyr_die "link failed"
    kyr_gate "${out}/${name}"
}

kyr_build_bin() {
    kyr_version; kyr_select_profile "$1"
    kyr_bin_names
    (( ${#KYR_REPLY[@]} )) || { printf 'build.sh: no binary declared, nothing to build\n'; return 0; }
    local names=("${KYR_REPLY[@]}") name
    rm -rf "${KYR_BUILD_OUT}/obj_bin"
    for name in "${names[@]}"; do _kyr_build_one_bin "${name}"; done
}

kyr_build_tests() {
    kyr_version; kyr_select_profile "$1"
    local out="${KYR_BUILD_OUT}/tests" src name support=() libldlibs=("${KYR_LIB_LDLIBS[@]}") linkage
    rm -rf "${out}"; mkdir -p "${out}"   # only the sources listed now: a removed test leaves no executable behind
    declare -p KYR_TEST_LIB_LDLIBS > /dev/null 2>&1 && libldlibs=("${KYR_TEST_LIB_LDLIBS[@]}")
    local cpp=() linkages=(static)
    declare -p KYR_TEST_CPPFLAGS > /dev/null 2>&1 && cpp=("${KYR_TEST_CPPFLAGS[@]}")
    declare -p KYR_TEST_LINKAGES > /dev/null 2>&1 && linkages=("${KYR_TEST_LINKAGES[@]}")
    if declare -p KYR_TEST_SUPPORT_SOURCES > /dev/null 2>&1 && (( ${#KYR_TEST_SUPPORT_SOURCES[@]} )); then
        mkdir -p "${out}/.support"
        for src in "${KYR_TEST_SUPPORT_SOURCES[@]}"; do
            printf 'CC %s (test support)\n' "${src}"
            "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" -UNDEBUG "${KYR_CFLAGS[@]}" -I"${ROOT_DIR}/tests" \
                -c "${ROOT_DIR}/${src}" -o "${out}/.support/${src//\//__}.o" || kyr_die "compile failed"
            support+=("${out}/.support/${src//\//__}.o")
        done
    fi
    for linkage in "${linkages[@]}"; do
        local dir="${out}"
        [[ "${linkage}" == shared ]] && dir="${out}/shared"
        mkdir -p "${dir}"
        for src in "${KYR_TEST_SOURCES[@]}"; do
            name="$(basename "${src}" .c)"
            local lib=()
            if [[ -n "${KYR_LIB:-}" ]]; then
                lib=("${KYR_BUILD_OUT}/lib${KYR_LIB}.a")
                if [[ "${linkage}" == shared ]] && ! { [[ -n "${KYR_TEST_WHITEBOX:-}" ]] && grep -qE "${KYR_TEST_WHITEBOX}" "${ROOT_DIR}/${src}"; }; then
                    lib=("${KYR_BUILD_OUT}/lib${KYR_LIB}.so" -Wl,-rpath,"${KYR_BUILD_OUT}")
                fi
            fi
            printf 'CC+LD %s\n' "${dir}/${name}"
            "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${cpp[@]}" -UNDEBUG "${KYR_CFLAGS[@]}" -I"${ROOT_DIR}/tests" "${KYR_LDFLAGS[@]}" \
                -o "${dir}/${name}" "${ROOT_DIR}/${src}" "${support[@]}" "${lib[@]}" "${libldlibs[@]}" "${KYR_TEST_LDLIBS[@]}" -lcmocka || kyr_die "link failed"
        done
    done
}

_kyr_expected_failure() {  # <name>
    local n
    declare -p KYR_TEST_EXPECT_FAIL > /dev/null 2>&1 || return 1
    for n in "${KYR_TEST_EXPECT_FAIL[@]}"; do [[ "${n}" == "$1" ]] && return 0; done
    return 1
}

kyr_run_tests() {
    kyr_select_profile "$1"
    local exe rc=0 n=0 want one env=() reset=() linkages=(static) p
    declare -p KYR_TEST_ENV > /dev/null 2>&1 && env=("${KYR_TEST_ENV[@]}")
    declare -p KYR_TEST_RESET > /dev/null 2>&1 && reset=("${KYR_TEST_RESET[@]}")
    declare -p KYR_TEST_LINKAGES > /dev/null 2>&1 && linkages=("${KYR_TEST_LINKAGES[@]}")
    case "${KYR_PROFILE}" in
        sanitize) env+=(ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 LSAN_OPTIONS=exitcode=1) ;;
        coverage) find "${KYR_BUILD_OUT}" -name '*.gcda' -delete 2> /dev/null || true ;;
    esac
    want=$(( ${#KYR_TEST_SOURCES[@]} * ${#linkages[@]} ))
    for exe in "${KYR_BUILD_OUT}"/tests/* "${KYR_BUILD_OUT}"/tests/shared/*; do
        [[ -f "${exe}" && -x "${exe}" ]] || continue
        n=$((n + 1))
        for p in "${reset[@]}"; do rm -rf "${ROOT_DIR:?}/${p}"; done
        printf 'RUN %s\n' "${exe}"
        one=0
        ( cd "${ROOT_DIR}" && env LD_LIBRARY_PATH="${KYR_BUILD_OUT}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "${env[@]}" "${exe}" ) || one=$?
        if _kyr_expected_failure "$(basename "${exe}")"; then
            if (( one )); then printf 'ok %s failed as expected (exit %d)\n' "${exe##*/}" "${one}"
            else printf 'FAIL %s passed but must fail\n' "${exe##*/}"; rc=1; fi
        elif (( one )); then
            rc=1
        fi
    done
    (( n == want )) || { printf 'build.sh: %d test executable(s) for %d expected (run build_tests.sh first)\n' "${n}" "${want}" >&2; return 1; }
    return "${rc}"
}

# shellcheck source=test.sh
source "${KYR_BUILD_DIR}/lib/test.sh"
