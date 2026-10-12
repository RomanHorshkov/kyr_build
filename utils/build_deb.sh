#!/usr/bin/env bash
# build_deb.sh — build/debs/: kyr-build_<ver>_all.deb (share/ -> /usr/local/share/kyr-build/) and one kyr-util-<header>
# deb per app/include/kyr/util/*.h (installs <kyr/util/x.h>). Deterministic; SHA256SUMS and one .buildinfo per deb.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR KYR_BUILD_DIR="${ROOT_DIR}/share"
KYR_BUILD_INPUTS=(app share VERSION deps.txt utils debian .clang-format)   # what the kyr-build and kyr-util debs are made of
source "${KYR_BUILD_DIR}/lib/deb.sh"
deb_init

stage="$(deb_stage kyr-build share/kyr-build)"
cp -a "${ROOT_DIR}/share/." "${stage}/usr/local/share/kyr-build/"
install -m 0644 "${ROOT_DIR}/.clang-format" "${stage}/usr/local/share/kyr-build/.clang-format"
install -m 0644 "${ROOT_DIR}/.clang-format" "${stage}/usr/local/share/kyr-build/template/.clang-format"
printf '%s\n' "${DEB_VERSION}" > "${stage}/usr/local/share/kyr-build/VERSION"
find "${stage}/usr/local/share/kyr-build" -type f ! -name '*.sh' -exec chmod 0644 {} +
find "${stage}/usr/local/share/kyr-build" -type f -name '*.sh' -exec chmod 0755 {} +
deb_control "${stage}" kyr-build devel all \
    "kyr build tooling: profile catalog, hardening gate, deps.sh, vendor.sh, deb and build libraries, buildinfo, build root, repository template" \
    "Depends: bash, dpkg-dev, binutils"
deb_copyright "${stage}" kyr-build
deb_build "${stage}" kyr-build all

for h in "${ROOT_DIR}"/app/include/kyr/util/*.h; do
    base="$(basename "${h}")"; name="${base%.h}"; slug="${name//_/-}"
    stage="$(deb_stage "kyr-util-${slug}" include/kyr/util)"
    install -m 0644 "${h}" "${stage}/usr/local/include/kyr/util/${base}"
    deb_control "${stage}" "kyr-util-${slug}" libdevel all "kyr header-only utility: <kyr/util/${base}>"
    deb_copyright "${stage}" "kyr-util-${slug}"
    deb_build "${stage}" "kyr-util-${slug}" all
done
deb_sha256sums
cat "${DEB_OUT_DIR}/SHA256SUMS"
