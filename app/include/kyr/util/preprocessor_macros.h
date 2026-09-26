/**
 * @file preprocessor_macros.h
 * @defgroup common JWK - Common utilities
 * @brief Lightweight compile-time helpers and portability shims used across the
 *        JWK implementation.
 *
 * This header centralises small, widely-used definitions that keep the rest of
 * the JWK subsystem compact and branch-light:
 *
 * - portable always-inline / likely/unlikely annotations used in hot helpers
 * - a small feature-test macro used by per-key-family headers
 * - common includes (`stddef.h`, `stdint.h`, `string_view.h`)
 *
 * Rationale and usage
 * -------------------
 * The JWK codebase favours small, header-only helpers for extremely hot
 * operations (parsing JOSE identifiers, mapping lengths, etc.). This file
 * intentionally provides only very small building blocks — no runtime state
 * and no allocations. Keep the macros here stable: many other headers depend on
 * them being available at preprocess time.
 *
 * Thread-safety: all macros and inline helpers are header-only and stateless.
 *
 * @note Do not place heavy logic here; prefer separate C files for anything
 *       requiring storage or non-trivial complexity.
 *
 *
 * @author  Roman Horshkov <github.com/RomanHorshkov>
 * @date    dec 2025
 * (c) 2025
 */

#ifndef PREPROCESSOR_COMMON_H
#define PREPROCESSOR_COMMON_H

/****************************************************************************
 * PUBLIC INCLUDES
 ****************************************************************************
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

/****************************************************************************
 * MARK: COMPILATION FEATURES
 ****************************************************************************
 */

#if defined(__GNUC__) || defined(__clang__)
/**
 * @def PREPROC_ALWAYS_INLINE
 * @brief Force inline attribute for GCC/Clang.
 *
 * Applies `__attribute__((always_inline))` to static inline functions, ensuring
 * they are inlined even at low optimization levels. Used for hot-path helpers
 * where inlining is critical for performance.
 *
 * On other compilers, falls back to plain `static inline`.
 */
#    define PREPROC_ALWAYS_INLINE __attribute__((always_inline)) static inline

/**
 * @def PREPROC_LIKELY(x)
 * @brief Branch prediction hint for likely conditions (GCC/Clang).
 *
 * @param x Expression expected to evaluate to true in the common case.
 * @return The input expression with a branch prediction hint applied.
 *
 * Guides the CPU branch predictor to optimize for the case where `x` is true.
 * Use in performance-critical paths where the condition is usually satisfied.
 * On other compilers, transparently returns `x` unchanged.
 */
#    define PREPROC_LIKELY(x)     __builtin_expect(!!(x), 1)

/**
 * @def PREPROC_UNLIKELY(x)
 * @brief Branch prediction hint for unlikely conditions (GCC/Clang).
 *
 * @param x Expression expected to evaluate to false in the common case.
 * @return The input expression with a branch prediction hint applied.
 *
 * Guides the CPU branch predictor to optimize for the case where `x` is false.
 * Use to mark error paths, edge cases, or infrequent branches.
 * On other compilers, transparently returns `x` unchanged.
 */
#    define PREPROC_UNLIKELY(x)   __builtin_expect(!!(x), 0)

/**
 * @def FALLTHROUGH
 * @brief Document an intentional fall-through between `case` labels.
 *
 * Expands to a compiler-specific attribute (for example
 * `__attribute__((fallthrough))`) that documents an intentional fall-through
 * from one `case` to the next, suppressing implicit-fallthrough warnings. If
 * the target compiler does not support the attribute, the macro should be
 * defined empty to preserve portability.
 *
 * Usage example:
 * @code
 * switch (v) {
 * case 1:
 *     FALLTHROUGH;
 * case 2:
 *     break;
 * }
 * @endcode
 */
#    define FALLTHROUGH           __attribute__((fallthrough))

/**
 *
 */
#    define CT_REQUIRE_CONST_AND_LE8(L) \
        (0u * (unsigned)sizeof(char[(__builtin_constant_p(L) && ((L) <= 8u)) ? 1 : -1]))

#else
/**
 * @def PREPROC_ALWAYS_INLINE
 * @brief Force inline attribute (portable fallback).
 *
 * On non-GCC/Clang compilers, this is simply `static inline`. The actual
 * inlining decision is left to the compiler.
 */
#    define PREPROC_ALWAYS_INLINE       static inline

/**
 * @def PREPROC_LIKELY(x)
 * @brief Branch prediction hint (no-op fallback).
 *
 * @param x Expression to evaluate.
 * @return The input expression unchanged.
 *
 * On compilers without `__builtin_expect`, this is a transparent pass-through.
 */
#    define PREPROC_LIKELY(x)           (x)

/**
 * @def PREPROC_UNLIKELY(x)
 * @brief Branch prediction hint (no-op fallback).
 *
 * @param x Expression to evaluate.
 * @return The input expression unchanged.
 *
 * On compilers without `__builtin_expect`, this is a transparent pass-through.
 */
#    define PREPROC_UNLIKELY(x)         (x)

#    define FALLTHROUGH                 /* fallthrough */

/* Fallback: only checks when L is a constant expression (C11+). */
#    define CT_REQUIRE_CONST_AND_LE8(L) (0u * (unsigned)sizeof(char[((L) <= 8u) ? 1 : -1]))

#endif

/****************************************************************************
 * MARK: HELPERS
 ****************************************************************************
 */

/**
 * @def CAT(a, b)
 * @brief Concatenate two preprocessor tokens into a single token.
 *
 * @param a First token.
 * @param b Second token.
 *
 * @note This performs token pasting via the `##` operator: the result is the
 *       single token `a##b`. It expands both arguments before pasting.
 */
#define PRIMITIVE_CAT(_prefix, _suffix)      _prefix##_suffix
#define CAT(_prefix, _suffix)                PRIMITIVE_CAT(_prefix, _suffix)

/**
 * @def ENUM_ID(_prefix, _suffix)
 * @brief Form an enum identifier by token-pasting a prefix and a suffix.
 *
 * This helper expands to `CAT(_prefix, _suffix)` and is intended to be used
 * when building enum identifiers from a common prefix and an element suffix.
 * Example:
 * @code
 *     ENUM_ID(JWK_EC_CRV_, P256) -> JWK_EC_CRV_P256
 * @endcode
 *
 * @param _prefix Enum prefix token (for example `JWK_EC_CRV_`).
 * @param _suffix Enum suffix token (for example `P256`).
 *
 * @note The macro performs raw token pasting and does not add a trailing comma.
 *       If either argument is itself a macro that must be expanded before
 *       pasting, use a two-level indirection (see `CAT` documentation).
 */
#define ENUM_ID(_prefix, _suffix)            CAT(_prefix, _suffix)

#define MAX_INT(a, b)                        (((a) > (b)) ? (a) : (b))

/**
 * @brief Create a standard enum entry.
 *
 * Expands to a simple enum identifier formed by token pasting the given
 * @p _prefix and @p _suffix. Commonly used with prefix macros such as
 * `JWK_EC_CRV_` to produce identifiers like `JWK_EC_CRV_P256`.
 *
 * Example expansion:
 * @code
 * CAT(_prefix, _suffix), -> JWK_EC_CRV_P256
 * @endcode
 *
 * @param _prefix Enum prefix token.
 * @param _suffix Enum suffix token.
 */
#define ENUM_ITEM_STANDARD(_prefix, _suffix) ENUM_ID(_prefix, _suffix),

#ifdef __cplusplus
}
#endif
#endif /* PREPROCESSOR_COMMON_H */
