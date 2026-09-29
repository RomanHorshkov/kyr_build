#!/usr/bin/env bash
# The ABI gate on a library with two namespaces: KYR_ABI_TYPE_PREFIX, KYR_ABI_FUNC_PREFIX and KYR_ABI_CONST_PREFIX take lists
# (a string or a bash array), every namespace is covered and exported exactly; with one prefix the second namespace is invisible
# and the exports check says so.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
g() { git -c user.name=it -c user.email=it@localhost "$@" > /dev/null; }
cat > app/include/kyr/word/word.h <<'EOF'
#ifndef KYR_WORD_WORD_H
#define KYR_WORD_WORD_H

#include <stddef.h>
#include <stdint.h>

#define KYR_WORD_LIMIT 16
#define ZAP_LIMIT      32

typedef enum
{
    ZAP_MODE_A = 1,
    ZAP_MODE_B = 2,
} zap_mode_t;

enum
{
    ZAP_KIND_X = 7,
};

typedef struct
{
    uint32_t left;
    uint32_t right;
} zap_pair_t;

size_t kyr_word_len(const char* s);
int    zap_run(zap_pair_t* pair, zap_mode_t mode);

#endif
EOF
cat >> app/src/word.c <<'EOF'

int zap_run(zap_pair_t* pair, zap_mode_t mode)
{
    return pair ? (int)(pair->left + pair->right) + (int)mode : -1;
}
EOF
printf 'KYR_WORD_0 {\n    global: kyr_word_*; zap_*;\n    local: *;\n};\n' > utils/kyr_word.map
g add -A; g commit -q -m "two namespaces"

# One prefix: the second namespace is invisible to the gate, and the exports check finds it.
./utils/check_abi.sh --update > /dev/null
grep -q 'zap' abi/layout.txt && fail "one prefix covered the second namespace"
./utils/build_libs.sh release > /dev/null
out="$(./utils/check_abi.sh --exports 2>&1)" && fail "a function outside the prefix passed the exports check"
grep -q 'exported, not declared: zap_run@@KYR_WORD_0' <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "exports message"; }
rm -f abi/layout.txt

# Lists: a string and an array.
cat >> utils/kyr_word_project.sh <<'EOF'
KYR_ABI_TYPE_PREFIX=(kyr_word_ zap_)
KYR_ABI_FUNC_PREFIX="kyr_word_ zap_"
KYR_ABI_CONST_PREFIX="KYR_WORD_ ZAP_"
EOF
./utils/check_abi.sh --update > /dev/null
for line in 'function zap_run returns int params 2 (zap_pair_t \*, zap_mode_t)' 'function kyr_word_len returns size_t' \
            'struct zap_pair_t size 8 align 4' 'enum zap_mode_t' 'constant ZAP_LIMIT 32' 'constant KYR_WORD_LIMIT 16' \
            'enumerator ZAP_KIND_X 7' 'type zap_mode_t size 4'; do
    grep -q "^${line}" abi/layout.txt || { cat abi/layout.txt >&2; fail "not covered: ${line}"; }
done
g add -A; g commit -q -m "abi: both namespaces"
./utils/check_abi.sh > /dev/null || fail "the committed layout"
./utils/build_libs.sh release > /dev/null
./utils/check_abi.sh --exports > /dev/null || fail "both namespaces exported exactly"

# The second namespace is gated like the first.
sed -i 's/^    uint32_t right;/    uint16_t right;/' app/include/kyr/word/word.h
out="$(./utils/check_abi.sh 2>&1)" && fail "a changed member in the second namespace passed"
grep -q 'without a major bump' <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "refusal message"; }
