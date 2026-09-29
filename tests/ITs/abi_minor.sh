#!/usr/bin/env bash
# ABI numbers: a `*_ABI_MINOR` constant that only rises needs a raised minor, not a major; lowering it, changing a
# `*_ABI_MAJOR` constant or any other constant still needs a major.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
g() { git -c user.name=it -c user.email=it@localhost "$@" > /dev/null; }
chk() { ./utils/check_abi.sh "$@" 2>&1; }
expect_fail() { # <what> <needle> [args]
    local what="$1" needle="$2" out rc=0; shift 2
    out="$(chk "$@")" || rc=$?
    (( rc != 0 )) && grep -qF -- "${needle}" <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "${what} (exit ${rc}, no '${needle}')"; }
}
H=app/include/kyr/word/word.h
sed -i 's|^#include <stddef.h>|&\n\n#define KYR_WORD_ABI_MAJOR 1\n#define KYR_WORD_ABI_MINOR 2\n#define KYR_WORD_LIMIT     16|' "${H}"
grep -q 'KYR_WORD_ABI_MINOR 2' "${H}" || fail "test setup: no ABI numbers in the header"
g add -A; g commit -q -m "ABI numbers"
./utils/check_abi.sh --update > /dev/null
grep -qx 'constant KYR_WORD_ABI_MINOR 2' abi/layout.txt || fail "ABI minor not recorded"
g add -A; g commit -q -m "abi: first layout"
g tag v0.1.0
cp "${H}" "${SCRATCH}/word.h.base"

# The minor rises: a minor, refused at the same version, accepted with VERSION's minor raised.
sed -i 's/^#define KYR_WORD_ABI_MINOR 2/#define KYR_WORD_ABI_MINOR 3/' "${H}"
expect_fail "a raised ABI minor without a raise" "raise VERSION's minor"
expect_fail "--update refuses it" "needs a raised minor" --update
echo 0.2.0 > VERSION
./utils/check_abi.sh --update > /dev/null || fail "--update with the minor raised"
g add -A; g commit -q -m "0.2.0: ABI minor 3"
./utils/check_abi.sh > /dev/null || fail "the history accepts a raised ABI minor with a raised minor"
g reset -q --hard v0.1.0

# A raised ABI minor together with a new constant: still a minor.
sed -i 's/^#define KYR_WORD_ABI_MINOR 2/#define KYR_WORD_ABI_MINOR 3\n#define KYR_WORD_EXTRA     1/' "${H}"
echo 0.2.0 > VERSION
./utils/check_abi.sh --update > /dev/null || fail "a raised ABI minor and a new constant at 0.2.0"
g reset -q --hard v0.1.0

# Everything else about the numbers is a major.
for edit in 's/^#define KYR_WORD_ABI_MINOR 2/#define KYR_WORD_ABI_MINOR 1/' 's/^#define KYR_WORD_ABI_MAJOR 1/#define KYR_WORD_ABI_MAJOR 2/' \
            's/^#define KYR_WORD_LIMIT     16/#define KYR_WORD_LIMIT     17/'; do
    cp "${SCRATCH}/word.h.base" "${H}"; sed -i "${edit}" "${H}"
    cmp -s "${SCRATCH}/word.h.base" "${H}" && fail "test setup: ${edit} changed nothing"
    expect_fail "${edit}" "without a major bump"
done
cp "${SCRATCH}/word.h.base" "${H}"
sed -i 's/^#define KYR_WORD_ABI_MINOR 2/#define KYR_WORD_ABI_MINOR 3/; s/^#define KYR_WORD_LIMIT     16/#define KYR_WORD_LIMIT     17/' "${H}"
expect_fail "a raised ABI minor does not excuse another changed constant" "without a major bump"
