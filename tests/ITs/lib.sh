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
export RH_DEPS_CACHE="${SCRATCH}/cache"
mkdir -p "${RH_DEPS_CACHE}/debs"
cp "${DEBS}"/*.deb "${RH_DEPS_CACHE}/debs/"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# has <pattern> <command ...>: the command's whole output contains the pattern (no early-closed pipes under pipefail)
has() { local pat="$1"; shift; local out; out="$("$@" 2>&1)" || true; grep -q -- "${pat}" <<< "${out}"; }

# instantiate <dir>: the template with the kyr-build pin filled in, as a git repository named kyr_host (tier 3)
instantiate() {
    local dir="$1"
    mkdir -p "${dir}"
    dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/x"
    cp -a "${SCRATCH}/x/usr/local/share/kyr-build/template/." "${dir}/"
    rm -rf "${SCRATCH}/x"
    sed -i "s|<sha256 of kyr-build_2.0.0_all.deb>|${KYR_SHA}|; s|2\.0\.0 |${VER} |" "${dir}/deps.txt"
    ( cd "${dir}" && git init -q -b master && git add -A && git -c user.name=it -c user.email=it@localhost commit -q -m init && git remote add origin git@github.com:owner/kyr_host.git )
}
