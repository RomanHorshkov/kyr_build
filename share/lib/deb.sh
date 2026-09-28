#!/usr/bin/env bash
# shellcheck shell=bash
# deb.sh — the shared Debian packaging steps. A repository's utils/build_deb.sh sources it and calls, in order:
#
#   deb_init                                   VERSION -> DEB_VERSION DEB_MAJOR; DEB_ARCH; DEB_OUT_DIR (build/debs, emptied);
#                                              SOURCE_DATE_EPOCH (kept if set, else the commit being built); umask 022;
#                                              DEB_TIER from the "# tier: <n> <kind>" line of deps.txt (lib/tier.sh)
#   deb_stage <pkg> [usr/local subdir ...]     fresh build/pkgroot/<pkg> with DEBIAN/ and the subdirs; prints its path
#   deb_control <stage> <pkg> <section> <arch> <description> [Field: value ...]
#                                              every control file carries X-Kyr-Tier: <n> <kind>, what a consumer's
#                                              deps.sh check --tiers reads as the tier of the pinned deb
#   deb_depends_from_deps_txt [pkg ...]        the runtime Depends a library deb needs, derived from deps.txt: every
#                                              own line that is a runtime package (not -dev, not kyr-build, not a
#                                              header-only *-util-* package), as "pkg (>= ver)"; extra names appended
#   deb_ldconfig_hooks <stage>                 postinst/postrm running ldconfig
#   deb_copyright <stage> <pkg>                debian/copyright -> /usr/share/doc/<pkg>/copyright (missing = error)
#   deb_build <stage> <pkg> [arch]             normalises modes and mtimes, dpkg-deb --root-owner-group, writes
#                                              build/debs/<pkg>_<ver>_<arch>.deb and its .buildinfo; prints the deb path
#   deb_sha256sums                             SHA256SUMS over build/debs/*.deb
#   deb_tar <out.tar.gz> <dir> <member ...>    sorted, epoch-clamped, root-owned, gzip -n: the same bytes every time
#
# Every step is deterministic (plan 4.1): no fakeroot, no sudo, the same tree gives the same deb on any machine.
# The caller sets ROOT_DIR (default: the parent of the sourcing script's directory).

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
KYR_BUILD_DIR="${KYR_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEB_MAINTAINER="${DEB_MAINTAINER:-Roman Horshkov <https://github.com/RomanHorshkov>}"
# shellcheck source=tier.sh
source "${KYR_BUILD_DIR}/lib/tier.sh"

deb_die() { printf 'deb.sh: %s\n' "$*" >&2; exit 1; }

deb_init() {
    umask 022
    [[ -f "${ROOT_DIR}/VERSION" ]] || deb_die "missing ${ROOT_DIR}/VERSION"
    DEB_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
    [[ "${DEB_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || deb_die "VERSION '${DEB_VERSION}' is not MAJOR.MINOR.PATCH"
    DEB_MAJOR="${DEB_VERSION%%.*}"
    DEB_TIER="$(kyr_tier_declared "${ROOT_DIR}/deps.txt")" || deb_die "every deb carries the tier of its repository: declare it in deps.txt"
    DEB_ARCH="$(dpkg --print-architecture)"
    DEB_OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/debs}"
    DEB_STAGE_ROOT="${ROOT_DIR}/build/pkgroot"
    if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
        SOURCE_DATE_EPOCH="$(git -C "${ROOT_DIR}" log -1 --format=%ct 2>/dev/null || true)"
        : "${SOURCE_DATE_EPOCH:=0}"
    fi
    export SOURCE_DATE_EPOCH TZ=UTC
    command -v dpkg-deb >/dev/null 2>&1 || deb_die "dpkg-deb not found"
    rm -rf "${DEB_OUT_DIR}"
    install -d -m 0755 "${DEB_OUT_DIR}"
}

deb_stage() {
    local pkg="$1"; shift
    local stage="${DEB_STAGE_ROOT}/${pkg}" d
    rm -rf "${stage}"
    install -d -m 0755 "${stage}" "${stage}/DEBIAN" "${stage}/usr" "${stage}/usr/local"
    for d in "$@"; do install -d -m 0755 "${stage}/usr/local/${d}"; done
    printf '%s\n' "${stage}"
}

deb_control() {
    local stage="$1" pkg="$2" section="$3" arch="$4" desc="$5"; shift 5
    {
        printf 'Package: %s\nVersion: %s\nSection: %s\nPriority: optional\nArchitecture: %s\nMaintainer: %s\n' \
            "${pkg}" "${DEB_VERSION}" "${section}" "${arch}" "${DEB_MAINTAINER}"
        local line
        for line in "$@"; do printf '%s\n' "${line}"; done
        printf 'X-Kyr-Tier: %s\n' "${DEB_TIER:?deb_init first}"
        printf 'Description: %s\n' "${desc}"
    } > "${stage}/DEBIAN/control"
    chmod 0644 "${stage}/DEBIAN/control"
}

deb_depends_from_deps_txt() {
    local out=() name ver
    if [[ -f "${ROOT_DIR}/deps.txt" ]]; then
        while read -r name ver; do
            case "${name}" in
                *-dev|kyr-build|*-util-*) continue ;;
            esac
            out+=("${name} (>= ${ver})")
        done < <(sed 's/#.*$//' "${ROOT_DIR}/deps.txt" | awk '$1=="own"{print $2, $3}')
    fi
    out+=("$@")
    local IFS=','
    printf '%s\n' "${out[*]}" | sed 's/,/, /g'
}

deb_ldconfig_hooks() {
    local stage="$1" hook
    for hook in postinst postrm; do
        printf '#!/bin/sh\nset -e\nldconfig\nexit 0\n' > "${stage}/DEBIAN/${hook}"
        chmod 0755 "${stage}/DEBIAN/${hook}"
    done
}

deb_copyright() {
    local stage="$1" pkg="$2" src="${ROOT_DIR}/debian/copyright"
    [[ -f "${src}" ]] || deb_die "missing ${src}: a package never leaves without its notices"
    install -d -m 0755 "${stage}/usr/share" "${stage}/usr/share/doc" "${stage}/usr/share/doc/${pkg}"
    install -m 0644 "${src}" "${stage}/usr/share/doc/${pkg}/copyright"
}

deb_build() {
    local stage="$1" pkg="$2" arch="${3:-${DEB_ARCH}}"
    local deb="${DEB_OUT_DIR}/${pkg}_${DEB_VERSION}_${arch}.deb"
    find "${stage}" -type d -exec chmod 0755 {} +
    find "${stage}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
    dpkg-deb --build --root-owner-group -Zgzip "${stage}" "${deb}" >/dev/null
    "${KYR_BUILD_DIR}/buildinfo.sh" "${deb}" > "${deb}.buildinfo"
    printf '%s\n' "${deb}"
}

deb_sha256sums() {
    ( cd "${DEB_OUT_DIR}" && sha256sum -- *.deb > SHA256SUMS )
}

deb_tar() {
    local out="$1" dir="$2"; shift 2
    tar -C "${dir}" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
        --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime -cf - "$@" | gzip -n > "${out}"
}
