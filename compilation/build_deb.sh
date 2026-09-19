#!/usr/bin/env bash
# =============================================================================
# build_deb.sh — package the rh header-only utilities as SEPARATE debs
#
# author  Roman Horshkov <github.com/RomanHorshkov>
#
# One Debian package per header (Architecture: all), each shipping exactly one
# .h to /usr/local/include/utils/, plus one devtools package for the shared
# build tooling. This lets a consumer depend on only what it includes, and
# lets each header version independently.
#
#   header_only/string_view.h          -> rh-util-string-view
#   header_only/memory_macros.h        -> rh-util-memory-macros
#   header_only/time_macros.h          -> rh-util-time-macros
#   header_only/preprocessor_macros.h  -> rh-util-preprocessor-macros
#     each installs  /usr/local/include/utils/<name>.h
#     consumed as    #include <utils/<name>.h>     (flat, unchanged)
#
#   compilation/gcc_build_profiles.sh  ┐
#   .clang-format                      ├─ rh-utils-devtools
#   ../tests/  (superproject testkit)  ┘   -> /usr/local/share/rh-utils/
#
# Every produced .deb lands in build/debs/. See Utils/README.md and the
# superproject IMPLEMENTATION_PROCEDURE.md §4.3.
# =============================================================================

set -euo pipefail

START_DIR="$(pwd -P)"
cleanup() { cd -- "${START_DIR}"; }
trap cleanup EXIT

