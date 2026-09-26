#!/usr/bin/env bash
# deps.sh — resolve deps.txt: check [--tiers] | fetch | install [--with-optional] [--downgrade] | sysroot [--with-optional] | env [--plain] | apt-list
#
#   apt    <pkg> [>=ver]                                   dpkg --compare-versions against the minimum
#   own    <pkg> <ver> <owner/repo> [sha256] [optional]    .deb from that repository's GitHub Release v<ver>
#   vendor <name> <ver> <path>                             verified by vendor.sh
#
# check     reports every line; exit 1 on any required drift. With build/sysroot/MANIFEST matching deps.txt the own
#           lines pass without touching dpkg. --tiers also enforces the tier map (tiers.txt next to this file): a
#           repository pins only repositories of a lower tier.
# fetch     downloads every own deb into the cache (${RH_DEPS_CACHE:-~/.cache/rh-deps}/debs).
# install   makes the machine match: apt for apt lines, apt install of the cached debs for own lines (needs sudo).
#           The VM lane only; --downgrade is the one way to move a package down.
# sysroot   no sudo: extracts every own deb into build/sysroot/{include,lib,bin,share}, writes MANIFEST and prints the
#           export lines a build needs. Two repositories pin different versions of one library on one workstation.
# env       prints the export lines for the existing sysroot; --plain prints KEY=VALUE lines for $GITHUB_ENV.
# apt-list  prints the apt package names, one per line (CI installs them once).
#
# A sha256 column is enforced on every cached file in every mode. This file ships in kyr-build; a repository runs it
# through its utils/deps.sh wrapper, which bootstraps the pinned kyr-build into build/sysroot and exports ROOT_DIR.
set -euo pipefail
START_DIR="$(pwd -P)"
cleanup() { cd -- "${START_DIR}"; }
trap cleanup EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
DEPS_FILE="${ROOT_DIR}/deps.txt"
CACHE_DIR="${RH_DEPS_CACHE:-${HOME}/.cache/rh-deps}/debs"
SYSROOT="${ROOT_DIR}/build/sysroot"
TIERS_FILE="${KYR_TIERS_FILE:-${SCRIPT_DIR}/tiers.txt}"
ARCH="$(dpkg --print-architecture)"
die() { printf 'deps.sh: %s\n' "$*" >&2; exit 1; }
[[ -f "${DEPS_FILE}" ]] || die "missing ${DEPS_FILE} (run through the repository's utils/deps.sh wrapper)"
cd -- "${ROOT_DIR}"
export ROOT_DIR

MODE="${1:-check}"; shift || true
WITH_OPTIONAL=0 TIERS=0 PLAIN=0 DOWNGRADE=0
for arg in "$@"; do
    case "${arg}" in
    --with-optional) WITH_OPTIONAL=1 ;;
    --tiers) TIERS=1 ;;
    --plain) PLAIN=1 ;;
    --downgrade) DOWNGRADE=1 ;;
    *) die "unknown option '${arg}'" ;;
    esac
done

