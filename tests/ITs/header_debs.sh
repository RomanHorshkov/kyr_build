#!/usr/bin/env bash
# kyr-util-<header> installs the kyr/util path and keeps the utils/ path, and takes over the rh-util-* name;
# rh-util-<header> is still built for today's pins; kyr-build ships the template and its VERSION.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
d="${DEBS}/kyr-util-string-view_${VER}_all.deb"
[[ -f "${d}" ]] || fail "missing $(basename "${d}")"
has './usr/local/include/kyr/util/string_view.h' dpkg-deb -c "${d}" || fail "kyr/util path missing"
has './usr/local/include/utils/string_view.h' dpkg-deb -c "${d}" || fail "utils compat path missing"
[[ "$(dpkg-deb -f "${d}" Provides)" == "rh-util-string-view" ]] || fail "Provides"
has 'rh-util-string-view' dpkg-deb -f "${d}" Replaces || fail "Replaces"
[[ -f "${DEBS}/rh-util-string-view_${VER}_all.deb" ]] || fail "rh-util-string-view no longer built"
has './usr/local/include/utils/memory_macros.h' dpkg-deb -c "${DEBS}/rh-util-memory-macros_${VER}_all.deb" || fail "rh-util path"
for p in VERSION deps.sh gcc_build_profiles.sh check_hardening.sh vendor.sh buildinfo.sh build_root.sh tiers.txt lib/deb.sh lib/build.sh lib/tier.sh template/utils/deps.sh template/.clang-format .clang-format; do
    has "./usr/local/share/kyr-build/${p}\$" dpkg-deb -c "${KYR_DEB}" || fail "kyr-build lacks ${p}"
done
[[ "$(dpkg-deb -f "${KYR_DEB}" Architecture)" == all ]] || fail "kyr-build must be arch all"
for f in "${DEBS}"/*.deb; do [[ "$(dpkg-deb -f "${f}" X-Kyr-Tier)" == "0 build" ]] || fail "$(basename "${f}") lacks X-Kyr-Tier: 0 build"; done
[[ "$(dpkg-deb -c "${KYR_DEB}" | awk '{print $2}' | sort -u)" == "root/root" ]] || fail "deb members not root-owned"
