#include "kyr/word/word.h"

#include <string.h>

size_t kyr_word_len(const char* s)
{
    return s ? strlen(s) : 0;
}
