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

#endif /* TIME_UNIT_MACROS_H_ */
