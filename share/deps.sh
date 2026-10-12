#!/usr/bin/env bash
# deps.sh — resolve deps.txt: check [--tiers] | fetch | install [--with-optional] [--downgrade] | sysroot [--with-optional] |
#           env [--plain] | apt-list | manifest-verify [--strict] [--with-optional]
#
#   apt    <pkg> [>=ver]                                          dpkg --compare-versions against the minimum
#   own    <pkg> <ver> <owner/repo> [sha256] [optional] [test] [static]
#                                                                 .deb from that repository's GitHub Release v<ver>; test: the
#                                                                 tests need it, static: linked or composed at build time (neither
#                                                                 becomes a runtime Depends, lib/deb.sh)
#   vendor <name> <ver> <path>                                    verified by vendor.sh
#
# check     reports every line; exit 1 on any required drift. With build/sysroot/MANIFEST matching deps.txt the own
#           lines pass without touching dpkg. --tiers also enforces the tier law (plan 2.1, lib/tier.sh): the repository
#           declares its tier in deps.txt ("# tier: <n> <kind>"), every own pin must be of a strictly lower tier, read
#           from the pinned deb's X-Kyr-Tier field; tiers.txt (the platform's fixed repositories only) cross-checks both,
#           and stands in for a deb built before the field existed. A repository tiers.txt does not list is a product.
# fetch     downloads every own deb into the cache (${KYR_DEPS_CACHE:-${RH_DEPS_CACHE:-~/.cache/rh-deps}}/debs).
# install   makes the machine match: apt for apt lines, apt install of the cached debs for own lines (needs sudo).
#           The VM lane only; --downgrade is the one way to move a package down.
# sysroot   no sudo: extracts every own deb into build/sysroot/{include,lib,bin,share}, writes MANIFEST and prints the
#           export lines a build needs. Two repositories pin different versions of one library on one workstation.
# env       prints the export lines for the existing sysroot; --plain prints KEY=VALUE lines for $GITHUB_ENV.
# apt-list  prints the apt package names, one per line (CI installs them once).
# manifest-verify
#           every own line must carry a sha256; the cached deb must hash to it; and that hash must be listed for that file in the
#           SHA256SUMS the component's own release published (cached under <cache>/sums/<owner>_<repo>_v<ver>/). Run after
#           fetch. A component with no release v<ver> yet (or no repository on GitHub yet) whose cached deb hashes to the pin is
#           reported "local, unreleased" and does not fail; --strict fails it (a platform release needs every pin published).
#
# The cache is ${KYR_DEPS_CACHE:-${RH_DEPS_CACHE:-~/.cache/rh-deps}} (debs/, sums/, vendor/).
# A sha256 column is enforced on every cached file in every mode. This file ships in kyr-build; a repository runs it
# through its utils/deps.sh wrapper, which bootstraps the pinned kyr-build into build/sysroot and exports ROOT_DIR.
set -euo pipefail
START_DIR="$(pwd -P)"
cleanup() { cd -- "${START_DIR}"; }
trap cleanup EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
DEPS_FILE="${ROOT_DIR}/deps.txt"
CACHE_ROOT="${KYR_DEPS_CACHE:-${RH_DEPS_CACHE:-${HOME}/.cache/rh-deps}}"
CACHE_DIR="${CACHE_ROOT}/debs"
SUMS_DIR="${CACHE_ROOT}/sums"
SYSROOT="${ROOT_DIR}/build/sysroot"
TIERS_FILE="${KYR_TIERS_FILE:-${SCRIPT_DIR}/tiers.txt}"
# shellcheck source=lib/tier.sh
source "${SCRIPT_DIR}/lib/tier.sh"
ARCH="$(dpkg --print-architecture)"
die() { printf 'deps.sh: %s\n' "$*" >&2; exit 1; }
# deps.txt without comments and blank lines: a `#` starts a comment anywhere on a line, so a trailing note is never read as
# a version, a repository or a hash.
deps_lines() { sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "${DEPS_FILE}"; }
[[ -f "${DEPS_FILE}" ]] || die "missing ${DEPS_FILE} (run through the repository's utils/deps.sh wrapper)"
cd -- "${ROOT_DIR}"
export ROOT_DIR

MODE="${1:-check}"; shift || true
WITH_OPTIONAL=0 TIERS=0 PLAIN=0 DOWNGRADE=0 STRICT=0
for arg in "$@"; do
    case "${arg}" in
    --with-optional) WITH_OPTIONAL=1 ;;
    --strict) STRICT=1 ;;
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

