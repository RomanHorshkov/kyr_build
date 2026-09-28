#!/usr/bin/env bash
# What a product repository learned the hard way: a removed test source leaves no stale executable behind, the -dev deb
# ships every file under app/include (the .def tables headers include), and a comment on a deps.txt line is only a comment.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
./utils/build_libs.sh release > /dev/null

# Two test sources, then one: the second run must not count the removed one's executable.
cp tests/UTs/word_tests.c tests/UTs/extra_tests.c
sed -i 's|^KYR_TEST_SOURCES=.*|KYR_TEST_SOURCES=(tests/UTs/word_tests.c tests/UTs/extra_tests.c)|' utils/kyr_word_project.sh
./utils/build_tests.sh release > /dev/null && ./utils/run_tests.sh release > /dev/null || fail "two test sources"
[[ -x build/release/tests/extra_tests ]] || fail "extra_tests not built"
rm -f tests/UTs/extra_tests.c
sed -i 's|^KYR_TEST_SOURCES=.*|KYR_TEST_SOURCES=(tests/UTs/word_tests.c)|' utils/kyr_word_project.sh
./utils/build_tests.sh release > /dev/null || fail "tests rebuild"
[[ ! -e build/release/tests/extra_tests ]] || fail "a removed test source left its executable"
./utils/run_tests.sh release > /dev/null || fail "run_tests counted a stale executable"

# An X-macro table next to the header travels in the -dev deb.
printf '/* word.def */\nX(one)\n' > app/include/kyr/word/word.def
./utils/build_deb.sh > /dev/null
has './usr/local/include/kyr/word/word.def$' dpkg-deb -c build/debs/libkyr-word-dev_0.1.0_*.deb || fail ".def missing from the -dev deb"
has './usr/local/include/kyr/word/word.h$' dpkg-deb -c build/debs/libkyr-word-dev_0.1.0_*.deb || fail "header missing from the -dev deb"

# Comments on dependency lines: never a version, never a package.
printf 'apt     kyr-no-such-package       # >=99.0 a note, not a minimum\n' >> deps.txt
out="$(./utils/deps.sh check 2>&1 || true)"
grep -q 'kyr-no-such-package *MISSING$' <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "a trailing comment read as a minimum version"; }
[[ "$(./utils/deps.sh apt-list | tail -1)" == kyr-no-such-package ]] || fail "apt-list"
sed -i '$d' deps.txt
printf 'apt     pkg-config                # the .pc files\n' >> deps.txt
./utils/deps.sh check > /dev/null || fail "a commented apt line"
