#!/usr/bin/env bash
# check_reproducible.sh [--keep | --inputs-clean] — the byte reproducibility gate: a fresh clone of HEAD in another directory,
# built with nothing inherited from this environment but HOME, PATH, the deb cache, KYR_ALLOW_HOST_BUILD, KYR_BUILD_ROOT_MARKER,
# TMPDIR and the hardening knobs build_root.sh enter passes, writes the same build/debs/SHA256SUMS as this tree: on the host two
# host builds, inside the build root two root builds. Refuses while a build input (lib/epoch.sh's list) has uncommitted changes:
# the clone would build something else.
#   --keep          leaves the clone for inspection
#   --inputs-clean  exits 0 when no build input has uncommitted changes (the pipeline's question)
# Runs through the repository's utils/check_reproducible.sh wrapper.
set -euo pipefail
ROOT_DIR="${ROOT_DIR:-$(pwd -P)}"
cd -- "${ROOT_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'check_reproducible: %s\n' "$*" >&2; exit 1; }
OLD_CACHE="RH""_DEPS_CACHE"; [[ -z "${!OLD_CACHE:-}" || -n "${KYR_DEPS_CACHE:-}" ]] || die "${OLD_CACHE} is no longer read: export KYR_DEPS_CACHE=${!OLD_CACHE}"   # 3.0.0: the Utils-era name alone is refused
_projects=(utils/*_project.sh)
KYR_BUILD_INPUTS=()
# shellcheck source=lib/epoch.sh
source "${SCRIPT_DIR}/lib/epoch.sh"
KYR_BUILD_INPUTS=("${KYR_BUILD_INPUTS_DEFAULT[@]}")
# shellcheck source=/dev/null
[[ -f "${_projects[0]}" ]] && source utils/gcc_build_profiles.sh && source "${_projects[0]}"
present=()
for p in "${KYR_BUILD_INPUTS[@]}"; do [[ -e "${p}" ]] && present+=("${p}"); done
dirty="$(git status --porcelain -- "${present[@]}")"
KEEP=0
case "${1:-}" in
    --keep) KEEP=1 ;;
    --inputs-clean) [[ -z "${dirty}" ]] && exit 0 || exit 1 ;;
    "") ;;
    *) printf 'usage: %s [--keep | --inputs-clean]\n' "${0##*/}" >&2; exit 2 ;;
esac
[[ -z "${dirty}" ]] || die "uncommitted build inputs, commit them first:"$'\n'"${dirty}"
SUMS="${ROOT_DIR}/build/debs/SHA256SUMS"
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ -f "${SUMS}" ]] || die "no ${SUMS}: run ./utils/build_deb.sh first"
for deb in "${ROOT_DIR}"/build/debs/*.deb; do
    [[ "$(dpkg-deb -f "${deb}" Version)" == "${VERSION}" ]] || die "$(basename "${deb}") is not VERSION ${VERSION}: rebuild"
done
WORK="$(mktemp -d)"
(( KEEP )) || trap 'rm -rf "${WORK}"' EXIT
CLONE="${WORK}/clone/$(basename "${ROOT_DIR}")"
git clone -q --no-hardlinks "${ROOT_DIR}" "${CLONE}"
git -C "${CLONE}" checkout -q --detach "$(git rev-parse HEAD)"
pass=()
for name in KYR_ALLOW_HOST_BUILD KYR_BUILD_ROOT_MARKER TMPDIR KYR_TARGET_GLIBC_MAX KYR_TARGET_GLIBCXX_MAX KYR_TARGET_CXXABI_MAX \
    KYR_TARGET_GCC_MAX CHECK_HARDENING_NEEDED_EXTRA; do
    [[ -n "${!name+x}" ]] && pass+=("${name}=${!name}")
done
env -i HOME="${HOME}" PATH="${PATH}" LANG=C.UTF-8 KYR_DEPS_CACHE="${KYR_DEPS_CACHE:-${HOME}/.cache/rh-deps}" "${pass[@]}" \
    bash -c 'set -euo pipefail
             cd -- "$1"
             eval "$(./utils/deps.sh sysroot | grep "^export")"
             ./utils/build_deb.sh' _ "${CLONE}" > "${WORK}/build.log" 2>&1 ||
    { tail -20 "${WORK}/build.log" >&2; die "the clone does not build (log: ${WORK}/build.log)"; }
if diff -u <(LC_ALL=C sort "${SUMS}") <(LC_ALL=C sort "${CLONE}/build/debs/SHA256SUMS"); then
    printf 'reproducible: a fresh clone of %s in %s builds the same bytes\n' "$(git rev-parse --short HEAD)" "${CLONE}"
    LC_ALL=C sort -k2 "${SUMS}" | sed 's/^/  /'
else
    die "the fresh clone built different bytes (compare with diffoscope; keep the clone with --keep)"
fi
