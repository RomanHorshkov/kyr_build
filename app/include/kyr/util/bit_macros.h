/**
 * @file bit_macros.h
 * @brief Flag and bit helpers: one AND, one shift, or one instruction each, usable in constant expressions.
 *
 * @author  Roman Horshkov <github.com/RomanHorshkov>
 * @date    oct 2026
 * (c) 2026
 */

#ifndef BIT_MACROS_H_
#define BIT_MACROS_H_

/* A single bit, as the width the flag word has. */
#ifndef BIT
#    define BIT(n)     (1ULL << (n))
#    define BIT_U8(n)  ((unsigned char)(1u << (n)))
#    define BIT_U16(n) ((unsigned short)(1u << (n)))
#    define BIT_U32(n) (1u << (n))
#    define BIT_U64(n) (1ULL << (n))
#endif

/* Flag tests. ANY: at least one bit of the mask is set (an AND and a branch). ALL: every bit of the mask is set.
 * NONE: no bit of the mask is set. Each evaluates its arguments once per use; pass variables or constants, not calls. */
#ifndef BIT_TEST_ANY
#    define BIT_TEST_ANY(v, m)  (((v) & (m)) != 0)
#    define BIT_TEST_ALL(v, m)  (((v) & (m)) == (m))
#    define BIT_TEST_NONE(v, m) (((v) & (m)) == 0)
#    define BIT_TEST(v, m)      BIT_TEST_ANY(v, m)
#endif

/* Flag writes, in place. The value keeps its own type: the mask is cast back to it so narrow flag bytes stay narrow. */
#ifndef BIT_SET
#    define BIT_SET(v, m)         ((v) |= (m))
#    define BIT_CLEAR(v, m)       ((v) &= (__typeof__(v))~(m))
#    define BIT_TOGGLE(v, m)      ((v) ^= (m))
#    define BIT_ASSIGN(v, m, on)  ((on) ? BIT_SET(v, m) : BIT_CLEAR(v, m))
#    define BIT_WITH(v, m)        ((v) | (m))
#    define BIT_WITHOUT(v, m)     ((v) & ~(m))
#endif

/* Powers of two and alignment (a must be a power of two). */
#ifndef BIT_IS_POW2
#    define BIT_IS_POW2(x)        ((x) != 0 && ((x) & ((x) - 1)) == 0)
#    define BIT_ALIGN_DOWN(x, a)  ((x) & ~((a) - 1))
#    define BIT_ALIGN_UP(x, a)    (((x) + ((a) - 1)) & ~((a) - 1))
#    define BIT_IS_ALIGNED(x, a)  (((x) & ((a) - 1)) == 0)
#    define BIT_MASK_LOW(n)       ((n) >= 64 ? ~0ULL : (1ULL << ((n) & 63)) - 1ULL)
#endif

/* Counts: one instruction where the CPU has it (popcnt, tzcnt, lzcnt), a portable loop otherwise. Argument 0 to
 * BIT_CTZ and BIT_CLZ is undefined, as with the builtins; BIT_LOWEST(x) is x's lowest set bit, 0 for 0. */
#ifndef BIT_POPCOUNT
#    if defined(__GNUC__) || defined(__clang__)
#        define BIT_POPCOUNT(x) __builtin_popcountll((unsigned long long)(x))
#        define BIT_CTZ(x)      __builtin_ctzll((unsigned long long)(x))
#        define BIT_CLZ(x)      __builtin_clzll((unsigned long long)(x))
#    else
static inline int BIT_POPCOUNT(unsigned long long x) { int n = 0; while(x) { x &= x - 1ULL; n++; } return n; }
static inline int BIT_CTZ(unsigned long long x) { int n = 0; while((x & 1ULL) == 0ULL) { x >>= 1; n++; } return n; }
static inline int BIT_CLZ(unsigned long long x) { int n = 0; while((x & (1ULL << 63)) == 0ULL) { x <<= 1; n++; } return n; }
#    endif
#    define BIT_LOWEST(x) ((x) & (0ULL - (unsigned long long)(x)))
#endif

#endif /* BIT_MACROS_H_ */
