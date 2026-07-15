#include "../os.h"

#include <stdio.h>
#include <string.h>

typedef struct {
    int real_count;
    int unexpected_count;
} TEST_INFO;

static void count_entry(void* data, const char* name, int64_t timestamp, int is_dir)
{
    TEST_INFO* info = (TEST_INFO*)data;

    (void)timestamp;
    (void)is_dir;
    if(strcmp(name, "real") == 0)
        ++info->real_count;
    else
        ++info->unexpected_count;
}

int main(int argc, char** argv)
{
    TEST_INFO info = { 0, 0 };

    if(argc != 2) {
        fprintf(stderr, "usage: %s directory\n", argv[0]);
        return 2;
    }

    if(os_get_dir(count_entry, &info, argv[1]) != 0) {
        perror("os_get_dir");
        return 1;
    }
    if(info.real_count != 1 || info.unexpected_count != 0) {
        fprintf(stderr, "unexpected entries: real=%d other=%d\n",
                info.real_count, info.unexpected_count);
        return 1;
    }
    return 0;
}
