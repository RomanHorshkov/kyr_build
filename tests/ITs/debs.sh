#!/usr/bin/env bash
# The packaging recipes from declarations alone (KYR_DEBS): the library split with a header spec, @VERSION@ and @PIN:<pkg>@ in
# the fields and a .pc with extra variables and Libs.private; the combined library deb with a shipped binary; a binary deb with a
# link and share files; a web deb whose allow-list refuses a stray file; the runtime Depends (test and static pins and a paired
# -dev pin left out, an unpaired -dev pin kept); a bin directory refused in a library deb; another notices file.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
# Pins of every kind, tier 4 so the product may pin them; their debs exist in the test cache.
for p in libkyr-alpha libkyr-alpha-dev libkyr-beta-dev kyr-gamma-web libkyr-delta; do
    root="${SCRATCH}/pins/${p}"; mkdir -p "${root}/DEBIAN"
    printf 'Package: %s\nVersion: 1.0.0\nArchitecture: all\nMaintainer: it\nX-Kyr-Tier: 4 core\nDescription: pin\n' "${p}" > "${root}/DEBIAN/control"
    dpkg-deb --build --root-owner-group "${root}" "${KYR_DEPS_CACHE}/debs/${p}_1.0.0_all.deb" > /dev/null
done
printf 'own     libkyr-alpha              1.0.0      owner/kyr_alpha   %s\n' "$(sha256sum "${KYR_DEPS_CACHE}/debs/libkyr-alpha_1.0.0_all.deb" | cut -d' ' -f1)" >> deps.txt
printf 'own     libkyr-alpha-dev          1.0.0      owner/kyr_alpha   %s\n' "$(sha256sum "${KYR_DEPS_CACHE}/debs/libkyr-alpha-dev_1.0.0_all.deb" | cut -d' ' -f1)" >> deps.txt
printf 'own     libkyr-beta-dev           1.0.0      owner/kyr_beta    %s\n' "$(sha256sum "${KYR_DEPS_CACHE}/debs/libkyr-beta-dev_1.0.0_all.deb" | cut -d' ' -f1)" >> deps.txt
printf 'own     kyr-gamma-web             1.0.0      owner/kyr_gamma   %s test\n' "$(sha256sum "${KYR_DEPS_CACHE}/debs/kyr-gamma-web_1.0.0_all.deb" | cut -d' ' -f1)" >> deps.txt
printf 'own     libkyr-delta              1.0.0      owner/kyr_delta   %s static\n' "$(sha256sum "${KYR_DEPS_CACHE}/debs/libkyr-delta_1.0.0_all.deb" | cut -d' ' -f1)" >> deps.txt
mkdir -p app/cli web/word/js share/units
printf '#include "kyr/word/word.h"\nint main(void) { return (int)kyr_word_len(""); }\n' > app/cli/main.c
printf 'export const x = 1;\n' > web/word/js/app.js
printf '<p>word</p>\n' > web/word/index.html
printf '[Unit]\nDescription=word\n' > share/units/word.service
printf 'notices\n' > NOTICE
cat >> utils/kyr_word_project.sh <<'EOF'
KYR_BINS=(word-cli)
KYR_BIN_WORD_CLI_SOURCES=(app/cli/main.c)
KYR_DEBS=(lib bin:kyr-word-tools web:kyr-word-web)
KYR_DEB_HEADERS=(app/include app/include/kyr/word/word.h:compat)
KYR_DEB_DEV_DEPENDS=("libkyr-alpha-dev (>= @PIN:libkyr-alpha-dev@)")
KYR_DEB_DEV_FIELDS=("Breaks: libkyr-word (<< @VERSION@)")
KYR_PC_VARIABLES=('compatdir=${includedir}/compat')
KYR_PC_LIBS_PRIVATE="-lkyr_alpha -pthread"
KYR_PC_CFLAGS='-I${includedir} -I${compatdir}'
KYR_DEB_KYR_WORD_TOOLS_BINS=(word-cli)
KYR_DEB_KYR_WORD_TOOLS_LINKS=("word:word-cli")
KYR_DEB_KYR_WORD_TOOLS_SHARE=("share/units:kyr-word/units")
KYR_DEB_KYR_WORD_TOOLS_DESCRIPTION="kyr word tools @VERSION@"
KYR_DEB_KYR_WORD_WEB_SRC="web/word"
KYR_DEB_KYR_WORD_WEB_DEST="kyr/web/word"
KYR_DEB_KYR_WORD_WEB_ALLOW=(js html)
KYR_DEB_KYR_WORD_WEB_FIELDS=("Depends: kyr-gamma-web (>= @PIN:kyr-gamma-web@)")
KYR_DEB_KYR_WORD_WEB_DESCRIPTION="kyr word web bundle"
EOF
./utils/deps.sh sysroot > /dev/null
./utils/build_deb.sh > "${SCRATCH}/deb.log" 2>&1 || { tail -30 "${SCRATCH}/deb.log"; fail "build_deb with every recipe"; }
D=build/debs
[[ "$(ls "${D}"/*.deb | wc -l)" == 4 ]] || fail "four debs expected"
deb() { compgen -G "${D}/$1" | head -1; }
f() { dpkg-deb -f "$(deb "$1")" "$2"; }
c() { dpkg-deb -c "$(deb "$1")" | awk '{print $NF}'; }
[[ "$(f libkyr-word_0.1.0_*.deb Depends)" == "libkyr-alpha (>= 1.0.0), libkyr-beta-dev (>= 1.0.0), libc6" ]] || fail "runtime Depends: $(f libkyr-word_0.1.0_*.deb Depends)"
[[ "$(f libkyr-word-dev_0.1.0_*.deb Depends)" == "libkyr-word (= 0.1.0), libkyr-alpha-dev (>= 1.0.0)" ]] || fail "-dev Depends"
[[ "$(f libkyr-word-dev_0.1.0_*.deb Breaks)" == "libkyr-word (<< 0.1.0)" ]] || fail "@VERSION@ in a -dev field"
c libkyr-word-dev_0.1.0_*.deb | grep -qx './usr/local/include/kyr/word/word.h' || fail "header tree"
c libkyr-word-dev_0.1.0_*.deb | grep -qx './usr/local/include/compat/word.h' || fail "header with a destination"
dpkg-deb --fsys-tarfile "${D}"/libkyr-word-dev_0.1.0_*.deb | tar -xO ./usr/local/lib/pkgconfig/kyr_word.pc > "${SCRATCH}/pc"
grep -qx 'compatdir=${includedir}/compat' "${SCRATCH}/pc" && grep -qx 'Libs.private: -lkyr_alpha -pthread' "${SCRATCH}/pc" \
    && grep -qx 'Cflags: -I${includedir} -I${compatdir}' "${SCRATCH}/pc" || { cat "${SCRATCH}/pc"; fail ".pc"; }
