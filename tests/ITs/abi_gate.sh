#!/usr/bin/env bash
# The ABI gate (share/abi/check_abi.sh) on a scratch library made from the template: SemVer on the ABI against the last release.
# A changed or removed line, or a member added to an existing struct (even into padding), needs a major; a new public name a
# minor; a newly covered category nothing. Enumerator values, #define constants, unnamed enums, parameter types and exports are
# ABI; moving a declaration is not. The pipeline runs the gate when abi/layout.txt exists.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="${SCRATCH}/kyr_zeta"; instantiate "${R}"; cd "${R}"
./utils/deps.sh sysroot > /dev/null
g() { git -c user.name=it -c user.email=it@localhost "$@" > /dev/null; }
chk() { ./utils/check_abi.sh "$@" 2>&1; }
expect_ok() { local what="$1" out; shift; out="$(chk "$@")" || { printf '%s\n' "${out}" >&2; fail "${what}"; }; }
expect_fail() { # <what> <needle> [args]
    local what="$1" needle="$2" out rc=0; shift 2
    out="$(chk "$@")" || rc=$?
    (( rc != 0 )) && grep -qF -- "${needle}" <<< "${out}" || { printf '%s\n' "${out}" >&2; fail "${what} (exit ${rc}, no '${needle}')"; }
}
H=app/include/kyr/word/word.h
cat > "${H}" <<'EOF'
#ifndef KYR_WORD_WORD_H
#define KYR_WORD_WORD_H

#include <stddef.h>
#include <stdint.h>

#define KYR_WORD_LIMIT 16
#define KYR_WORD_NAME  "word"

typedef enum
{
    KYR_WORD_MODE_A = 1,
    KYR_WORD_MODE_B = 2,
} kyr_word_mode_t;

enum
{
    KYR_WORD_KIND_X = 1,
    KYR_WORD_KIND_Y,
};

typedef struct
{
    uint32_t id;
    uint8_t  flags;
    uint64_t size;
} kyr_word_rec_t;

typedef int (*kyr_word_cb_t)(const kyr_word_rec_t* rec, void* ctx);

size_t kyr_word_len(const char* s);
int    kyr_word_visit(kyr_word_cb_t cb, void* ctx);

#endif
EOF
cat >> app/src/word.c <<'EOF'

int kyr_word_visit(kyr_word_cb_t cb, void* ctx)
{
    kyr_word_rec_t r = {0};
    return cb ? cb(&r, ctx) : 0;
}
EOF
g add -A; g commit -q -m "a public API"

expect_fail "no layout yet" "missing abi/layout.txt"
expect_ok "a first layout is a tooling change" --update
grep -q '^enumerator KYR_WORD_KIND_Y 2$' abi/layout.txt || fail "unnamed enum not covered"
grep -q '^constant KYR_WORD_LIMIT 16$' abi/layout.txt || fail "#define constant not covered"
grep -q 'KYR_WORD_NAME' abi/layout.txt && fail "a string macro taken for a constant"
g add -A; g commit -q -m "abi: first layout"
g tag v0.1.0
expect_ok "the committed layout matches"
sed -i '1s/.*/# a header line of our own/' abi/layout.txt
expect_ok "the header comment line is kept as committed"
g checkout -q abi/layout.txt
cp "${H}" "${SCRATCH}/word.h.base"; cp abi/layout.txt "${SCRATCH}/layout.base"

# The pipeline runs the gate and the exports check once the file exists.
./utils/run_pipeline.sh > "${SCRATCH}/pipeline.log" 2>&1 || { tail -30 "${SCRATCH}/pipeline.log"; fail "pipeline with the ABI stages"; }
grep -q '^== abi$' "${SCRATCH}/pipeline.log" && grep -q '^== abi-exports$' "${SCRATCH}/pipeline.log" || fail "ABI stages not in the pipeline"
expect_ok "exports exactly the declared functions" --exports
sed -i 's/^KYR_WORD_0 {/KYR_WORD_1 {/' utils/kyr_word.map
has "version node major 1 is not VERSION's major 0" ./utils/build_libs.sh release || fail "a map node under another major built"
g checkout -q utils/kyr_word.map && ./utils/build_libs.sh release > /dev/null

# Moving a declaration is not an ABI change.
python3 - "${H}" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
block = s[s.index('typedef enum'):s.index('\nenum\n{') + 1]
s = s.replace(block, '', 1)
s = s.replace('typedef int (*kyr_word_cb_t)', block + 'typedef int (*kyr_word_cb_t)', 1)
open(p, 'w').write(s)
PY
cmp -s "${SCRATCH}/word.h.base" "${H}" && fail "test setup: nothing moved"
expect_ok "declarations reordered"
cp "${SCRATCH}/word.h.base" "${H}"

