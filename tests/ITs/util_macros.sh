#!/usr/bin/env bash
# The three macro headers ship as kyr-util-* debs and hold as C11 under the catalog's whole warning set and -Werror, and as C++17:
# every conversion and every flag test is checked at compile time and at run time against the installed copies.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
for h in time-macros memory-macros bit-macros; do
    d="${DEBS}/kyr-util-${h}_${VER}_all.deb"
    [[ -f "${d}" ]] || fail "missing $(basename "${d}")"
    dpkg-deb -x "${d}" "${SCRATCH}/inc"
done
cat > "${SCRATCH}/t.c" <<'SRC'
#include <kyr/util/bit_macros.h>
#include <kyr/util/memory_macros.h>
#include <kyr/util/time_macros.h>
#include <stdio.h>
#define CHECK(c) do { if(!(c)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); return 1; } } while(0)
#ifdef __cplusplus
#    define SASSERT(c) static_assert(c, #c)
#else
#    define SASSERT(c) _Static_assert(c, #c)
#endif
SASSERT(TIME_SIZE_SECOND_2_MS(3) == 3000ULL);
SASSERT(TIME_SIZE_MINUTE_2_MS(2) == 120000ULL);
SASSERT(TIME_SIZE_DAY_2_SECOND(1) == 86400ULL);
SASSERT(TIME_SIZE_MS_2_SECOND(1999) == 1ULL && TIME_SIZE_MS_2_SECOND_CEIL(1999) == 2ULL && TIME_SIZE_MS_2_SECOND_CEIL(2000) == 2ULL);
SASSERT(TIME_SIZE_NS_2_MS(1500000) == 1ULL && TIME_SIZE_NS_2_MS_CEIL(1500000) == 2ULL);
SASSERT(TIME_SIZE_SECOND_2_NS(1) == 1000000000ULL && TIME_SIZE_US_2_NS(7) == 7000ULL);
SASSERT(MEMORY_SIZE_MiB_2_B(4) == 4194304ULL && MEMORY_SIZE_B_2_MiB(4194304) == 4ULL);
SASSERT(MEMORY_SIZE_B_2_KiB(1) == 0ULL && MEMORY_SIZE_B_2_KiB_CEIL(1) == 1ULL && MEMORY_SIZE_B_2_KiB_CEIL(0) == 0ULL);
SASSERT(MEMORY_SIZE_GiB_2_MiB(2) == 2048ULL && MEMORY_SIZE_GiB == MEMORY_SIZE_GiB_2_B(1));
SASSERT(BIT(0) == 1ULL && BIT(63) == 0x8000000000000000ULL && BIT_U32(31) == 0x80000000u);
SASSERT(BIT_TEST_ANY(0x5u, 0x4u) && !BIT_TEST_ANY(0x5u, 0x2u) && BIT_TEST_ALL(0x7u, 0x5u) && !BIT_TEST_ALL(0x6u, 0x5u) && BIT_TEST_NONE(0x6u, 0x1u));
SASSERT(BIT_WITH(0x1u, 0x4u) == 0x5u && BIT_WITHOUT(0x5u, 0x4u) == 0x1u);
SASSERT(BIT_IS_POW2(1024) && !BIT_IS_POW2(1000) && !BIT_IS_POW2(0));
SASSERT(BIT_ALIGN_UP(4097, 4096) == 8192 && BIT_ALIGN_DOWN(4097, 4096) == 4096 && BIT_IS_ALIGNED(8192, 4096));
SASSERT(BIT_MASK_LOW(3) == 7ULL && BIT_MASK_LOW(64) == ~0ULL);
SASSERT(BIT_LOWEST(0x18u) == 0x8u && BIT_LOWEST(0u) == 0u);
int main(void)
{
    unsigned char flags = 0;
    BIT_SET(flags, BIT_U8(1));
    CHECK(flags == 2 && BIT_TEST(flags, BIT_U8(1)));
    BIT_SET(flags, BIT_U8(7));
    BIT_CLEAR(flags, BIT_U8(1));
    CHECK(flags == 0x80);
    BIT_TOGGLE(flags, BIT_U8(0));
    CHECK(flags == 0x81);
    BIT_ASSIGN(flags, BIT_U8(7), 0);
    CHECK(flags == 0x01);
    CHECK(BIT_POPCOUNT(0xF0F0ULL) == 8 && BIT_CTZ(0x80ULL) == 7 && BIT_CLZ(1ULL) == 63);
    puts("ok");
    return 0;
}
SRC
I="${SCRATCH}/inc/usr/local/include"
dpkg-deb -x "${KYR_DEB}" "${SCRATCH}/kb"
mapfile -t WARN < <(ROOT_DIR="${SCRATCH}" bash -c 'source "$1" && printf "%s\n" "${CFLAGS_WARN_ALL[@]}"' _ "${SCRATCH}/kb/usr/local/share/kyr-build/gcc_build_profiles.sh")
(( ${#WARN[@]} > 30 )) || fail "the catalog gave ${#WARN[@]} warning flags"
gcc -std=c11 -O2 "${WARN[@]}" -I"${I}" -o "${SCRATCH}/t_c" "${SCRATCH}/t.c" || fail "C11 compile"
[[ "$("${SCRATCH}/t_c")" == ok ]] || fail "C11 run"
cp "${SCRATCH}/t.c" "${SCRATCH}/t.cpp"
g++ -std=c++17 -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Wcast-qual -Wundef -Werror -I"${I}" -o "${SCRATCH}/t_cpp" "${SCRATCH}/t.cpp" || fail "C++17 compile"
[[ "$("${SCRATCH}/t_cpp")" == ok ]] || fail "C++17 run"
printf 'ok util_macros\n'
