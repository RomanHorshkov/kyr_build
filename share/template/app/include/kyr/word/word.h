/**
 * @file word.h
 * @brief kyr_word public surface (template: replace with the repository's own).
 */
#ifndef KYR_WORD_WORD_H
#define KYR_WORD_WORD_H

#include <stddef.h>

#ifdef __cplusplus
extern "C"
{
#endif

/* Length of a NUL-terminated string; 0 for NULL. */
size_t kyr_word_len(const char* s);

#ifdef __cplusplus
}
#endif

#endif /* KYR_WORD_WORD_H */
