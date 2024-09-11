#ifndef OS_H_
#define OS_H_

#include <stdint.h>


typedef void (*BLUD_DIR_CALLBACK)(void*, const char*, int64_t, int is_dir);
extern int os_get_dir(BLUD_DIR_CALLBACK callback, void* data, const char* dir);

extern char* get_cwd();

#endif // OS_H_
