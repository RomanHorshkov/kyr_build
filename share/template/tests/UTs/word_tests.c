#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include <cmocka.h>

#include "kyr/word/word.h"

static void len_of_null_is_zero(void** state)
{
    (void)state;
    assert_int_equal(kyr_word_len(NULL), 0);
}

static void len_counts_bytes(void** state)
{
    (void)state;
    assert_int_equal(kyr_word_len("kyr"), 3);
}

int main(void)
{
    const struct CMUnitTest tests[] = {
        cmocka_unit_test(len_of_null_is_zero),
        cmocka_unit_test(len_counts_bytes),
    };
    return cmocka_run_group_tests(tests, NULL, NULL);
}
