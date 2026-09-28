#!/usr/bin/env bash
# The tier law from declarations (plan 2.1): a new product passes with no line in kyr-build and its debs carry its tier;
# a composition pins a product it was never told about; a product pinning a product, an unlisted repository declaring a
# platform kind, a declaration the fixed map contradicts, a missing or inconsistent header, a deb whose X-Kyr-Tier the fixed
# map contradicts, and a deb with no tier at all from an unlisted repository are refused.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
refused() { # <what> <expected output pattern>: check --tiers in the current repository fails and says why
    local out rc=0
    out="$(./utils/deps.sh check --tiers 2>&1)" || rc=$?
    (( rc != 0 )) || fail "accepted: $1"
    grep -q -- "$2" <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "refused without \"$2\": $1"; }
}

# A new product: nothing in kyr-build names it.
P="${SCRATCH}/kyr_zeta"; instantiate "${P}"; cd "${P}"
./utils/deps.sh sysroot > /dev/null
grep -qw kyr_zeta build/sysroot/share/kyr-build/tiers.txt && fail "the fixed map lists a product"
out="$(./utils/deps.sh check --tiers)" || { printf '%s\n' "${out}" >&2; fail "a new product needs a line in kyr-build"; }
grep -q 'kyr_zeta declares tier 5 (product)' <<< "${out}" || fail "declaration not reported"
grep -q 'kyr-build .* tier 0 ok (X-Kyr-Tier 0 build)' <<< "${out}" || fail "kyr-build's tier not read from its deb"
./utils/build_deb.sh > /dev/null
for d in build/debs/*.deb; do [[ "$(dpkg-deb -f "${d}" X-Kyr-Tier)" == "5 product" ]] || fail "$(basename "${d}") lacks X-Kyr-Tier: 5 product"; done
cp build/debs/*.deb "${RH_DEPS_CACHE}/debs/"
PDEV="$(ls "${P}"/build/debs/libkyr-word-dev_*.deb)"

# A composition pins the product from its deb alone.
C="${SCRATCH}/kyr_server"; instantiate "${C}" "6 composition"; cd "${C}"
pin deps.txt "${PDEV}" owner/kyr_zeta
./utils/deps.sh sysroot > /dev/null
has 'libkyr-word-dev .* tier 5 ok (X-Kyr-Tier 5 product)' ./utils/deps.sh check --tiers || fail "a composition cannot pin a product"
./utils/deps.sh check --tiers > /dev/null || fail "composition refused"

# A product pinning a product.
Q="${SCRATCH}/kyr_other"; instantiate "${Q}"; cd "${Q}"
pin deps.txt "${PDEV}" owner/kyr_zeta
./utils/deps.sh sysroot > /dev/null
refused "a product pinning a product" 'libkyr-word-dev .* tier 5 (X-Kyr-Tier 5 product) VIOLATION'

# An unlisted repository may only be a product.
sed -i 's|^# tier: .*|# tier: 6 composition|' deps.txt
refused "an unlisted repository declaring a platform kind" 'not in the fixed map, which lists every repository but products'

# The fixed map contradicts a listed repository's declaration.
cd "${P}"
KYR_REPO=kyr_host refused "a listed repository declaring another tier" 'tier 3 in the fixed map, declared 5: VIOLATION'
KYR_REPO=kyr_host ./utils/deps.sh check --tiers > /dev/null 2>&1 && fail "kyr_host as a product"
KYR_REPO=kyr_server bash -c 'sed -i "s|^# tier: .*|# tier: 6 composition|" deps.txt && ./utils/deps.sh check --tiers' > /dev/null || fail "a listed repository with its own tier"
sed -i 's|^# tier: .*|# tier: 5 product|' deps.txt

# Missing, doubled and inconsistent headers.
cp deps.txt "${SCRATCH}/deps.keep"
sed -i '/^# tier:/d' deps.txt
refused "no declaration" 'must declare its tier once'
cp "${SCRATCH}/deps.keep" deps.txt; printf '# tier: 5 product\n' >> deps.txt
refused "two declarations" 'must declare its tier once'
cp "${SCRATCH}/deps.keep" deps.txt; sed -i 's|^# tier: .*|# tier: 4 product|' deps.txt
refused "a number that is not the kind's" 'with n the kind'
cp "${SCRATCH}/deps.keep" deps.txt

# Debs whose tier is contradicted or unknown.
fake() { # <pkg> [X-Kyr-Tier]: a minimal deb in the test cache
    local root="${SCRATCH}/fake_$1"
    mkdir -p "${root}/DEBIAN"
    { printf 'Package: %s\nVersion: 1.0.0\nArchitecture: all\nMaintainer: it <it@localhost>\n' "$1"
      [[ -z "${2:-}" ]] || printf 'X-Kyr-Tier: %s\n' "$2"
      printf 'Description: test deb\n'; } > "${root}/DEBIAN/control"
    dpkg-deb --build --root-owner-group "${root}" "${RH_DEPS_CACHE}/debs/$1_1.0.0_all.deb" > /dev/null
    printf '%s\n' "${RH_DEPS_CACHE}/debs/$1_1.0.0_all.deb"
}
pin deps.txt "$(fake libfake-http-dev '1 foundation')" owner/kyr_http
./utils/deps.sh sysroot > /dev/null
refused "a deb the fixed map contradicts" 'says 1, the fixed map says 2 for kyr_http: VIOLATION'
cp "${SCRATCH}/deps.keep" deps.txt
pin deps.txt "$(fake libfake-old-dev)" owner/somewhere
./utils/deps.sh sysroot > /dev/null
refused "a deb with no tier from an unlisted repository" 'carries no X-Kyr-Tier and somewhere is not in the fixed map'
cp "${SCRATCH}/deps.keep" deps.txt
pin deps.txt "$(fake libfake-emlog-dev)" owner/EMlog
./utils/deps.sh sysroot > /dev/null
has 'libfake-emlog-dev .* tier 1 ok (fixed map, EMlog (the deb predates X-Kyr-Tier))' ./utils/deps.sh check --tiers || fail "an old deb of a fixed repository"
