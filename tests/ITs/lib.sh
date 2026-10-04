#!/usr/bin/env bash
# shellcheck shell=bash
# Shared setup for the integration tests: a scratch directory, the freshly built debs as the only dependency cache,
# and a repository instantiated from the shipped template with the real kyr-build sha256 pinned.
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DEBS="${ROOT_DIR}/build/debs"
VER="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
KYR_DEB="${DEBS}/kyr-build_${VER}_all.deb"
[[ -f "${KYR_DEB}" ]] || { printf 'build the debs first: ./utils/build_deb.sh\n' >&2; exit 1; }
KYR_SHA="$(sha256sum "${KYR_DEB}" | awk '{print $1}')"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/kyr_build_it.XXXXXX")"
trap 'rm -rf "${SCRATCH}"' EXIT
export KYR_DEPS_CACHE="${SCRATCH}/cache" RH_DEPS_CACHE="${SCRATCH}/cache"
export KYR_ALLOW_HOST_BUILD="${KYR_ALLOW_HOST_BUILD:-1}"   # the scratch debs are test builds, wherever they run
mkdir -p "${KYR_DEPS_CACHE}/debs"
cp "${DEBS}"/*.deb "${KYR_DEPS_CACHE}/debs/"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# has <pattern> <command ...>: the command's whole output contains the pattern (no early-closed pipes under pipefail)
has() { local pat="$1"; shift; local out; out="$("$@" 2>&1)" || true; grep -q -- "${pat}" <<< "${out}"; }

# instantiate <dir> [tier]: the template with the kyr-build pin filled in, as a git repository named after <dir>'s basename
# (origin git@github.com:owner/<name>.git). The template declares "# tier: 5 product"; [tier] replaces "5 product".
instantiate() {
    local dir="$1" tier="${2:-}" name
    name="$(basename "${dir}")"
    mkdir -p "${dir}"
    dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/x"
    cp -a "${SCRATCH}/x/usr/local/share/kyr-build/template/." "${dir}/"
    rm -rf "${SCRATCH}/x"
    sed -i -E "s|^own[[:space:]]+kyr-build[[:space:]].*|own     kyr-build                 ${VER}      RomanHorshkov/Utils    ${KYR_SHA}|" "${dir}/deps.txt"
    [[ -z "${tier}" ]] || sed -i "s|^# tier: .*|# tier: ${tier}|" "${dir}/deps.txt"
    ( cd "${dir}" && git init -q -b master && git add -A && git -c user.name=it -c user.email=it@localhost commit -q -m init && git remote add origin "git@github.com:owner/${name}.git" )
}

# pin <deps.txt> <deb> <owner/repo>: append the own line for a deb in the test cache
pin() {
    local file="$1" deb="$2" repo="$3" base pkg ver
    base="$(basename "${deb}" .deb)"; pkg="${base%%_*}"; ver="${base#*_}"; ver="${ver%%_*}"
    printf 'own     %-25s %-10s %-22s %s\n' "${pkg}" "${ver}" "${repo}" "$(sha256sum "${deb}" | awk '{print $1}')" >> "${file}"
}
