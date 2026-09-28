#!/usr/bin/env bash
# build_deb.sh — build/debs/<pkg>_<ver>_<arch>.deb (runtime) and <pkg>-dev (app/include/**, .a, .pc, linker symlink), SHA256SUMS,
# one .buildinfo per deb. Deterministic: the same commit gives the same bytes anywhere.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/utils/gcc_build_profiles.sh"
source "${ROOT_DIR}"/utils/*_project.sh
source "${KYR_BUILD_DIR}/lib/deb.sh"
"${ROOT_DIR}/utils/build_libs.sh" release
deb_init
LIB="lib${KYR_LIB}"; REAL="${LIB}.so.${DEB_VERSION}"; SONAME="${LIB}.so.${DEB_MAJOR}"

stage="$(deb_stage "${KYR_PKG}" lib)"
install -m 0755 "${ROOT_DIR}/build/release/${REAL}" "${stage}/usr/local/lib/${REAL}"
strip --strip-unneeded "${stage}/usr/local/lib/${REAL}"
ln -sfn "${REAL}" "${stage}/usr/local/lib/${SONAME}"
"${ROOT_DIR}/utils/check_hardening.sh" "${stage}/usr/local/lib/${REAL}"
deb_control "${stage}" "${KYR_PKG}" libs "${DEB_ARCH}" "${KYR_PKG_DESCRIPTION}" "Depends: $(deb_depends_from_deps_txt libc6)"
deb_ldconfig_hooks "${stage}"
deb_copyright "${stage}" "${KYR_PKG}"
deb_build "${stage}" "${KYR_PKG}"

stage="$(deb_stage "${KYR_PKG}-dev" lib lib/pkgconfig "include/${KYR_INCLUDE_ROOT}")"
while IFS= read -r -d '' h; do
    install -D -m 0644 "${h}" "${stage}/usr/local/include/${h#${ROOT_DIR}/app/include/}"
done < <(find "${ROOT_DIR}/app/include" -type f -print0)   # every public file: headers and the .def tables they include
install -m 0644 "${ROOT_DIR}/build/release/${LIB}.a" "${stage}/usr/local/lib/${LIB}.a"
ln -sfn "${REAL}" "${stage}/usr/local/lib/${LIB}.so"
cat > "${stage}/usr/local/lib/pkgconfig/${KYR_LIB}.pc" <<PC
prefix=/usr/local
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: ${KYR_LIB}
Description: ${KYR_PKG_DESCRIPTION}
Version: ${DEB_VERSION}
Libs: -L\${libdir} -l${KYR_LIB}
Cflags: -I\${includedir}
PC
deb_control "${stage}" "${KYR_PKG}-dev" libdevel "${DEB_ARCH}" "Development files for ${KYR_PKG}" "Depends: ${KYR_PKG} (= ${DEB_VERSION})"
deb_copyright "${stage}" "${KYR_PKG}-dev"
deb_build "${stage}" "${KYR_PKG}-dev"
deb_sha256sums
cat "${DEB_OUT_DIR}/SHA256SUMS"
