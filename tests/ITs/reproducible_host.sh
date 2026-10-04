#!/usr/bin/env bash
# check_reproducible.sh builds its fresh clone where this tree was built: on the host with KYR_ALLOW_HOST_BUILD=1 two host builds
# compare equal, without it the clone's build_deb refuses; with a build root's marker two root builds compare equal.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ID="$(printf 'it' | sha256sum | awk '{print $1}')"
printf 'Format: kyr-build-root/1\nIdentity: %s\n' "${ID}" > "${SCRATCH}/marker"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
cp build/sysroot/share/kyr-build/wrappers/check_reproducible.sh utils/
git add utils/check_reproducible.sh && git -c user.name=it -c user.email=it@localhost commit -q -m reproducible
export KYR_BUILD_ROOT_MARKER="${SCRATCH}/none"
KYR_ALLOW_HOST_BUILD=1 ./utils/build_deb.sh > /dev/null 2>&1 || fail "host build_deb"

out="$(KYR_ALLOW_HOST_BUILD=1 ./utils/check_reproducible.sh 2>&1)" || { printf '%s\n' "${out}"; fail "two host builds do not compare"; }
grep -q '^reproducible: ' <<< "${out}" || { printf '%s\n' "${out}"; fail "no reproducible line"; }
out="$(env -u KYR_ALLOW_HOST_BUILD ./utils/check_reproducible.sh 2>&1)" && fail "the clone built a host release without KYR_ALLOW_HOST_BUILD=1"
grep -q 'a release is built inside the pinned build root' <<< "${out}" || { printf '%s\n' "${out}"; fail "no refusal message"; }
out="$(env -u KYR_ALLOW_HOST_BUILD KYR_BUILD_ROOT_MARKER="${SCRATCH}/marker" ./utils/check_reproducible.sh 2>&1)" ||
    { printf '%s\n' "${out}"; fail "two root builds do not compare"; }
