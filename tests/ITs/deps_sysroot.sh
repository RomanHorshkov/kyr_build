#!/usr/bin/env bash
# The wrapper bootstraps kyr-build by exact version and sha256 into build/sysroot; a wrong hash is refused;
# check passes from the sysroot without dpkg; env prints the exports; the tier law is enforced.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_host"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > "${SCRATCH}/sysroot.log" || { cat "${SCRATCH}/sysroot.log"; fail "sysroot"; }
[[ -f build/sysroot/share/kyr-build/deps.sh && -f build/sysroot/MANIFEST ]] || fail "sysroot content"
grep -q "^kyr-build ${VER} ${KYR_SHA}$" build/sysroot/MANIFEST || fail "MANIFEST line"
grep -q '^export KYR_WORD_DEPS_INCLUDE_DIR=' "${SCRATCH}/sysroot.log" || fail "export prefix from the project file"
./utils/deps.sh check > /dev/null || fail "check after sysroot"
has "^KYR_BUILD_DIR=${R}/build/sysroot/share/kyr-build\$" ./utils/deps.sh env --plain || fail "env --plain"
has 'kyr_host is tier 3' ./utils/deps.sh check --tiers || fail "tier of the repository"
KYR_REPO=Utils ./utils/deps.sh check --tiers > "${SCRATCH}/t.log" && fail "same-tier pin accepted"
grep -q VIOLATION "${SCRATCH}/t.log" || fail "violation not reported"
KYR_REPO=nobody ./utils/deps.sh check --tiers > /dev/null 2>&1 && fail "unknown repository accepted"
# a wrong pin: the cached file is refused and removed
sed -i "s|${KYR_SHA}|$(printf '0%.0s' {1..64})|" deps.txt
rm -rf build/sysroot
./utils/deps.sh sysroot > /dev/null 2> "${SCRATCH}/bad.log" && fail "wrong sha256 accepted"
grep -q 'sha256' "${SCRATCH}/bad.log" || fail "no sha256 message"
[[ ! -f "${RH_DEPS_CACHE}/debs/kyr-build_${VER}_all.deb" ]] || fail "tampered pin left the file in the cache"