tier_of() {  # name -> tier number; fails when the name is not in the map
    awk -v n="$1" '$1 ~ /^[0-9]+$/ && $2 == n { print $1; found = 1; exit } END { exit !found }' "${TIERS_FILE}"
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
    local self decl self_tier self_kind map dep deb field dep_tier src bad=0
    self="$(repo_name)"
    decl="$(kyr_tier_declared "${DEPS_FILE}")" || return 1
    read -r self_tier self_kind <<< "${decl}"
    printf 'tiers: %s declares tier %s (%s)\n' "${self}" "${self_tier}" "${self_kind}"
    if map="$(tier_of "${self}")"; then
        if [[ "${map}" == "${self_tier}" ]]; then
            printf '  map     %-26s tier %s in the fixed map, agrees\n' "${self}" "${map}"
        else
            printf '  tier    %-26s tier %s in the fixed map, declared %s: VIOLATION\n' "${self}" "${map}" "${self_tier}"; bad=1
        fi
    elif [[ "${self_kind}" == product ]]; then
        printf '  map     %-26s not in the fixed map: a product\n' "${self}"
    else
        printf '  tier    %-26s not in the fixed map, which lists every repository but products; declared %s: VIOLATION\n' "${self}" "${self_kind}"; bad=1
    fi
    while read -r cls name ver rest; do
        [[ "${cls}" == own ]] || continue
        parse_own "${rest%%#*}"
        dep="${REPO##*/}"
        if ! deb="$(download_own_deb "${name}" "${ver}" "${REPO}" "${SHA}" 2>/dev/null)"; then
            if (( OPT )) && (( ! WITH_OPTIONAL )); then printf '  tier    %-26s optional, not resolved: skipped\n' "${name}"; continue; fi
            printf '  tier    %-26s %s %s: the pinned deb cannot be read (run ./utils/deps.sh sysroot)\n' "${name}" "${ver}" "${REPO}"; bad=1; continue
        fi
        field="$(dpkg-deb -f "${deb}" X-Kyr-Tier 2>/dev/null || true)"
        map=""; map="$(tier_of "${dep}")" || map=""
        if [[ -n "${field}" ]]; then
            if ! kyr_tier_valid "${field}"; then
                printf '  tier    %-26s X-Kyr-Tier "%s" is malformed\n' "${name}" "${field}"; bad=1; continue
            fi
            dep_tier="${field%% *}"; src="X-Kyr-Tier ${field}"
            if [[ -n "${map}" && "${map}" != "${dep_tier}" ]]; then
                printf '  tier    %-26s %s says %s, the fixed map says %s for %s: VIOLATION\n' "${name}" "${src}" "${dep_tier}" "${map}" "${dep}"; bad=1; continue
            fi
        elif [[ -n "${map}" ]]; then
            dep_tier="${map}"; src="fixed map, ${dep} (the deb predates X-Kyr-Tier)"
        else
            printf '  tier    %-26s %s carries no X-Kyr-Tier and %s is not in the fixed map: unknown tier\n' "${name}" "$(basename "${deb}")" "${dep}"; bad=1; continue
        fi
        if (( dep_tier < self_tier )); then
            printf '  tier    %-26s tier %s ok (%s)\n' "${name}" "${dep_tier}" "${src}"
        else
            printf '  tier    %-26s tier %s (%s) VIOLATION: a repository pins only lower tiers\n' "${name}" "${dep_tier}" "${src}"; bad=1
        fi
    done < <(deps_lines)
    return "${bad}"
}

release_sums() {  # ver repo -> path of that release's SHA256SUMS (fetched once, then cached); return 2: no release v<ver> yet
    local ver="$1" repo="$2" tag="v$1" dir="${SUMS_DIR}/${2//\//_}_v$1" err
    [[ -s "${dir}/SHA256SUMS" ]] && { printf '%s\n' "${dir}/SHA256SUMS"; return 0; }
    if have_gh; then
        if ! err="$(gh release view "${tag}" --repo "${repo}" --json tagName 2>&1 > /dev/null)"; then
            grep -qE 'release not found|Could not resolve to a Repository' <<< "${err}" && return 2
            die "${repo} ${tag}: ${err}"
        fi
        mkdir -p "${dir}"
        gh release download "${tag}" --repo "${repo}" --pattern SHA256SUMS --dir "${dir}" --clobber > /dev/null \
            || die "${repo} ${tag}: no SHA256SUMS asset"
    else
        local api="https://api.github.com/repos/${repo}/releases/tags/${tag}" url code json
        local -a auth=(); [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GH_TOKEN}")
        json="$(mktemp)"
        code="$(curl -sSL "${auth[@]}" -o "${json}" -w '%{http_code}' "${api}")" || { rm -f "${json}"; die "${repo} ${tag}: GitHub API unreachable"; }
        # Unauthenticated, a private repository answers 404 too: only an authenticated 404 means "not released".
        [[ "${code}" == 404 && -n "${GH_TOKEN:-}" ]] && { rm -f "${json}"; return 2; }
        url="$(python3 -c "
import json,sys
for a in json.load(sys.stdin).get('assets',[]):
    if a['name']=='SHA256SUMS': print(a['browser_download_url']); break
" < "${json}" 2> /dev/null)" || true
        rm -f "${json}"
        [[ -n "${url}" ]] || die "${repo} ${tag}: no SHA256SUMS asset (HTTP ${code}; private repo? install gh and log in)"
        mkdir -p "${dir}"
        curl -fsSL --retry 3 "${auth[@]}" -o "${dir}/SHA256SUMS.part" "${url}" && mv -f "${dir}/SHA256SUMS.part" "${dir}/SHA256SUMS"
    fi
    [[ -s "${dir}/SHA256SUMS" ]] || die "${repo} ${tag}: SHA256SUMS download produced nothing"
    printf '%s\n' "${dir}/SHA256SUMS"
}

