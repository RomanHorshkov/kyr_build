/**
 * @file string_view.h
 * @brief String view utility definitions
 *
 * Provides a lightweight string view structure for non-owning
 * references to character data.
 *
 * @author  Roman Horshkov <124358264+RomanHorshkov@users.noreply.github.com>
 * @date    2025
 * (c) 2025
 */

#ifndef STRING_VIEW_H
#define STRING_VIEW_H

#include <stddef.h> /* for size_t */

/****************************************************************************
 * PUBLIC DEFINES
 ****************************************************************************
 */
/* None */

/****************************************************************************
 * PUBLIC STUCTURED VARIABLES
 ****************************************************************************
 */

/**
 * @brief String view structure
 *
 * Represents a non-owning view into a character array with length.
 */
typedef struct
{
    const char* p; /* may be NULL */
    size_t      n; /* bytes (no trailing NUL required) */
} sv_t;

/****************************************************************************
 * PUBLIC VARIABLES
 ****************************************************************************
 */
/* None */

/****************************************************************************
 * PUBLIC FUNCTIONS DEFINITIONS
 ****************************************************************************
 */
/**
 * @brief Create a string view from a NUL-terminated C string
 * @param[in] z     NUL-terminated string
 * @return sv_t     String view covering the whole string
 */
static inline sv_t sv_c(const char* z, size_t maxlen)
{
    if(!z) return (sv_t){0, 0};
    size_t n = 0;
    while(n < maxlen && z[n] != '\0')
        n++;
    return (sv_t){z, n};
}

/**
 * @brief Set a string view to point to given data
 * @param sv    Pointer to string view to set
 * @param p     Pointer to character data
 * @param n     Length of data in bytes
 */
static inline void sv_set(sv_t* sv, const char* p, size_t n)
{
    if(!sv || !p) return;
    sv->p = p;
    sv->n = n;
}

/**
 * @brief Shift a string view forward by n bytes
 * @param sv    Pointer to string view to modify
 * @param n     Number of bytes to shift
 */
static inline void sv_shift(sv_t* sv, size_t n)
{
    if(!sv || n == 0 || n > sv->n) return;
    sv->p += n;
    sv->n -= n;
}

/**
 * @brief Append data to a string view if contiguous
 * @param sv    Pointer to string view to modify
 * @param p     Pointer to character data to append
 * @param n     Length of data in bytes
 */
static inline void sv_append(sv_t* sv, const char* p, size_t n)
{
    if(!sv || !p || n == 0) return;

    /* If empty, just set */
    if(!sv->p)
    {
        sv->p = p;
        sv->n = n;
        return;
    }

    /* Append only if contiguous */
    if(sv->p + sv->n == p)
    {
        sv->n += n;
    }
    /* else: non-contiguous; for now, ignore:
     // sv->p = p;
     // sv->n = n;
   */
}

/**
 * @brief Reset a string view to empty
 * @param sv    Pointer to string view to reset
 */
static inline void sv_reset(sv_t* sv)
{
    sv->p = NULL;
    sv->n = 0;
}

#endif /* STRING_VIEW_H */