# A member hidden in padding: sizes and offsets unchanged, still a major.
sed -i 's/^    uint8_t  flags;$/&\n    uint8_t  probe;/' "${H}"
expect_fail "a member added into padding without a major" "without a major bump"
expect_fail "--update refuses it" "needs a raised major" --update
./utils/check_abi.sh --update > /dev/null 2>&1 || cp build/abi/layout.txt abi/layout.txt
expect_fail "a hand-updated layout, uncommitted" "needs a raised major"
g add -A; g commit -q -m "probe without a major"
expect_fail "a commit that needed a major" "needs a raised major"
g reset -q --hard HEAD~1

# The legal major: VERSION, the map's node, --update, one commit.
sed -i 's/^    uint8_t  flags;$/&\n    uint8_t  probe;/' "${H}"
echo 1.0.0 > VERSION; sed -i 's/^KYR_WORD_0 {/KYR_WORD_1 {/' utils/kyr_word.map
expect_ok "--update after raising the major" --update
g add -A; g commit -q -m "1.0.0: probe"
expect_ok "a major committed with its layout"
./utils/build_libs.sh release > /dev/null
expect_ok "exports under the new major's node" --exports
echo 2.0.0 > VERSION
expect_fail "a major raised without --update" "records 1"
g reset -q --hard v0.1.0

# A new name is a minor: refused at the same version, accepted with the minor raised; two additions in one release cycle.
sed -i 's/^int    kyr_word_visit.*$/&\nint    kyr_word_count(void);/' "${H}"
printf '\nint kyr_word_count(void)\n{\n    return 1;\n}\n' >> app/src/word.c
expect_fail "a new function without a minor" "raise VERSION's minor"
expect_fail "--update refuses it" "needs a raised minor" --update
echo 0.2.0 > VERSION
expect_ok "--update with the minor raised" --update
g add -A; g commit -q -m "0.2.0: count"
sed -i 's/^int    kyr_word_count.*$/&\nint    kyr_word_reset(void);/' "${H}"
printf '\nint kyr_word_reset(void)\n{\n    return 0;\n}\n' >> app/src/word.c
expect_ok "a second new name before the next release" --update
g add -A; g commit -q -m "reset"
expect_ok "both names against v0.1.0 at 0.2.0"
g reset -q --hard v0.1.0

# What else is ABI: an enumerator value, a parameter type, a #define constant, an unnamed enum.
for edit in 's/KYR_WORD_MODE_B = 2/KYR_WORD_MODE_B = 3/' 's/^int    kyr_word_visit(kyr_word_cb_t cb, void\* ctx);/int    kyr_word_visit(kyr_word_cb_t cb, const void* ctx);/' \
            's/^#define KYR_WORD_LIMIT 16/#define KYR_WORD_LIMIT 17/' 's/^    KYR_WORD_KIND_X = 1,/    KYR_WORD_KIND_X = 5,/'; do
    cp "${SCRATCH}/word.h.base" "${H}"; sed -i "${edit}" "${H}"
    cmp -s "${SCRATCH}/word.h.base" "${H}" && fail "test setup: ${edit} changed nothing"
    expect_fail "${edit}" "without a major bump"
done
cp "${SCRATCH}/word.h.base" "${H}"

# A gate that learned a category: tooling, no raise. The first layout was written by a gate without unnamed enums.
g checkout -q -b older-gate v0.1.0~1
mkdir -p abi && grep -v '^enumerator ' "${SCRATCH}/layout.base" > abi/layout.txt
g add -A; g commit -q -m "abi: first layout, from a gate without unnamed enums"
expect_fail "a newly covered category" "run --update"
expect_ok "--update adds it without a raise" --update
g add -A; g commit -q -m "abi: unnamed enums"
expect_ok "the history accepts a tooling change"
grep -v '^enumerator \|^constant ' "${SCRATCH}/layout.base" > abi/layout.txt
printf 'constant KYR_WORD_OTHER 1\n' >> abi/layout.txt
expect_fail "a covered category changed along with new ones" "without a major bump"
g checkout -q -f master

# A hand-written layout program (DB_lmdb's form) must list every public struct.
printf '#include <stdio.h>\n#include <kyr/word/word.h>\nint main(void)\n{\n    printf("data_model pointer %%zu long %%zu\\n", sizeof(void*), sizeof(long));\n    return 0;\n}\n' > abi/layout.c
expect_fail "abi/layout.c missing a struct" "struct kyr_word_rec_t is public but not listed"
