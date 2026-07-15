#ifndef OS_H_
#define OS_H_

#include <stdint.h>


typedef void (*BLUD_DIR_CALLBACK)(void*, const char*, int64_t, int is_dir);
extern int os_get_dir(BLUD_DIR_CALLBACK callback, void* data, const char* dir);
extern int os_mkdir(const char* path);
extern int os_mkdir_one(const char* path);
extern int os_path_type(const char* path);
extern int os_remove_dir(const char* path);
extern int os_remove_file(const char* path);
extern int os_touch(const char* path);
extern char* os_getcwd(void);
extern int os_setcwd(const char* path);

#endif // OS_H_
