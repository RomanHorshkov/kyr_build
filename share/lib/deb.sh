#!/usr/bin/env bash
# shellcheck shell=bash
# deb.sh — the shared Debian packaging steps. A repository's utils/build_deb.sh sources it and calls, in order:
#
#   deb_release_check                          a release is built inside the pinned build root (build_root.sh enter);
#                                              on the host only with KYR_ALLOW_HOST_BUILD=1, a development deb whose
#                                              buildinfo says Build-Root: none (deb_init and kyr_debs call it first)
#   deb_init                                   VERSION -> DEB_VERSION DEB_MAJOR; DEB_ARCH; DEB_OUT_DIR (build/debs, emptied);
#                                              SOURCE_DATE_EPOCH (kept if the caller set it, else the last commit that
#                                              touched a build input, lib/epoch.sh); umask 022;
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
#   deb_sha256sums                             SHA256SUMS over build/debs/*.deb, in C-locale order
#   deb_tar <out.tar.gz> <dir> <member ...>    sorted, epoch-clamped, root-owned, gzip -n: the same bytes every time
#
# The recipes, which a repository's utils/build_deb.sh wrapper reaches through kyr_debs (release library and binaries first, then
# every entry of KYR_DEBS, then SHA256SUMS). KYR_DEBS defaults to (lib) with a library; its entries:
#
#   lib            runtime KYR_PKG (lib<KYR_LIB>.so.<ver> stripped, soname link, ldconfig hooks; KYR_DEB_LIB_BINS in usr/local/bin)
#                  and KYR_PKG-dev (headers, archive, linker link, .pc), Depends: KYR_PKG (= <ver>)
#   lib-combined   one deb KYR_PKG with everything above (runtime and development files together)
#   bin:<pkg>      KYR_DEB_<P>_BINS (built binaries, usr/local/bin), _LINKS ("<link>:<target>" in usr/local/bin), _SHARE
#                  ("<src>:<dest>" under usr/local/share), _SECTION (default admin), _DESCRIPTION, _FIELDS
#   web:<pkg>      KYR_DEB_<P>_SRC (a directory) as usr/local/share/KYR_DEB_<P>_DEST, files 0644, Architecture all, Section web;
#                  _ALLOW (file extensions; anything else refuses the deb), _DESCRIPTION, _FIELDS
#   (P: the package name in upper case, - and . as _)
#
#   KYR_DEB_HEADERS        "<src>[:<dest>]": a file, or a directory (every file under it, KYR_DEB_HEADER_EXTS filters by
#                          extension), installed under usr/local/include/<dest> (default: app/include, every file, same paths)
#   KYR_DEB_RUNTIME_FIELDS control fields of the runtime (or combined) deb; default "Depends: <deb_runtime_depends libc6
#                          KYR_DEB_DEPENDS_EXTRA>"
#   KYR_DEB_DEV_DEPENDS    added to the -dev deb's Depends     KYR_DEB_DEV_FIELDS  further -dev control fields
#   KYR_DEB_DEV_DESCRIPTION  default "Development files for <pkg>"
#   KYR_DEB_PC             1 (default) writes lib/pkgconfig/<KYR_LIB>.pc: KYR_PC_NAME KYR_PC_DESCRIPTION KYR_PC_INCLUDE_SUBDIR
#                          KYR_PC_VARIABLES (extra lines) KYR_PC_REQUIRES_PRIVATE KYR_PC_LIBS_PRIVATE KYR_PC_CFLAGS
#   KYR_DEB_COPYRIGHT      the notices file every deb carries (default debian/copyright)
# In every field and description, @VERSION@ is VERSION and @PIN:<pkg>@ the version deps.txt pins for <pkg>. A library deb that
# declares no binary refuses a payload with a bin directory.
#
# Every step is deterministic (plan 4.1): no fakeroot, no sudo, the same tree gives the same deb on any machine.
# The caller sets ROOT_DIR (default: the parent of the sourcing script's directory).

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
KYR_BUILD_DIR="${KYR_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEB_MAINTAINER="${DEB_MAINTAINER:-Roman Horshkov <https://github.com/RomanHorshkov>}"
# shellcheck source=tier.sh
source "${KYR_BUILD_DIR}/lib/tier.sh"
# shellcheck source=epoch.sh
source "${KYR_BUILD_DIR}/lib/epoch.sh"
# shellcheck source=root.sh
source "${KYR_BUILD_DIR}/lib/root.sh"

deb_die() { printf 'deb.sh: %s\n' "$*" >&2; exit 1; }

deb_release_check() {
    kyr_root_release_check || deb_die "a release is built inside the pinned build root: ${KYR_BUILD_DIR}/build_root.sh enter -- ./utils/build_deb.sh (KYR_ALLOW_HOST_BUILD=1 builds a development deb on the host, Build-Root: none)"
    if ! kyr_root_identity > /dev/null && [[ -z "${_DEB_HOST_NOTED:-}" ]]; then
        printf 'deb.sh: host build (KYR_ALLOW_HOST_BUILD=1): development debs, Build-Root: none\n' >&2
        _DEB_HOST_NOTED=1
    fi
}

deb_init() {
    deb_release_check
    umask 022
    [[ -f "${ROOT_DIR}/VERSION" ]] || deb_die "missing ${ROOT_DIR}/VERSION"
    DEB_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
    [[ "${DEB_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || deb_die "VERSION '${DEB_VERSION}' is not MAJOR.MINOR.PATCH"
    DEB_MAJOR="${DEB_VERSION%%.*}"
    DEB_TIER="$(kyr_tier_declared "${ROOT_DIR}/deps.txt")" || deb_die "every deb carries the tier of its repository: declare it in deps.txt"
    DEB_ARCH="$(dpkg --print-architecture)"
    DEB_OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/debs}"
    DEB_STAGE_ROOT="${ROOT_DIR}/build/pkgroot"
    kyr_epoch_init "${ROOT_DIR}"
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

# deb_runtime_depends [pkg ...]: the runtime Depends from deps.txt: every own line but kyr-build, header-only *-util-* packages,
# lines marked test (needed by the tests only), static (linked or composed at build time) or optional (resolved only on request),
# and a -dev package whose runtime sibling is pinned too (an unpaired -dev package carries the runtime itself); as "pkg (>= ver)",
# extra names appended
deb_runtime_depends() {
    local out=() name ver marks pinned
    if [[ -f "${ROOT_DIR}/deps.txt" ]]; then
        pinned=" $(sed 's/#.*$//' "${ROOT_DIR}/deps.txt" | awk '$1=="own"{printf "%s ", $2}')"
        while read -r name ver marks; do
            case "${name}" in kyr-build|*-util-*) continue ;; esac
            case " ${marks} " in *" test "*|*" static "*|*" optional "*) continue ;; esac
            [[ "${name}" == *-dev && "${pinned}" == *" ${name%-dev} "* ]] && continue
            out+=("${name} (>= ${ver})")
        done < <(sed 's/#.*$//' "${ROOT_DIR}/deps.txt" | awk '$1=="own"{m=""; for (i = 5; i <= NF; i++) m = m " " $i; print $2, $3, m}')
    fi
    out+=("$@")
    local IFS=','
    printf '%s\n' "${out[*]}" | sed 's/,/, /g'
}

# deb_expand <text>: @VERSION@ and @PIN:<pkg>@
deb_expand() {
    local text="$1" pkg ver
    text="${text//@VERSION@/${DEB_VERSION}}"
    while [[ "${text}" =~ @PIN:([A-Za-z0-9.+-]+)@ ]]; do
        pkg="${BASH_REMATCH[1]}"
        ver="$(sed 's/#.*$//' "${ROOT_DIR}/deps.txt" | awk -v p="${pkg}" '$1=="own" && $2==p {print $3; exit}')"
        [[ -n "${ver}" ]] || deb_die "@PIN:${pkg}@: deps.txt pins no ${pkg}"
        text="${text//@PIN:${pkg}@/${ver}}"
    done
    printf '%s\n' "${text}"
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
    local stage="$1" pkg="$2" src="${ROOT_DIR}/${KYR_DEB_COPYRIGHT:-debian/copyright}"
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
    # LC_ALL=C before the glob: the file order must not depend on the machine's locale (en_US sorts "x-dev_" after "x_")
    ( cd "${DEB_OUT_DIR}" && export LC_ALL=C && sha256sum -- *.deb > SHA256SUMS )
}

deb_tar() {
    local out="$1" dir="$2"; shift 2
    tar -C "${dir}" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
        --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime -cf - "$@" | gzip -n > "${out}"
}

_deb_var() { local p="${1^^}"; p="${p//[^A-Z0-9]/_}"; printf 'KYR_DEB_%s_%s\n' "${p}" "$2"; }

# _deb_arr <var>: DEB_REPLY=(its values), empty when undeclared
_deb_arr() {
    DEB_REPLY=()
    declare -p "$1" > /dev/null 2>&1 || return 0
    local -n _deb_ref="$1"
    DEB_REPLY=("${_deb_ref[@]}")
}

# _deb_fields <var> <default ...>: DEB_REPLY=(the declared fields, expanded; the defaults when undeclared)
_deb_fields() {
    local var="$1" f; shift
    if declare -p "${var}" > /dev/null 2>&1; then _deb_arr "${var}"; else DEB_REPLY=("$@"); fi
    local out=()
    for f in "${DEB_REPLY[@]}"; do out+=("$(deb_expand "${f}")"); done
    DEB_REPLY=("${out[@]}")
}

# deb_install_headers <stage>: KYR_DEB_HEADERS under usr/local/include
deb_install_headers() {
    local stage="$1" spec src dest f rel ext keep exts=()
    declare -p KYR_DEB_HEADER_EXTS > /dev/null 2>&1 && read -r -a exts <<< "${KYR_DEB_HEADER_EXTS[*]}"
    _deb_arr KYR_DEB_HEADERS
    (( ${#DEB_REPLY[@]} )) || DEB_REPLY=(app/include)
    for spec in "${DEB_REPLY[@]}"; do
        src="${spec%%:*}"; dest=""; [[ "${spec}" == *:* ]] && dest="${spec#*:}"
        dest="${stage}/usr/local/include${dest:+/${dest}}"
        if [[ -d "${ROOT_DIR}/${src}" ]]; then
            while IFS= read -r -d '' f; do
                rel="${f#"${ROOT_DIR}/${src}"/}"
                if (( ${#exts[@]} )); then
                    keep=0; for ext in "${exts[@]}"; do [[ "${rel}" == *."${ext}" ]] && keep=1; done
                    (( keep )) || continue
                fi
                install -D -m 0644 "${f}" "${dest}/${rel}"
            done < <(find "${ROOT_DIR}/${src}" -type f -print0)
        elif [[ -f "${ROOT_DIR}/${src}" ]]; then
            install -D -m 0644 "${ROOT_DIR}/${src}" "${dest}/$(basename "${src}")"
        else
            deb_die "KYR_DEB_HEADERS: no ${src}"
        fi
    done
}

# deb_pc <stage>: usr/local/lib/pkgconfig/<KYR_LIB>.pc
deb_pc() {
    local stage="$1" line cflags pc="$1/usr/local/lib/pkgconfig/${KYR_LIB}.pc"
    install -d -m 0755 "${stage}/usr/local/lib/pkgconfig"
    {
        printf 'prefix=/usr/local\nexec_prefix=${prefix}\nlibdir=${exec_prefix}/lib\nincludedir=${prefix}/include%s\n' "${KYR_PC_INCLUDE_SUBDIR:+/${KYR_PC_INCLUDE_SUBDIR}}"
        _deb_arr KYR_PC_VARIABLES
        for line in "${DEB_REPLY[@]}"; do printf '%s\n' "${line}"; done
        printf '\nName: %s\nDescription: %s\nVersion: %s\n' "${KYR_PC_NAME:-${KYR_LIB}}" "${KYR_PC_DESCRIPTION:-${KYR_PKG_DESCRIPTION}}" "${DEB_VERSION}"
        [[ -n "${KYR_PC_REQUIRES_PRIVATE:-}" ]] && printf 'Requires.private: %s\n' "${KYR_PC_REQUIRES_PRIVATE}"
        printf 'Libs: -L${libdir} -l%s\n' "${KYR_LIB}"
        [[ -n "${KYR_PC_LIBS_PRIVATE:-}" ]] && printf 'Libs.private: %s\n' "${KYR_PC_LIBS_PRIVATE}"
        cflags="${KYR_PC_CFLAGS:-}"
        [[ -n "${cflags}" ]] || cflags='-I${includedir}'
        printf 'Cflags: %s\n' "${cflags}"
    } > "${pc}"
    chmod 0644 "${pc}"
}

# deb_install_bins <stage> <name ...>: built release binaries into usr/local/bin, stripped, hardening-gated
deb_install_bins() {
    local stage="$1" b; shift
    (( $# )) || return 0
    install -d -m 0755 "${stage}/usr/local/bin"
    for b in "$@"; do
        install -m 0755 "${ROOT_DIR}/build/release/${b}" "${stage}/usr/local/bin/${b}"
        strip --strip-unneeded "${stage}/usr/local/bin/${b}"
        "${KYR_BUILD_DIR}/check_hardening.sh" "${stage}/usr/local/bin/${b}" || deb_die "hardening gate failed: ${b}"
    done
}

_deb_guard_no_bin() {  # <deb>: a library deb that ships no binary carries no bin directory
    if dpkg-deb -c "$1" | awk '{print $NF}' | grep -qE '^\./usr/(local/)?s?bin/.'; then deb_die "$(basename "$1"): a bin directory in a library deb"; fi
}

_deb_lib_runtime_files() {  # <stage>
    local stage="$1" real="lib${KYR_LIB}.so.${DEB_VERSION}"
    install -d -m 0755 "${stage}/usr/local/lib"
    install -m 0755 "${ROOT_DIR}/build/release/${real}" "${stage}/usr/local/lib/${real}"
    strip --strip-unneeded "${stage}/usr/local/lib/${real}"
    ln -sfn "${real}" "${stage}/usr/local/lib/lib${KYR_LIB}.so.${DEB_MAJOR}"
    "${KYR_BUILD_DIR}/check_hardening.sh" "${stage}/usr/local/lib/${real}" || deb_die "hardening gate failed: ${real}"
}

_deb_lib_dev_files() {  # <stage>
    local stage="$1"
    install -d -m 0755 "${stage}/usr/local/lib"
    deb_install_headers "${stage}"
    install -m 0644 "${ROOT_DIR}/build/release/lib${KYR_LIB}.a" "${stage}/usr/local/lib/lib${KYR_LIB}.a"
    ln -sfn "lib${KYR_LIB}.so.${DEB_VERSION}" "${stage}/usr/local/lib/lib${KYR_LIB}.so"
    [[ "${KYR_DEB_PC:-1}" == 1 ]] && deb_pc "${stage}"
    return 0
}

# deb_lib_split: KYR_PKG and KYR_PKG-dev
deb_lib_split() {
    local pkg="${KYR_PKG:?KYR_PKG}" dev="${KYR_PKG}-dev" stage deb bins=()
    _deb_arr KYR_DEB_LIB_BINS; bins=("${DEB_REPLY[@]}")
    stage="$(deb_stage "${pkg}")"
    _deb_lib_runtime_files "${stage}"
    deb_install_bins "${stage}" "${bins[@]}"
    _deb_fields KYR_DEB_RUNTIME_FIELDS "Depends: $(deb_runtime_depends libc6 "${KYR_DEB_DEPENDS_EXTRA[@]}")"
    deb_control "${stage}" "${pkg}" libs "${DEB_ARCH}" "$(deb_expand "${KYR_PKG_DESCRIPTION}")" "${DEB_REPLY[@]}"
    deb_ldconfig_hooks "${stage}"
    deb_copyright "${stage}" "${pkg}"
    deb="$(deb_build "${stage}" "${pkg}")"
    (( ${#bins[@]} )) || _deb_guard_no_bin "${deb}"

    stage="$(deb_stage "${dev}")"
    _deb_lib_dev_files "${stage}"
    local depends="${pkg} (= ${DEB_VERSION})" d
    _deb_fields KYR_DEB_DEV_DEPENDS; for d in "${DEB_REPLY[@]}"; do depends+=", ${d}"; done
    _deb_fields KYR_DEB_DEV_FIELDS
    deb_control "${stage}" "${dev}" libdevel "${DEB_ARCH}" "$(deb_expand "${KYR_DEB_DEV_DESCRIPTION:-Development files for ${pkg}}")" \
        "Depends: ${depends}" "${DEB_REPLY[@]}"
    deb_copyright "${stage}" "${dev}"
    deb="$(deb_build "${stage}" "${dev}")"
    _deb_guard_no_bin "${deb}"
}

# deb_lib_combined: one KYR_PKG with the runtime and the development files
deb_lib_combined() {
    local pkg="${KYR_PKG:?KYR_PKG}" stage deb bins=()
    _deb_arr KYR_DEB_LIB_BINS; bins=("${DEB_REPLY[@]}")
    stage="$(deb_stage "${pkg}")"
    _deb_lib_runtime_files "${stage}"
    _deb_lib_dev_files "${stage}"
    deb_install_bins "${stage}" "${bins[@]}"
    _deb_fields KYR_DEB_RUNTIME_FIELDS "Depends: $(deb_runtime_depends libc6 "${KYR_DEB_DEPENDS_EXTRA[@]}")"
    deb_control "${stage}" "${pkg}" libs "${DEB_ARCH}" "$(deb_expand "${KYR_PKG_DESCRIPTION}")" "${DEB_REPLY[@]}"
    deb_ldconfig_hooks "${stage}"
    deb_copyright "${stage}" "${pkg}"
    deb="$(deb_build "${stage}" "${pkg}")"
    (( ${#bins[@]} )) || _deb_guard_no_bin "${deb}"
}

# deb_bin <pkg>: binaries, links and share files (KYR_DEB_<P>_*)
deb_bin() {
    local pkg="$1" stage spec src dest l desc
    stage="$(deb_stage "${pkg}")"
    _deb_arr "$(_deb_var "${pkg}" BINS)"; (( ${#DEB_REPLY[@]} )) || deb_die "${pkg}: $(_deb_var "${pkg}" BINS) is empty"
    deb_install_bins "${stage}" "${DEB_REPLY[@]}"
    _deb_arr "$(_deb_var "${pkg}" LINKS)"
    for l in "${DEB_REPLY[@]}"; do ln -sfn "${l#*:}" "${stage}/usr/local/bin/${l%%:*}"; done
    _deb_arr "$(_deb_var "${pkg}" SHARE)"
    for spec in "${DEB_REPLY[@]}"; do
        src="${spec%%:*}"; dest="${stage}/usr/local/share/${spec#*:}"
        [[ -e "${ROOT_DIR}/${src}" ]] || deb_die "${pkg}: no ${src}"
        install -d -m 0755 "$(dirname "${dest}")"
        cp -a "${ROOT_DIR}/${src}" "${dest}"
    done
    [[ -d "${stage}/usr/local/share" ]] && find "${stage}/usr/local/share" -type f -exec chmod 0644 {} +
    local sec="$(_deb_var "${pkg}" SECTION)" dv="$(_deb_var "${pkg}" DESCRIPTION)"
    desc="${!dv:-${KYR_PKG_DESCRIPTION:-${pkg}}}"
    _deb_fields "$(_deb_var "${pkg}" FIELDS)" "Depends: $(deb_runtime_depends libc6 "${KYR_DEB_DEPENDS_EXTRA[@]}")"
    deb_control "${stage}" "${pkg}" "${!sec:-admin}" "${DEB_ARCH}" "$(deb_expand "${desc}")" "${DEB_REPLY[@]}"
    deb_copyright "${stage}" "${pkg}"
    deb_build "${stage}" "${pkg}" > /dev/null
}

# deb_web <pkg>: a web tree (KYR_DEB_<P>_SRC) under usr/local/share/KYR_DEB_<P>_DEST
deb_web() {
    local pkg="$1" stage sv dv desc_v src dest f ext ok
    sv="$(_deb_var "${pkg}" SRC)"; dv="$(_deb_var "${pkg}" DEST)"; desc_v="$(_deb_var "${pkg}" DESCRIPTION)"
    src="${!sv:-}"; dest="${!dv:-}"
    [[ -n "${src}" && -d "${ROOT_DIR}/${src}" ]] || deb_die "${pkg}: ${sv} is not a directory"
    [[ -n "${dest}" ]] || deb_die "${pkg}: ${dv} is not set"
    _deb_arr "$(_deb_var "${pkg}" ALLOW)"
    if (( ${#DEB_REPLY[@]} )); then
        while IFS= read -r -d '' f; do
            ok=0; for ext in "${DEB_REPLY[@]}"; do [[ "${f}" == *."${ext#.}" ]] && ok=1; done
            (( ok )) || deb_die "${pkg}: ${f#"${ROOT_DIR}"/} is not an allowed file type (${DEB_REPLY[*]})"
        done < <(find "${ROOT_DIR}/${src}" -type f -print0)
    fi
    stage="$(deb_stage "${pkg}" share)"
    install -d -m 0755 "$(dirname "${stage}/usr/local/share/${dest}")"
    cp -a "${ROOT_DIR}/${src}" "${stage}/usr/local/share/${dest}"
    find "${stage}/usr/local/share" -type f -exec chmod 0644 {} +
    _deb_fields "$(_deb_var "${pkg}" FIELDS)"
    deb_control "${stage}" "${pkg}" web all "$(deb_expand "${!desc_v:-${pkg}}")" "${DEB_REPLY[@]}"
    deb_copyright "${stage}" "${pkg}"
    deb_build "${stage}" "${pkg}" all > /dev/null
}

# kyr_debs: the build_deb.sh entry: the release library and binaries, every KYR_DEBS entry, SHA256SUMS
kyr_debs() {
    local entry debs=()
    if declare -p KYR_DEBS > /dev/null 2>&1; then debs=("${KYR_DEBS[@]}"); elif [[ -n "${KYR_LIB:-}" ]]; then debs=(lib); fi
    (( ${#debs[@]} )) || deb_die "nothing to package: no KYR_DEBS and no KYR_LIB"
    deb_release_check
    [[ -n "${KYR_LIB:-}" ]] && kyr_build_lib release
    kyr_bin_names; (( ${#KYR_REPLY[@]} )) && kyr_build_bin release
    deb_init
    for entry in "${debs[@]}"; do
        case "${entry}" in
            lib) deb_lib_split ;;
            lib-combined) deb_lib_combined ;;
            bin:*) deb_bin "${entry#bin:}" ;;
            web:*) deb_web "${entry#web:}" ;;
            *) deb_die "KYR_DEBS: unknown entry '${entry}' (lib | lib-combined | bin:<pkg> | web:<pkg>)" ;;
        esac
    done
    deb_sha256sums
    cat "${DEB_OUT_DIR}/SHA256SUMS"
}
