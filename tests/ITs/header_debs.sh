#!/usr/bin/env bash
# The debs are kyr-build and one kyr-util-<header> per header, nothing else: each kyr-util deb installs its header under kyr/util
# only and declares no package relation; kyr-build ships the template and its VERSION.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
want="kyr-build_${VER}_all.deb"
for h in "${ROOT_DIR}"/app/include/kyr/util/*.h; do n="$(basename "${h}" .h)"; want+=$'\n'"kyr-util-${n//_/-}_${VER}_all.deb"; done
[[ "$(cd "${DEBS}" && ls -1 ./*.deb | sed 's|^\./||' | LC_ALL=C sort)" == "$(LC_ALL=C sort <<< "${want}")" ]] || { ls -1 "${DEBS}"/*.deb >&2; fail "the debs are not exactly kyr-build and one kyr-util per header"; }
for d in "${DEBS}"/kyr-util-*_"${VER}"_all.deb; do
    n="$(basename "${d}")"; n="${n#kyr-util-}"; n="${n%%_*}"; n="${n//-/_}.h"
    has "./usr/local/include/kyr/util/${n}\$" dpkg-deb -c "${d}" || fail "$(basename "${d}") lacks kyr/util/${n}"
    other="$(dpkg-deb -c "${d}" | awk '{print $6}' | grep '^\./usr/local/include/.' | grep -v '^\./usr/local/include/kyr/' || true)"
    [[ -z "${other}" ]] || fail "$(basename "${d}") installs outside kyr/: ${other}"
    for f in Provides Replaces Conflicts Breaks; do [[ -z "$(dpkg-deb -f "${d}" "${f}")" ]] || fail "$(basename "${d}") declares ${f}"; done
done
for f in Provides Replaces Conflicts Breaks; do [[ -z "$(dpkg-deb -f "${KYR_DEB}" "${f}")" ]] || fail "kyr-build declares ${f}"; done
for p in VERSION deps.sh gcc_build_profiles.sh check_hardening.sh vendor.sh buildinfo.sh build_root.sh tiers.txt lib/deb.sh lib/build.sh lib/tier.sh lib/epoch.sh abi/check_abi.sh abi/abi.py template/utils/deps.sh template/utils/check_abi.sh template/.clang-format .clang-format; do
    has "./usr/local/share/kyr-build/${p}\$" dpkg-deb -c "${KYR_DEB}" || fail "kyr-build lacks ${p}"
done
[[ "$(dpkg-deb -f "${KYR_DEB}" Architecture)" == all ]] || fail "kyr-build must be arch all"
for f in "${DEBS}"/*.deb; do [[ "$(dpkg-deb -f "${f}" X-Kyr-Tier)" == "0 build" ]] || fail "$(basename "${f}") lacks X-Kyr-Tier: 0 build"; done
[[ "$(dpkg-deb -c "${KYR_DEB}" | awk '{print $2}' | sort -u)" == "root/root" ]] || fail "deb members not root-owned"