SUDO=()
if [[ "${MODE}" == install ]] && (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "not root and sudo not found"
    SUDO=(sudo)
fi

installed_version() {
    { dpkg-query -W -f='${db:Status-Status} ${Version}\n' "$1" 2>/dev/null || true; } | awk '$1=="installed"{print $2}'
}
have_gh() { command -v gh >/dev/null 2>&1 && { [[ -n "${GH_TOKEN:-}" ]] || gh auth status >/dev/null 2>&1; }; }

# Prefix for the export lines: utils/<name>_project.sh -> NAME, else the repository directory name.
var_prefix() {
    local p
    p="$(ls "${ROOT_DIR}"/utils/*_project.sh 2>/dev/null | head -1 || true)"
    if [[ -n "${p}" ]]; then p="$(basename "${p}" _project.sh)"; else p="$(basename "${ROOT_DIR}")"; fi
    printf '%s\n' "${p}" | tr '[:lower:]-' '[:upper:]_'
}

# The repository's own name in the tier map: KYR_REPO, else the origin remote's basename, else the directory.
repo_name() {
    if [[ -n "${KYR_REPO:-}" ]]; then printf '%s\n' "${KYR_REPO}"; return; fi
    local url
    url="$(git -C "${ROOT_DIR}" remote get-url origin 2>/dev/null || true)"
    url="${url%/}"; url="${url%.git}"
    if [[ -n "${url}" ]]; then printf '%s\n' "${url##*[/:]}"; else basename "${ROOT_DIR}"; fi
}

tier_of() {  # name -> tier number; fails when the name (or alias) is not in the map
    awk -v n="$1" '$1 ~ /^[0-9]+$/ { for (i = 2; i <= NF; i++) if ($i == n) { print $1; found = 1; exit } } END { exit !found }' "${TIERS_FILE}"
}

verify_sha() {  # file expected-sha (empty = not enforced)
    local f="$1" want="$2" have
    [[ -z "${want}" ]] && return 0
    have="$(sha256sum "${f}" | awk '{print $1}')"
    [[ "${have}" == "${want}" ]] || { rm -f "${f}"; die "$(basename "${f}"): sha256 ${have} != pinned ${want} (file removed from cache)"; }
}

download_own_deb() {  # pkg ver repo sha -> path
    local pkg="$1" ver="$2" repo="$3" want="$4" tag="v$2" f
    mkdir -p "${CACHE_DIR}"
    for f in "${CACHE_DIR}/${pkg}_${ver}_${ARCH}.deb" "${CACHE_DIR}/${pkg}_${ver}_all.deb"; do
        [[ -s "${f}" ]] && { verify_sha "${f}" "${want}"; printf '%s\n' "${f}"; return 0; }
    done
    if have_gh; then
        gh release download "${tag}" --repo "${repo}" --pattern "${pkg}_${ver}_*.deb" --dir "${CACHE_DIR}" --clobber >/dev/null \
            || die "${pkg} ${ver}: no such asset in ${repo} release ${tag}"
    else
        local api="https://api.github.com/repos/${repo}/releases/tags/${tag}" url name
        local -a auth=(); [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GH_TOKEN}")
        read -r name url < <(curl -fsSL "${auth[@]}" "${api}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    n=a['name']
    if n.startswith('${pkg}_${ver}_') and n.endswith('.deb'): print(n, a['browser_download_url']); break
" ) || true
        [[ -n "${url:-}" ]] || die "${pkg} ${ver}: no such asset in ${repo} release ${tag} (private repo? install gh and log in)"
        curl -fsSL --retry 3 "${auth[@]}" -o "${CACHE_DIR}/${name}.part" "${url}" && mv -f "${CACHE_DIR}/${name}.part" "${CACHE_DIR}/${name}"
    fi
    for f in "${CACHE_DIR}/${pkg}_${ver}_${ARCH}.deb" "${CACHE_DIR}/${pkg}_${ver}_all.deb"; do
        [[ -s "${f}" ]] && { verify_sha "${f}" "${want}"; printf '%s\n' "${f}"; return 0; }
    done
    die "${pkg} ${ver}: download produced no .deb"
}

# own line parser: name ver repo [sha256] [optional]
parse_own() {  # rest -> REPO SHA OPT
    local rest="$1" tok
    REPO="${rest%% *}"; SHA=""; OPT=0
    for tok in ${rest}; do
        [[ "${tok}" =~ ^[0-9a-f]{64}$ ]] && SHA="${tok}"
        [[ "${tok}" == optional ]] && OPT=1
    done
    return 0
}

sysroot_has() {  # pkg ver sha -> 0 if MANIFEST lists exactly this
    [[ -f "${SYSROOT}/MANIFEST" ]] || return 1
    awk -v p="$1" -v v="$2" -v s="$3" '$1==p && $2==v && (s=="" || $3==s) {f=1} END{exit !f}' "${SYSROOT}/MANIFEST"
}

tiers_check() {
    [[ -f "${TIERS_FILE}" ]] || die "tier map not found: ${TIERS_FILE}"
    local self self_tier dep dep_tier bad=0
    self="$(repo_name)"
    self_tier="$(tier_of "${self}")" || die "repository '${self}' is not in the tier map ${TIERS_FILE} (set KYR_REPO to its name)"
    printf 'tiers: %s is tier %s\n' "${self}" "${self_tier}"
    while read -r cls name ver rest; do
        [[ "${cls}" == own ]] || continue
        parse_own "${rest%%#*}"
        dep="${REPO##*/}"
        if ! dep_tier="$(tier_of "${dep}")"; then
            printf '  tier    %-26s %s is not in the tier map\n' "${name}" "${dep}"; bad=1; continue
        fi
        if (( dep_tier < self_tier )); then
            printf '  tier    %-26s %s tier %s ok\n' "${name}" "${dep}" "${dep_tier}"
        else
            printf '  tier    %-26s %s tier %s VIOLATION: a repository pins only lower tiers\n' "${name}" "${dep}" "${dep_tier}"; bad=1
        fi
    done < "${DEPS_FILE}"
    return "${bad}"
}

print_exports() {
    local p fmt='export %s=%q\n'
    p="$(var_prefix)"
    (( PLAIN )) && fmt='%s=%s\n'
    # shellcheck disable=SC2059
    {
        printf "${fmt}" "${p}_DEPS_INCLUDE_DIR" "${SYSROOT}/include"
        printf "${fmt}" "${p}_DEPS_LIB_DIR" "${SYSROOT}/lib"
        printf "${fmt}" KYR_BUILD_DIR "${SYSROOT}/share/kyr-build"
        printf "${fmt}" LD_LIBRARY_PATH "${SYSROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        printf "${fmt}" PKG_CONFIG_PATH "${SYSROOT}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    }
}

case "${MODE}" in
apt-list) awk '$1=="apt"{print $2}' "${DEPS_FILE}"; exit 0 ;;
env)
    [[ -f "${SYSROOT}/MANIFEST" ]] || die "no sysroot at ${SYSROOT} (run: ./utils/deps.sh sysroot)"
    print_exports; exit 0 ;;
