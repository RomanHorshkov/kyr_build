/**
 * @file time_macros.h
 * @brief conversion helpers.
 */

#ifndef TIME_UNIT_MACROS_H_
#define TIME_UNIT_MACROS_H_

/****************************************************************************
 * PUBLIC INCLUDES
 ****************************************************************************
 */
#include <stddef.h> /* NULL, size_t */

/**
 * @brief second definition
 *
 * @param x Size in seconds.
 *
 * @return Size in seconds as a `size_t` expression.
 */
#ifndef TIME_SIZE_SECOND
#    define TIME_SIZE_SECOND(x) ((size_t)(x) * 1U)
#endif

/**
 * @brief Convert minutes to seconds.
 *
 * @param x Size in minutes.
 *
 * @return Size in seconds as a `size_t` expression.
 */
#ifndef TIME_SIZE_MINUTE_2_SECOND
#    define TIME_SIZE_MINUTE_2_SECOND(x) (TIME_SIZE_SECOND(x) * 60ULL)
#endif

/**
 * @brief Convert hours to seconds.
 *
 * @param x Size in hours.
 *
 * @return Size in seconds as a `size_t` expression.
 */
#ifndef TIME_SIZE_HOUR_2_SECOND
#    define TIME_SIZE_HOUR_2_SECOND(x) (TIME_SIZE_MINUTE_2_SECOND(x) * 60ULL)
#endif

/**
 * @brief Convert days to seconds.
 *
 * @param x Size in GiB.
 *
 * @return Size in seconds as a `size_t` expression.
 */
#ifndef TIME_SIZE_DAY_2_SECOND
#    define TIME_SIZE_DAY_2_SECOND(x) (TIME_SIZE_HOUR_2_SECOND(x) * 24ULL)
#endif

/* Sub-second units. Conversions down (ms → s, ns → ms…) truncate; the _CEIL forms round up. All unsigned long long. */
#ifndef TIME_MS_PER_SECOND
#    define TIME_MS_PER_SECOND 1000ULL
#    define TIME_US_PER_MS     1000ULL
#    define TIME_NS_PER_US     1000ULL
#    define TIME_US_PER_SECOND (TIME_US_PER_MS * TIME_MS_PER_SECOND)
#    define TIME_NS_PER_MS     (TIME_NS_PER_US * TIME_US_PER_MS)
#    define TIME_NS_PER_SECOND (TIME_NS_PER_MS * TIME_MS_PER_SECOND)
#endif

#ifndef TIME_SIZE_SECOND_2_MS
#    define TIME_SIZE_SECOND_2_MS(x)      ((unsigned long long)(x) * TIME_MS_PER_SECOND)
#    define TIME_SIZE_MINUTE_2_MS(x)      (TIME_SIZE_MINUTE_2_SECOND(x) * TIME_MS_PER_SECOND)
#    define TIME_SIZE_HOUR_2_MS(x)        (TIME_SIZE_HOUR_2_SECOND(x) * TIME_MS_PER_SECOND)
#    define TIME_SIZE_DAY_2_MS(x)         (TIME_SIZE_DAY_2_SECOND(x) * TIME_MS_PER_SECOND)
#    define TIME_SIZE_SECOND_2_US(x)      ((unsigned long long)(x) * TIME_US_PER_SECOND)
#    define TIME_SIZE_SECOND_2_NS(x)      ((unsigned long long)(x) * TIME_NS_PER_SECOND)
#    define TIME_SIZE_MS_2_US(x)          ((unsigned long long)(x) * TIME_US_PER_MS)
#    define TIME_SIZE_MS_2_NS(x)          ((unsigned long long)(x) * TIME_NS_PER_MS)
#    define TIME_SIZE_US_2_NS(x)          ((unsigned long long)(x) * TIME_NS_PER_US)
#    define TIME_SIZE_MS_2_SECOND(x)      ((unsigned long long)(x) / TIME_MS_PER_SECOND)
#    define TIME_SIZE_MS_2_SECOND_CEIL(x) (((unsigned long long)(x) + TIME_MS_PER_SECOND - 1ULL) / TIME_MS_PER_SECOND)
#    define TIME_SIZE_US_2_MS(x)          ((unsigned long long)(x) / TIME_US_PER_MS)
#    define TIME_SIZE_US_2_MS_CEIL(x)     (((unsigned long long)(x) + TIME_US_PER_MS - 1ULL) / TIME_US_PER_MS)
#    define TIME_SIZE_US_2_SECOND(x)      ((unsigned long long)(x) / TIME_US_PER_SECOND)
#    define TIME_SIZE_NS_2_US(x)          ((unsigned long long)(x) / TIME_NS_PER_US)
#    define TIME_SIZE_NS_2_MS(x)          ((unsigned long long)(x) / TIME_NS_PER_MS)
#    define TIME_SIZE_NS_2_MS_CEIL(x)     (((unsigned long long)(x) + TIME_NS_PER_MS - 1ULL) / TIME_NS_PER_MS)
#    define TIME_SIZE_NS_2_SECOND(x)      ((unsigned long long)(x) / TIME_NS_PER_SECOND)
#endif

#endif /* TIME_UNIT_MACROS_H_ */
