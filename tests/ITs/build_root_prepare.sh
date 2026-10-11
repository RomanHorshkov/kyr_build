#!/usr/bin/env bash
# The shipped build_root.sh prepares a root for apt as a rootless create needs it: apt on the pinned snapshot, no services,
# an empty resolver bind target, /src, and /usr/local/share/fonts made before apt, so fontconfig's postinst never chowns it to a
# group the user namespace does not map.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/x"
BR="${SCRATCH}/x/usr/local/share/kyr-build/build_root.sh"
R="${SCRATCH}/root"; mkdir -p "${R}/etc/apt/sources.list.d" "${R}/etc/apt/apt.conf.d" "${R}/usr/sbin"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "${R}/etc/apt/sources.list.d/ubuntu.sources"
printf 'nameserver 127.0.0.53\n' > "${R}/etc/resolv.conf"
# prepare_apt with the pins it reads, taken from the script itself
bash -c "$(sed -n '/^KYR_BUILD_ROOT_SUITE=/,/^FORMAT=/p; /^prepare_apt()/,/^}/p' "${BR}"); prepare_apt \"\$1\"" prepare "${R}"
[[ -d "${R}/usr/local/share/fonts" ]] || fail "no /usr/local/share/fonts before apt"
[[ -d "${R}/src" ]] || fail "no /src"
grep -q '^deb https://snapshot.ubuntu.com/ubuntu/[0-9T]*Z noble main universe$' "${R}/etc/apt/sources.list" || fail "apt is not on the snapshot"
[[ -z "$(ls -A "${R}/etc/apt/sources.list.d")" ]] || fail "the tarball's own sources stay"
[[ ! -s "${R}/etc/resolv.conf" ]] || fail "the resolver file is not an empty bind target"
[[ -x "${R}/usr/sbin/policy-rc.d" ]] || fail "services may start"
printf 'prepare_apt: snapshot sources, no services, /src and /usr/local/share/fonts before apt\n'