esac

declare -a APT_TO_INSTALL=() OWN_TO_INSTALL=()
DRIFT=0
while read -r cls name ver rest; do
    [[ -z "${cls}" || "${cls}" == \#* ]] && continue
    rest="${rest%%#*}"
    case "${cls}" in
    apt)
        inst="$(installed_version "${name}")"
        min="${ver#>=}"
        if [[ -z "${inst}" ]]; then
            printf '  %-7s %-26s MISSING%s\n' apt "${name}" "${min:+ (need >=${min})}"; APT_TO_INSTALL+=("${name}"); DRIFT=1
        elif [[ -n "${min}" && "${min}" != "${ver}" ]] && ! dpkg --compare-versions "${inst}" ge "${min}"; then
            printf '  %-7s %-26s %s < %s TOO OLD\n' apt "${name}" "${inst}" "${min}"; APT_TO_INSTALL+=("${name}"); DRIFT=1
        else
            printf '  %-7s %-26s %s ok\n' apt "${name}" "${inst}"
        fi
        ;;
    own)
        parse_own "${rest}"
        if [[ "${MODE}" == sysroot ]] || { [[ "${MODE}" == check ]] && [[ -f "${SYSROOT}/MANIFEST" ]]; }; then
            if sysroot_has "${name}" "${ver}" "${SHA}"; then
                printf '  %-7s %-26s %s ok (sysroot)\n' own "${name}" "${ver}"
            elif (( OPT )) && (( ! WITH_OPTIONAL )); then
                printf '  %-7s %-26s want %s (optional, not enforced)\n' own "${name}" "${ver}"
            else
                printf '  %-7s %-26s want %s from %s -> sysroot\n' own "${name}" "${ver}" "${REPO}"
                OWN_TO_INSTALL+=("${name} ${ver} ${REPO} ${SHA:--}"); DRIFT=1
            fi
        else
            inst="$(installed_version "${name}")"
            if [[ "${inst}" == "${ver}" ]]; then
                printf '  %-7s %-26s %s ok\n' own "${name}" "${inst}"
            elif (( OPT )) && (( ! WITH_OPTIONAL )); then
                printf '  %-7s %-26s %s (optional, want %s, not enforced)\n' own "${name}" "${inst:-absent}" "${ver}"
            else
                printf '  %-7s %-26s %s -> want %s from %s\n' own "${name}" "${inst:-absent}" "${ver}" "${REPO}"
                OWN_TO_INSTALL+=("${name} ${ver} ${REPO} ${SHA:--}"); DRIFT=1
            fi
        fi
        ;;
    vendor)
        if "${SCRIPT_DIR}/vendor.sh" verify "${name}" >/dev/null 2>&1; then
            printf '  %-7s %-26s %s ok (manifest verified)\n' vendor "${name}" "${ver}"
        else
            printf '  %-7s %-26s %s DRIFT — run utils/vendor.sh verify %s\n' vendor "${name}" "${ver}" "${name}"; DRIFT=1
        fi
        ;;
    *) die "unknown class '${cls}' in deps.txt" ;;
    esac
