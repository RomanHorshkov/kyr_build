#!/usr/bin/env bash
# SHA256SUMS lists the debs in C-locale order whatever the machine's locale (en_US.UTF-8 sorts "x_…" before "x-dev_…").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
locale -a 2> /dev/null | grep -qix 'en_US.utf8' || { printf 'en_US.UTF-8 not installed: the check needs a locale that sorts differently\n'; exit 0; }
LC_ALL=en_US.UTF-8 ./utils/build_deb.sh > /dev/null
cp build/debs/SHA256SUMS "${SCRATCH}/sums.en_US"
LC_ALL=C ./utils/build_deb.sh > /dev/null
cmp -s build/debs/SHA256SUMS "${SCRATCH}/sums.en_US" || { diff "${SCRATCH}/sums.en_US" build/debs/SHA256SUMS >&2; fail "SHA256SUMS depends on the locale"; }
[[ "$(awk '{print $2}' build/debs/SHA256SUMS | tr '\n' ' ')" == "libkyr-word-dev_0.1.0_$(dpkg --print-architecture).deb libkyr-word_0.1.0_$(dpkg --print-architecture).deb " ]] \
    || { cat build/debs/SHA256SUMS >&2; fail "SHA256SUMS is not in C order"; }
