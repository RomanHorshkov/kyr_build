#include <stdio.h>

#include <kyr/word/word.h>

int main(void)
{
    if (kyr_word_len("kyr") != 3)
    {
        return 1;
    }
    printf("smoke test: the installed package links and answers\n");
    return 0;
}