done < "${DEPS_FILE}"

case "${MODE}" in
check)
    if (( TIERS )); then tiers_check || DRIFT=1; fi
    (( DRIFT == 0 )) && { printf 'deps: matches deps.txt\n'; exit 0; }
    printf 'deps: drift found (run: ./utils/deps.sh sysroot for a no-sudo build, or ./utils/deps.sh install on the VM)\n'; exit 1 ;;
fetch)
    while read -r cls name ver rest; do
        [[ "${cls}" == own ]] || continue
        parse_own "${rest%%#*}"
        deb="$(download_own_deb "${name}" "${ver}" "${REPO}" "${SHA}")"
        printf '  cached: %s\n' "${deb}"
    done < <(grep -E '^own' "${DEPS_FILE}")
    ;;
install)
    if (( ${#APT_TO_INSTALL[@]} )); then
        "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -yqq update
        "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -yqq install "${APT_TO_INSTALL[@]}"
    fi
    APT_FLAGS=(); (( DOWNGRADE )) && APT_FLAGS=(--allow-downgrades)
    for entry in "${OWN_TO_INSTALL[@]}"; do
        read -r pkg ver repo sha <<< "${entry}"; [[ "${sha}" == - ]] && sha=""
        deb="$(download_own_deb "${pkg}" "${ver}" "${repo}" "${sha}")"
        "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -yqq install "${APT_FLAGS[@]}" "${deb}"
    done
    if grep -qE '^vendor' "${DEPS_FILE}"; then "${SCRIPT_DIR}/vendor.sh" verify; fi
    printf 'deps: machine now matches deps.txt\n'
    ;;
sysroot)
    (( ${#APT_TO_INSTALL[@]} )) && die "apt packages missing or too old: ${APT_TO_INSTALL[*]} (install them once with apt)"
    if (( ${#OWN_TO_INSTALL[@]} )) || [[ ! -f "${SYSROOT}/MANIFEST" ]]; then
        # Built beside the live sysroot and swapped in whole: a failed download never leaves a half sysroot, and the
        # kyr-build copy this script may be running from stays readable until the swap.
        NEW="${SYSROOT}.new"
        rm -rf "${NEW}"; mkdir -p "${NEW}/include" "${NEW}/lib" "${NEW}/bin" "${NEW}/share"
        : > "${NEW}/MANIFEST"
        while read -r cls name ver rest; do
            [[ "${cls}" == own ]] || continue
            parse_own "${rest%%#*}"
            (( OPT )) && (( ! WITH_OPTIONAL )) && continue
            deb="$(download_own_deb "${name}" "${ver}" "${REPO}" "${SHA}")"
            tmp="$(mktemp -d)"; dpkg-deb -x "${deb}" "${tmp}"
            for sub in include lib bin share; do
                [[ -d "${tmp}/usr/local/${sub}" ]] && cp -a "${tmp}/usr/local/${sub}/." "${NEW}/${sub}/"
            done
            rm -rf "${tmp}"
            printf '%s %s %s\n' "${name}" "${ver}" "$(sha256sum "${deb}" | awk '{print $1}')" >> "${NEW}/MANIFEST"
            printf '  sysroot: %s %s\n' "${name}" "${ver}"
        done < "${DEPS_FILE}"
        # .pc files must point at the sysroot, not /usr/local
        if [[ -d "${NEW}/lib/pkgconfig" ]]; then sed -i "s|^prefix=.*|prefix=${SYSROOT}|" "${NEW}"/lib/pkgconfig/*.pc 2>/dev/null || true; fi
        rm -rf "${SYSROOT}"; mv "${NEW}" "${SYSROOT}"
    fi
    if grep -qE '^vendor' "${DEPS_FILE}"; then "${SCRIPT_DIR}/vendor.sh" verify >/dev/null; fi
    printf 'deps: sysroot ready at %s\n' "${SYSROOT}"
    print_exports
    ;;
*) die "unknown mode '${MODE}' (check [--tiers] | fetch | install [--with-optional] [--downgrade] | sysroot [--with-optional] | env [--plain] | apt-list)" ;;
esac
