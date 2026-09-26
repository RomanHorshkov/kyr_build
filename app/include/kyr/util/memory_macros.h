/**
 * @file memory_macros.h
 * @brief Byte-size conversion helpers used by configuration headers.
 *
 * This header centralizes small, constexpr-style macros that convert units
 * such as kibibytes and mebibytes to byte counts expressed as `size_t`.
 *
 * @author  Roman Horshkov <github.com/RomanHorshkov>
 * @date    may 2026
 * (c) 2026
 *
 */

#ifndef MEMORY_UNIT_MACROS_H_
#define MEMORY_UNIT_MACROS_H_

/****************************************************************************
 * PUBLIC INCLUDES
 ****************************************************************************
 */

#include <stddef.h> /* NULL, size_t */

/****************************************************************************
 * PUBLIC DEFINES
 ****************************************************************************
 */

/**
 * @brief byte definition
 *
 * @param x Size in bytes.
 *
 * @return Size in bytes as a `size_t` expression.
 */
#ifndef MEMORY_SIZE_B
#    define MEMORY_SIZE_B(x) ((size_t)(x))
#endif

/**
 * @brief Convert kibibytes to bytes.
 *
 * @param x Size in KiB.
 *
 * @return Size in bytes as a `size_t` expression.
 */
#ifndef MEMORY_SIZE_KiB_2_B
#    define MEMORY_SIZE_KiB_2_B(x) (MEMORY_SIZE_B(x) * 1024ULL)
#endif

/**
 * @brief Convert mebibytes to bytes.
 *
 * @param x Size in MiB.
 *
 * @return Size in bytes as a `size_t` expression.
 */
#ifndef MEMORY_SIZE_MiB_2_B
#    define MEMORY_SIZE_MiB_2_B(x) (MEMORY_SIZE_KiB_2_B(x) * 1024ULL)
#endif

/**
 * @brief Convert gibibytes to bytes.
 *
 * @param x Size in GiB.
 *
 * @return Size in bytes as a `size_t` expression.
 */
#ifndef MEMORY_SIZE_GiB_2_B
#    define MEMORY_SIZE_GiB_2_B(x) (MEMORY_SIZE_MiB_2_B(x) * 1024ULL)
#endif

#endif /* MEMORY_UNIT_MACROS_H_ */