manifest_verify() {
    local fail=0 unreleased=0 cls name ver rest deb f have sums rc
    while read -r cls name ver rest; do
        [[ "${cls}" == own ]] || continue
        parse_own "${rest}"
        (( OPT )) && (( ! WITH_OPTIONAL )) && continue
        if [[ -z "${SHA}" ]]; then printf '  %-26s %-9s NO sha256 column\n' "${name}" "${ver}"; fail=1; continue; fi
        deb=""
        for f in "${CACHE_DIR}/${name}_${ver}_${ARCH}.deb" "${CACHE_DIR}/${name}_${ver}_all.deb"; do [[ -s "${f}" ]] && deb="${f}"; done
        if [[ -z "${deb}" ]]; then printf '  %-26s %-9s not cached (run: ./utils/deps.sh fetch)\n' "${name}" "${ver}"; fail=1; continue; fi
        have="$(sha256sum "${deb}" | awk '{print $1}')"
        if [[ "${have}" != "${SHA}" ]]; then printf '  %-26s %-9s cached %s != pinned %s\n' "${name}" "${ver}" "${have}" "${SHA}"; fail=1; continue; fi
        rc=0; sums="$(release_sums "${ver}" "${REPO}")" || rc=$?
        if (( rc == 2 )); then
            printf '  %-26s %-9s local, unreleased: cached = pinned; %s has no release v%s yet\n' "${name}" "${ver}" "${REPO}" "${ver}"
            unreleased=$(( unreleased + 1 )); continue
        fi
        (( rc == 0 )) || exit 1
        if grep -qE "^${SHA}[[:space:]]+\*?$(basename "${deb}")\$" "${sums}"; then
            printf '  %-26s %-9s ok: cached = pinned = %s SHA256SUMS\n' "${name}" "${ver}" "${REPO}"
        else
            printf '  %-26s %-9s pinned %s is NOT the hash %s published for %s\n' "${name}" "${ver}" "${SHA}" "${REPO}" "$(basename "${deb}")"; fail=1
        fi
    done < <(deps_lines)
    (( fail == 0 )) || die "manifest-verify: at least one pinned deb does not match its component's published SHA256SUMS"
    (( unreleased == 0 || ! STRICT )) || die "manifest-verify --strict: ${unreleased} pinned deb(s) not released yet"
    if (( unreleased )); then
        printf 'deps: every pinned deb matches its component release, except %d local, unreleased (cached = pinned; release them before the platform release)\n' "${unreleased}"
    else
        printf 'deps: every pinned deb matches its component release\n'
    fi
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
apt-list) deps_lines | awk '$1=="apt"{print $2}'; exit 0 ;;
manifest-verify) manifest_verify; exit 0 ;;
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
done < <(deps_lines)

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
    done < <(deps_lines | grep -E '^own')
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
    if deps_lines | grep -qE '^vendor'; then "${SCRIPT_DIR}/vendor.sh" verify; fi
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
        done < <(deps_lines)
        # .pc files must point at the sysroot, not /usr/local
        if [[ -d "${NEW}/lib/pkgconfig" ]]; then sed -i "s|^prefix=.*|prefix=${SYSROOT}|" "${NEW}"/lib/pkgconfig/*.pc 2>/dev/null || true; fi
        rm -rf "${SYSROOT}"; mv "${NEW}" "${SYSROOT}"
    fi
    if deps_lines | grep -qE '^vendor'; then "${SCRIPT_DIR}/vendor.sh" verify >/dev/null; fi
    printf 'deps: sysroot ready at %s\n' "${SYSROOT}"
    print_exports
    ;;
*) die "unknown mode '${MODE}' (check [--tiers] | fetch | install [--with-optional] [--downgrade] | sysroot [--with-optional] | env [--plain] | apt-list | manifest-verify [--strict])" ;;
esac