die() { printf 'build_deb: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd -- "${ROOT_DIR}"

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found in PATH"
command -v fakeroot >/dev/null 2>&1 || die "fakeroot not found in PATH"

VER="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
[[ -n "${VER}" ]] || die "VERSION is empty"

HEADERS_DIR="${ROOT_DIR}/header_only"
PROFILES_SH="${ROOT_DIR}/compilation/gcc_build_profiles.sh"
CLANG_FMT="${ROOT_DIR}/.clang-format"
TESTKIT_DIR="${TESTKIT_DIR:-$(cd "${ROOT_DIR}/.." 2>/dev/null && pwd)/tests}"

[[ -d "${HEADERS_DIR}" ]] || die "missing ${HEADERS_DIR}"
[[ -f "${PROFILES_SH}" ]] || die "missing ${PROFILES_SH}"
[[ -f "${CLANG_FMT}"   ]] || die "missing ${CLANG_FMT}"

BUILD_DIR="${ROOT_DIR}/build"
OUT_DIR="${OUT_DIR:-${BUILD_DIR}/debs}"
STAGE_ROOT="${BUILD_DIR}/pkgroot"

rm -rf -- "${STAGE_ROOT}"
mkdir -p -- "${OUT_DIR}"
# Clear previously produced debs so a stale package (notably the retired
# monolithic rh-utils_*.deb) can't linger and get picked up at install time.
rm -f -- "${OUT_DIR}"/*.deb

# _emit_deb <pkg> <description-one-line> <staged-root-dir>
# Writes DEBIAN/control into the staged root and builds the .deb.
_emit_deb() {
    local pkg="$1" desc="$2" stage="$3"
    mkdir -p -- "${stage}/DEBIAN"
    # Replaces/Conflicts the retired monolithic rh-utils: on any box that still
    # has it, apt removes it and these split packages take over its files
    # (each header used to be shipped by rh-utils).
    cat > "${stage}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${VER}
Section: libdevel
Priority: optional
Architecture: all
Maintainer: Roman Horshkov <https://github.com/RomanHorshkov>
Replaces: rh-utils
Conflicts: rh-utils
Description: ${desc}
EOF
    # Ship the DEP-5 copyright file (first-party terms + every third-party notice)
    # at /usr/share/doc/<pkg>/copyright (Debian Policy 12.5). A missing file is a
    # build error: a binary must never leave without its notices.
    COPYRIGHT_SRC="${ROOT_DIR}/debian/copyright"
    [[ -f "${COPYRIGHT_SRC}" ]] || die "missing ${COPYRIGHT_SRC} — third-party notices must ship in the deb"
    install -d -m 0755 "${stage}/usr/share" "${stage}/usr/share/doc" "${stage}/usr/share/doc/${pkg}"
    install -m 0644 "${COPYRIGHT_SRC}" "${stage}/usr/share/doc/${pkg}/copyright"
    local deb="${OUT_DIR}/${pkg}_${VER}_all.deb"
    fakeroot dpkg-deb --build "${stage}" "${deb}" >/dev/null
    printf '  built  %s\n' "$(basename "${deb}")"
}

# header_slug <memory_macros> -> memory-macros  (package-name friendly)
_header_slug() { printf '%s' "${1//_/-}"; }

printf 'Utils: packaging header-only utilities (version %s)\n' "${VER}"

# --- one deb per header ------------------------------------------------------
shopt -s nullglob
headers=("${HEADERS_DIR}"/*.h)
shopt -u nullglob
(( ${#headers[@]} > 0 )) || die "no headers found in ${HEADERS_DIR}"

for h in "${headers[@]}"
do
    base="$(basename "${h}")"           # memory_macros.h
    name="${base%.h}"                   # memory_macros
    slug="$(_header_slug "${name}")"    # memory-macros
    pkg="rh-util-${slug}"

    stage="${STAGE_ROOT}/${pkg}"
    rm -rf -- "${stage}"
    mkdir -p -- "${stage}/usr/local/include/utils"
    install -m 0644 -- "${h}" "${stage}/usr/local/include/utils/${base}"

    _emit_deb "${pkg}" "rh header-only utility: <utils/${base}> (installs one header under /usr/local/include/utils)" "${stage}"
done

# --- devtools: build profiles, clang-format, shared testkit ------------------
dt="${STAGE_ROOT}/rh-utils-devtools"
rm -rf -- "${dt}"
mkdir -p -- "${dt}/usr/local/share/rh-utils"
install -m 0644 -- "${PROFILES_SH}" "${dt}/usr/local/share/rh-utils/gcc_build_profiles.sh"
install -m 0755 -- "${ROOT_DIR}/compilation/check_hardening.sh" "${dt}/usr/local/share/rh-utils/check_hardening.sh"
install -m 0644 -- "${CLANG_FMT}"   "${dt}/usr/local/share/rh-utils/.clang-format"
printf '%s\n' "${VER}" > "${dt}/usr/local/share/rh-utils/VERSION"
chmod 0644 "${dt}/usr/local/share/rh-utils/VERSION"

if [[ -d "${TESTKIT_DIR}" ]]
then
    printf '  testkit %s -> /usr/local/share/rh-utils/testkit/\n' "${TESTKIT_DIR}"
    mkdir -p -- "${dt}/usr/local/share/rh-utils/testkit"
    cp -a -- "${TESTKIT_DIR}/." "${dt}/usr/local/share/rh-utils/testkit/"
    find "${dt}/usr/local/share/rh-utils/testkit" -type d -exec chmod 0755 {} +
    find "${dt}/usr/local/share/rh-utils/testkit" -type f -name '*.sh' -exec chmod 0755 {} +
    find "${dt}/usr/local/share/rh-utils/testkit" -type f ! -name '*.sh' -exec chmod 0644 {} +
else
    printf 'build_deb: NOTE superproject testkit not found at %s — devtools packaged without it\n' "${TESTKIT_DIR}"
fi

_emit_deb "rh-utils-devtools" "rh build tooling: gcc_build_profiles.sh, .clang-format, shared testkit under /usr/local/share/rh-utils" "${dt}"

printf '\nUtils: %d package(s) in %s\n' "$(( ${#headers[@]} + 1 ))" "${OUT_DIR}"
ls -1 "${OUT_DIR}"/rh-util*_"${VER}"_all.deb 2>/dev/null | sed 's|^|  |'
