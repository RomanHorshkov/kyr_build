#!/usr/bin/env bash
# =============================================================================
# vendor.sh — third-party sources vendored under app/extern/<name>/
#
#   ./utils/vendor.sh verify [name]          every kept file matches MANIFEST.sha256
#   ./utils/vendor.sh update <name> <ver>    fetch the upstream release, replace the
#                                            kept files, rewrite UPSTREAM + MANIFEST
#   ./utils/vendor.sh manifest <name>        re-pin the CURRENT tree (after a deliberate
#                                            local patch listed in UPSTREAM `patches:`)
#
# Every vendored directory carries an UPSTREAM record (origin URL, version, archive
# SHA-256, the exact list of kept files) and a MANIFEST.sha256 over those files.
# `verify` is a CI gate: a vendored byte that changed without its record changing is a
# failure, whether it came from an editor, a formatter or a hand patch. Downloads go
# through ${RH_DEPS_CACHE:-$HOME/.cache/rh-deps}/vendor, a cache and never the truth.
#
# Ships in kyr-build; a repository runs it through its utils/vendor.sh wrapper, which
# exports ROOT_DIR.
#
# author  Roman Horshkov <github.com/RomanHorshkov>
# date    2026
# (c) 2026
# =============================================================================
set -euo pipefail

START_DIR="$(pwd -P)"
cleanup() { cd -- "${START_DIR}"; }
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
EXTERN_DIR="${ROOT_DIR}/app/extern"
CACHE_DIR="${RH_DEPS_CACHE:-${HOME}/.cache/rh-deps}/vendor"
cd -- "${ROOT_DIR}"

die() { printf 'vendor.sh: %s\n' "$*" >&2; exit 1; }

# read_field <dir> <key>
read_field() {
    local value
    value="$(sed -nE "s/^${2}:[[:space:]]*//p" "${1}/UPSTREAM" | head -n1)"
    printf '%s\n' "${value}"
}

write_manifest() {
    local dir="$1"
    local keep
    read -r -a keep <<< "$(read_field "${dir}" keep)"
    ( cd "${dir}" && sha256sum -- "${keep[@]}" ) > "${dir}/MANIFEST.sha256"
    printf '  manifest: %s (%d files)\n' "${dir#${ROOT_DIR}/}/MANIFEST.sha256" "${#keep[@]}"
}

verify_one() {
    local dir="$1"
    local name
    name="$(read_field "${dir}" name)"
    [[ -f "${dir}/MANIFEST.sha256" ]] || die "${name}: MANIFEST.sha256 missing (run: vendor.sh manifest ${name})"
    printf '[vendor] %s %s\n' "${name}" "$(read_field "${dir}" version)"
    if ! ( cd "${dir}" && sha256sum --check --quiet --strict MANIFEST.sha256 ); then
        die "${name}: vendored files drifted from MANIFEST.sha256 — restore them or record the patch in UPSTREAM and re-manifest"
    fi
    # Anything beyond the kept files + the two records is a leftover (build tree, tarball, ...).
    local keep extra f
    read -r -a keep <<< "$(read_field "${dir}" keep)"
    extra=0
    while IFS= read -r f; do
        case " ${keep[*]} UPSTREAM MANIFEST.sha256 " in
            *" ${f} "*) ;;
            *) printf '  unexpected file: %s\n' "${f}" >&2; extra=1 ;;
        esac
    done < <(cd "${dir}" && find . -type f | sed 's#^\./##' | sort)
    (( extra == 0 )) || die "${name}: unexpected files in the vendored directory"
    printf '  ok: %d kept files match their record\n' "${#keep[@]}"
}

cmd_verify() {
    local only="${1:-}"
    local dir found=0
    for dir in "${EXTERN_DIR}"/*/; do
        [[ -f "${dir}/UPSTREAM" ]] || continue
        dir="${dir%/}"
        [[ -z "${only}" || "$(read_field "${dir}" name)" == "${only}" ]] || continue
        found=1
        verify_one "${dir}"
    done
    (( found )) || die "no vendored directory ${only:+named ${only} }with an UPSTREAM record under app/extern"
}

cmd_update() {
    local name="${1:-}" version="${2:-}"
    [[ -n "${name}" && -n "${version}" ]] || die "usage: vendor.sh update <name> <version>"
    local dir="${EXTERN_DIR}/${name}"
    [[ -f "${dir}/UPSTREAM" ]] || die "${dir}/UPSTREAM missing"
    local template url strip keep archive tmp sum
    template="$(read_field "${dir}" archive_template)"
    strip="$(read_field "${dir}" strip_components)"
    read -r -a keep <<< "$(read_field "${dir}" keep)"
    url="${template//\{version\}/${version}}"
    mkdir -p "${CACHE_DIR}"
    archive="${CACHE_DIR}/${name}-${version}.tar.gz"
    if [[ ! -s "${archive}" ]]; then
        printf '[vendor] downloading %s\n' "${url}"
        curl -fsSL --retry 3 -o "${archive}.part" "${url}" || die "download failed: ${url}"
        mv -f "${archive}.part" "${archive}"
    else
        printf '[vendor] using cached %s\n' "${archive}"
    fi
    sum="$(sha256sum "${archive}" | cut -d' ' -f1)"
    tmp="$(mktemp -d)"
    tar -xzf "${archive}" -C "${tmp}" --strip-components="${strip:-1}" || die "extract failed"
    local f
    for f in "${keep[@]}"; do
        [[ -f "${tmp}/${f}" ]] || die "upstream ${version} has no file ${f} — adjust keep: in UPSTREAM first"
    done
    # Replace the kept files; drop anything else so the directory is exactly the record.
    find "${dir}" -type f ! -name UPSTREAM ! -name MANIFEST.sha256 -delete
    find "${dir}" -type d -empty -delete 2>/dev/null || true
    for f in "${keep[@]}"; do
        mkdir -p "${dir}/$(dirname "${f}")"
        cp "${tmp}/${f}" "${dir}/${f}"
    done
    rm -rf "${tmp}"
    sed -i -E "s|^version:.*|version: ${version}|; s|^archive:.*|archive: ${url}|; s|^archive_sha256:.*|archive_sha256: ${sum}|" "${dir}/UPSTREAM"
    printf '[vendor] %s -> %s\n  archive: %s\n  sha256:  %s\n' "${name}" "${version}" "${url}" "${sum}"
    write_manifest "${dir}"
    printf '  next: build, run the pipeline, review `git diff`, commit with the version in the message\n'
}

cmd_manifest() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "usage: vendor.sh manifest <name>"
    local dir="${EXTERN_DIR}/${name}"
    [[ -f "${dir}/UPSTREAM" ]] || die "${dir}/UPSTREAM missing"
    write_manifest "${dir}"
}

case "${1:-verify}" in
    verify)   cmd_verify "${2:-}" ;;
    update)   cmd_update "${2:-}" "${3:-}" ;;
    manifest) cmd_manifest "${2:-}" ;;
    -h|--help|help) sed -n '3,20p' "${BASH_SOURCE[0]}" ;;
    *) die "unknown command: $1 (verify | update <name> <version> | manifest <name>)" ;;
esac
