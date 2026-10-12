#!/usr/bin/env bash
# The wrapper bootstraps kyr-build by exact version and sha256 into build/sysroot; a wrong hash is refused;
# check passes from the sysroot without dpkg; env prints the exports (the tier law has its own test, tiers.sh). The cache is
# KYR_DEPS_CACHE; a shell that sets only the Utils-era name is refused by the wrapper, deps.sh and vendor.sh, and nothing is
# read or written under it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > "${SCRATCH}/sysroot.log" || { cat "${SCRATCH}/sysroot.log"; fail "sysroot"; }
[[ -f build/sysroot/share/kyr-build/deps.sh && -f build/sysroot/MANIFEST ]] || fail "sysroot content"
grep -q "^kyr-build ${VER} ${KYR_SHA}$" build/sysroot/MANIFEST || fail "MANIFEST line"
grep -q '^export KYR_WORD_DEPS_INCLUDE_DIR=' "${SCRATCH}/sysroot.log" || fail "export prefix from the project file"
./utils/deps.sh check > /dev/null || fail "check after sysroot"
has "^KYR_BUILD_DIR=${R}/build/sysroot/share/kyr-build\$" ./utils/deps.sh env --plain || fail "env --plain"
# a wrong pin: the cached file is refused and removed
sed -i "s|${KYR_SHA}|$(printf '0%.0s' {1..64})|" deps.txt
rm -rf build/sysroot
./utils/deps.sh sysroot > /dev/null 2> "${SCRATCH}/bad.log" && fail "wrong sha256 accepted"
grep -q 'sha256' "${SCRATCH}/bad.log" || fail "no sha256 message"
[[ ! -f "${KYR_DEPS_CACHE}/debs/kyr-build_${VER}_all.deb" ]] || fail "tampered pin left the file in the cache"
# the Utils-era cache name alone is refused, with the name to export instead, before anything is read or written
sed -i "s|$(printf '0%.0s' {1..64})|${KYR_SHA}|" deps.txt
OLD="RH""_DEPS_CACHE"
mkdir -p "${SCRATCH}/old_cache/debs"; cp "${KYR_DEB}" "${SCRATCH}/old_cache/debs/"
before="$(find "${SCRATCH}/old_cache" | sort | sha256sum)"
rm -rf build/sysroot
env -u KYR_DEPS_CACHE "${OLD}=${SCRATCH}/old_cache" HOME="${SCRATCH}/home" ./utils/deps.sh sysroot > /dev/null 2> "${SCRATCH}/old.log" && fail "the wrapper ran with ${OLD} alone"
grep -q "${OLD} is no longer read.*KYR_DEPS_CACHE=${SCRATCH}/old_cache" "${SCRATCH}/old.log" || { cat "${SCRATCH}/old.log"; fail "the wrapper's refusal names neither"; }
[[ ! -e build/sysroot && ! -e "${SCRATCH}/home" ]] || fail "the refused wrapper wrote something"
cp "${KYR_DEB}" "${KYR_DEPS_CACHE}/debs/"
./utils/deps.sh sysroot > /dev/null || fail "sysroot again"
env -u KYR_DEPS_CACHE "${OLD}=${SCRATCH}/old_cache" ROOT_DIR="${R}" build/sysroot/share/kyr-build/deps.sh check > /dev/null 2> "${SCRATCH}/old2.log" && fail "deps.sh ran with ${OLD} alone"
grep -q "${OLD} is no longer read" "${SCRATCH}/old2.log" || { cat "${SCRATCH}/old2.log"; fail "deps.sh's refusal"; }
env -u KYR_DEPS_CACHE "${OLD}=${SCRATCH}/old_cache" ROOT_DIR="${R}" build/sysroot/share/kyr-build/vendor.sh verify > /dev/null 2> "${SCRATCH}/old3.log" && fail "vendor.sh ran with ${OLD} alone"
grep -q "${OLD} is no longer read" "${SCRATCH}/old3.log" || { cat "${SCRATCH}/old3.log"; fail "vendor.sh's refusal"; }
[[ "$(find "${SCRATCH}/old_cache" | sort | sha256sum)" == "${before}" ]] || fail "the Utils-era cache was touched"
env "${OLD}=${SCRATCH}/old_cache" ./utils/deps.sh check > /dev/null || fail "both names set: KYR_DEPS_CACHE is read"
