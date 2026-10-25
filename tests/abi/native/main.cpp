// Prints every value of the ABI probe's layout table, one per line, as
// measured by the native C++ compiler at run time.
#include <stdio.h>

extern "C" const long long steamworks_layout[];
extern "C" const unsigned long long steamworks_layout_count;

int main()
{
    for (unsigned long long i = 0; i < steamworks_layout_count; ++i)
        printf("%lld\n", steamworks_layout[i]);
    return 0;
}
