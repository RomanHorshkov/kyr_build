#!/usr/bin/env bash
# The generated layout records every function-pointer member with its full signature (a member typed by a callback typedef is
# covered by the typedef's own line), so a changed signature inside a struct is refused even when no size or offset moves; a
# hand-written abi/layout.c asserting the same signatures (kyr_host's SIG form) writes the same file, so it is not needed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
g() { git -c user.name=it -c user.email=it@localhost "$@" > /dev/null; }
H=app/include/kyr/word/word.h
cat > "${H}" <<'EOF'
#ifndef KYR_WORD_WORD_H
#define KYR_WORD_WORD_H

#include <stddef.h>
#include <stdint.h>

typedef struct kyr_word_ctx kyr_word_ctx_t;
typedef int (*kyr_word_cb_t)(void* user);

typedef struct
{
    uint32_t size;
    int (*init)(const kyr_word_ctx_t* ctx);
    void (*stop)(void);
    kyr_word_cb_t cb;
    const char* (*name)(int id, ...);
    int (*const fixed)(kyr_word_ctx_t** out, size_t n);
} kyr_word_ops_t;

size_t kyr_word_len(const char* s);

#endif
EOF
g add -A; g commit -q -m "an ops table"
./utils/check_abi.sh --update > /dev/null
for line in '  signature init int (*)(const kyr_word_ctx_t*)' '  signature stop void (*)(void)' \
            '  signature name const char* (*)(int, ...)' '  signature fixed int (* const)(kyr_word_ctx_t**, size_t)' \
            'callback kyr_word_cb_t returns int params 1 (void *)'; do
    grep -Fqx -- "${line}" abi/layout.txt || { cat abi/layout.txt >&2; fail "missing: ${line}"; }
done
grep -q '  signature cb ' abi/layout.txt && fail "a typedef'd member got a signature line of its own"
[[ "$(grep -n 'signature init' abi/layout.txt | cut -d: -f1)" -gt "$(grep -n '  field fixed' abi/layout.txt | cut -d: -f1)" ]] \
    || fail "signature lines follow the struct's field lines"
g add -A; g commit -q -m "abi: first layout"
g tag v0.1.0
./utils/check_abi.sh > /dev/null || fail "the committed layout"
cp abi/layout.txt "${SCRATCH}/generated.txt"

# A changed parameter type moves no size or offset: refused all the same.
sed -i 's/^    int (\*init)(const kyr_word_ctx_t\* ctx);/    int (*init)(kyr_word_ctx_t* ctx);/' "${H}"
git diff --quiet -- "${H}" && fail "test setup: the signature did not change"
out="$(./utils/check_abi.sh 2>&1)" && fail "a changed member signature passed"
grep -q 'without a major bump' <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "refusal message"; }
grep -Fq -- '-  signature init int (*)(const kyr_word_ctx_t*)' <<< "${out}" || fail "the diff names the signature"
g checkout -q -- "${H}"

# kyr_host's hand-written form writes the same file.
cat > abi/layout.c <<'EOF'
#include <stdalign.h>
#include <stddef.h>
#include <stdio.h>

#include <kyr/word/word.h>

#define STRUCT(T)   printf("struct %s size %zu align %zu\n", #T, sizeof(T), alignof(T))
#define FIELD(T, f) printf("  field %s offset %zu size %zu\n", #f, offsetof(T, f), sizeof(((T*)0)->f))
#define SIG(T, f, ...)                                                                                                    \
    do                                                                                                                    \
    {                                                                                                                     \
        _Static_assert(__builtin_types_compatible_p(__typeof__(((T*)0)->f), __VA_ARGS__), #T "." #f " changed its type"); \
        printf("  signature %s %s\n", #f, #__VA_ARGS__);                                                                  \
    } while(0)

int main(void)
{
    printf("data_model pointer %zu long %zu\n", sizeof(void*), sizeof(long));
    STRUCT(kyr_word_ops_t);
    FIELD(kyr_word_ops_t, size);
    FIELD(kyr_word_ops_t, init);
    FIELD(kyr_word_ops_t, stop);
    FIELD(kyr_word_ops_t, cb);
    FIELD(kyr_word_ops_t, name);
    FIELD(kyr_word_ops_t, fixed);
    SIG(kyr_word_ops_t, init, int (*)(const kyr_word_ctx_t*));
    SIG(kyr_word_ops_t, stop, void (*)(void));
    SIG(kyr_word_ops_t, name, const char* (*)(int, ...));
    SIG(kyr_word_ops_t, fixed, int (* const)(kyr_word_ctx_t**, size_t));
    return 0;
}
EOF
./utils/check_abi.sh --update > /dev/null || fail "the hand-written program"
cmp -s abi/layout.txt "${SCRATCH}/generated.txt" || { diff "${SCRATCH}/generated.txt" abi/layout.txt >&2; fail "the hand-written program writes another file"; }
