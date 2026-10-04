#!/usr/bin/env bash
# A release is built inside the build root: outside it (no /etc/kyr-build-root) build_deb refuses unless KYR_ALLOW_HOST_BUILD=1,
# whose debs say Build-Root: none; inside it (a marker with an identity) the buildinfo carries that identity and the deb bytes
# are the same. A consumer repository's build_deb refuses before it compiles anything.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ID="$(printf 'it' | sha256sum | awk '{print $1}')"
printf 'Format: kyr-build-root/1\nIdentity: %s\n' "${ID}" > "${SCRATCH}/marker"
build() { env OUT_DIR="${SCRATCH}/$1" KYR_BUILD_ROOT_MARKER="$2" KYR_ALLOW_HOST_BUILD="$3" "${ROOT_DIR}/utils/build_deb.sh"; }

out="$(build host "${SCRATCH}/none" 0 2>&1)" && fail "a host release was built without KYR_ALLOW_HOST_BUILD=1"
grep -q 'a release is built inside the pinned build root' <<< "${out}" || { printf '%s\n' "${out}"; fail "no refusal message"; }
build host "${SCRATCH}/none" 1 > /dev/null 2>&1 || fail "KYR_ALLOW_HOST_BUILD=1 did not build"
grep -q '^Build-Root: none$' "${SCRATCH}/host/kyr-build_${VER}_all.deb.buildinfo" || fail "a host build claims a build root"
build root "${SCRATCH}/marker" 0 > /dev/null 2>&1 || fail "the build refused inside a root"
grep -q "^Build-Root: ${ID}$" "${SCRATCH}/root/kyr-build_${VER}_all.deb.buildinfo" || fail "Build-Root is not the root's identity"
cmp "${SCRATCH}/host/SHA256SUMS" "${SCRATCH}/root/SHA256SUMS" || fail "Build-Root changed the deb bytes"

instantiate "${SCRATCH}/consumer"
cd "${SCRATCH}/consumer"
./utils/deps.sh sysroot > /dev/null
out="$(KYR_BUILD_ROOT_MARKER="${SCRATCH}/none" KYR_ALLOW_HOST_BUILD=0 ./utils/build_deb.sh 2>&1)" && fail "a consumer built a host release"
grep -q 'build/sysroot/share/kyr-build/build_root.sh enter -- ./utils/build_deb.sh' <<< "${out}" || { printf '%s\n' "${out}"; fail "the refusal does not name the pinned build_root.sh"; }
[[ ! -e build/release ]] || fail "the consumer compiled before refusing"