c kyr-word-tools_0.1.0_*.deb | grep -qx './usr/local/bin/word-cli' && c kyr-word-tools_0.1.0_*.deb | grep -qx './usr/local/share/kyr-word/units/word.service' \
    || fail "binary deb payload"
dpkg-deb -c "${D}"/kyr-word-tools_0.1.0_*.deb | grep -q './usr/local/bin/word -> word-cli' || fail "binary deb link"
[[ "$(f kyr-word-tools_0.1.0_*.deb Description)" == "kyr word tools 0.1.0" && "$(f kyr-word-tools_0.1.0_*.deb Section)" == admin ]] || fail "binary deb control"
[[ "$(f kyr-word-web_0.1.0_all.deb Architecture)" == all && "$(f kyr-word-web_0.1.0_all.deb Depends)" == "kyr-gamma-web (>= 1.0.0)" ]] || fail "web deb control"
c kyr-word-web_0.1.0_all.deb | grep -qx './usr/local/share/kyr/web/word/js/app.js' || fail "web deb payload"
grep -q "X-Kyr-Tier: 5 product" <(f kyr-word-web_0.1.0_all.deb X-Kyr-Tier | sed 's/^/X-Kyr-Tier: /') || fail "tier on every deb"
for d in "${D}"/*.deb; do [[ -f "${d}.buildinfo" ]] || fail "no buildinfo for ${d}"; done

printf 'x\n' > web/word/stray.txt
./utils/build_deb.sh > /dev/null 2>&1 && fail "the allow-list let stray.txt through"
rm web/word/stray.txt

# The combined library deb ships the declared binary; a library deb without one refuses a bin directory.
sed -i 's/^KYR_DEBS=.*/KYR_DEBS=(lib-combined)/' utils/kyr_word_project.sh
printf 'KYR_DEB_LIB_BINS=(word-cli)\nKYR_DEB_COPYRIGHT=NOTICE\n' >> utils/kyr_word_project.sh
./utils/build_deb.sh > "${SCRATCH}/deb2.log" 2>&1 || { tail -30 "${SCRATCH}/deb2.log"; fail "combined deb"; }
c libkyr-word_0.1.0_*.deb | grep -qx './usr/local/bin/word-cli' && c libkyr-word_0.1.0_*.deb | grep -qx './usr/local/lib/libkyr_word.a' \
    && c libkyr-word_0.1.0_*.deb | grep -qx './usr/local/include/kyr/word/word.h' || fail "combined payload"
[[ "$(dpkg-deb --fsys-tarfile "${D}"/libkyr-word_0.1.0_*.deb | tar -xO ./usr/share/doc/libkyr-word/copyright)" == notices ]] || fail "KYR_DEB_COPYRIGHT"
mkdir -p "${SCRATCH}/x/DEBIAN" "${SCRATCH}/x/usr/local/bin"; printf 'Package: x\nVersion: 1\nArchitecture: all\nMaintainer: it\nDescription: x\n' > "${SCRATCH}/x/DEBIAN/control"
: > "${SCRATCH}/x/usr/local/bin/x"; dpkg-deb --build --root-owner-group "${SCRATCH}/x" "${SCRATCH}/x.deb" > /dev/null
has 'a bin directory in a library deb' bash -c 'source utils/gcc_build_profiles.sh; source "${KYR_BUILD_DIR}/lib/kyr.sh"; _deb_guard_no_bin "$1"' _ "${SCRATCH}/x.deb" \
    || fail "the bin guard"
