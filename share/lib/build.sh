#!/usr/bin/env bash
# shellcheck shell=bash
# build.sh — the shared build steps a repository's thin utils/ wrappers call. Source the profile catalog and the
# repository's utils/<name>_project.sh first; that file declares:
#
#   KYR_LIB             library basename: lib<KYR_LIB>.so.<ver>, lib<KYR_LIB>.a
#   KYR_LIB_SOURCES     C sources, relative to ROOT_DIR
#   KYR_LIB_CPPFLAGS    include flags (default: -Iapp/include)          KYR_LIB_LDLIBS   libraries the shared link needs
#   KYR_LIB_MAP         version script (optional)                        KYR_LIB_HEADER   the public header for the strict compile
#   KYR_BIN             binary name (optional)                           KYR_BIN_SOURCES  its sources; links lib<KYR_LIB>.a
#   KYR_TEST_SOURCES    tests/UTs/*.c, one cmocka executable each        KYR_TEST_LDLIBS  extra libraries for the tests
#
#   kyr_build_lib <profile>     build/<profile>/lib<X>.{a,so.<ver>} + soname and linker symlinks; release gated by check_hardening.sh
#   kyr_build_bin <profile>     build/<profile>/<KYR_BIN>, PIE, release gated
#   kyr_build_tests <profile>   build/<profile>/tests/<name> for every test source, nothing else left there
#   kyr_run_tests <profile>     runs them; a failing test fails the call
#
# Objects are -fPIC (one object set serves the archive and the shared object); the archive is deterministic
# (GCC_BUILD_ARFLAGS); the shared link takes LDFLAGS_SHARED plus the profile's non--pie extras.

ROOT_DIR="${ROOT_DIR:-$(pwd -P)}"
KYR_BUILD_DIR="${KYR_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CC="${CC:-gcc}"
AR="${AR:-ar}"
KYR_LIB_CPPFLAGS=("${KYR_LIB_CPPFLAGS[@]:--I${ROOT_DIR}/app/include}")

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
        "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${KYR_CFLAGS[@]}" "${CFLAGS_SHARED[@]}" -c "${ROOT_DIR}/${src}" -o "${obj}"
        KYR_OBJECTS+=("${obj}")
    done
}

kyr_gate() {  # release-grade artifacts must carry the hardening the profile promises
    [[ "${KYR_PROFILE}" == release || "${KYR_PROFILE}" == native ]] || return 0
    printf 'CHECK %s\n' "$*"
    "${KYR_BUILD_DIR}/check_hardening.sh" "$@"
}

kyr_build_lib() {
    kyr_version; kyr_select_profile "$1"
    [[ -n "${KYR_LIB:-}" ]] || kyr_die "KYR_LIB is not set"
    local out="${KYR_BUILD_OUT}" real="lib${KYR_LIB}.so.${KYR_VERSION}" soname="lib${KYR_LIB}.so.${KYR_MAJOR}"
    rm -rf "${out}/obj"; mkdir -p "${out}"
    kyr_compile "${out}/obj" "${KYR_LIB_SOURCES[@]}"
    printf 'AR %s\n' "${out}/lib${KYR_LIB}.a"
    rm -f "${out}/lib${KYR_LIB}.a"
    "${AR}" "${GCC_BUILD_ARFLAGS[@]}" "${out}/lib${KYR_LIB}.a" "${KYR_OBJECTS[@]}"
    printf 'LD %s\n' "${out}/${real}"
    local map=()
    [[ -n "${KYR_LIB_MAP:-}" ]] && map=(-Wl,--version-script,"${ROOT_DIR}/${KYR_LIB_MAP}")
    "${CC}" "${KYR_LDFLAGS_SO[@]}" -Wl,-soname,"${soname}" "${map[@]}" -o "${out}/${real}" "${KYR_OBJECTS[@]}" "${KYR_LIB_LDLIBS[@]}"
    ln -sfn "${real}" "${out}/${soname}"
    ln -sfn "${real}" "${out}/lib${KYR_LIB}.so"
    kyr_gate "${out}/${real}" "${out}/lib${KYR_LIB}.a"
}

kyr_build_bin() {
    kyr_version; kyr_select_profile "$1"
    [[ -n "${KYR_BIN:-}" ]] || { printf 'build.sh: no KYR_BIN declared, nothing to build\n'; return 0; }
    local out="${KYR_BUILD_OUT}"
    kyr_compile "${out}/obj_bin" "${KYR_BIN_SOURCES[@]}"
    printf 'LD %s\n' "${out}/${KYR_BIN}"
    "${CC}" "${KYR_LDFLAGS[@]}" -o "${out}/${KYR_BIN}" "${KYR_OBJECTS[@]}" "${out}/lib${KYR_LIB}.a" "${KYR_LIB_LDLIBS[@]}" "${KYR_BIN_LDLIBS[@]}"
    kyr_gate "${out}/${KYR_BIN}"
}

kyr_build_tests() {
    kyr_version; kyr_select_profile "$1"
    local out="${KYR_BUILD_OUT}/tests" src name
    rm -rf "${out}"; mkdir -p "${out}"   # only the sources listed now: a removed test leaves no executable behind
    for src in "${KYR_TEST_SOURCES[@]}"; do
        name="$(basename "${src}" .c)"
        printf 'CC+LD %s\n' "${out}/${name}"
        "${CC}" "${KYR_CPPFLAGS[@]}" "${KYR_LIB_CPPFLAGS[@]}" "${KYR_CFLAGS[@]}" -I"${ROOT_DIR}/tests" "${KYR_LDFLAGS[@]}" \
            -o "${out}/${name}" "${ROOT_DIR}/${src}" "${KYR_BUILD_OUT}/lib${KYR_LIB}.a" "${KYR_LIB_LDLIBS[@]}" "${KYR_TEST_LDLIBS[@]}" -lcmocka
    done
}

kyr_run_tests() {
    kyr_select_profile "$1"
    local exe rc=0 n=0
    for exe in "${KYR_BUILD_OUT}"/tests/*; do
        [[ -x "${exe}" ]] || continue
        n=$((n + 1))
        printf 'RUN %s\n' "${exe}"
        "${exe}" || rc=1
    done
    (( n == ${#KYR_TEST_SOURCES[@]} )) || { printf 'build.sh: %d test executable(s) for %d test source(s) (run build_tests.sh first)\n' "${n}" "${#KYR_TEST_SOURCES[@]}" >&2; return 1; }
    return "${rc}"
}
