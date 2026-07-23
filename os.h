#ifndef OS_H_
#define OS_H_

#include <stdint.h>


typedef void (*BLUD_DIR_CALLBACK)(void*, const char*, int64_t, int is_dir);

// Enumerate dir and invoke callback once for each child. Returns 0 on success.
extern int os_get_dir(BLUD_DIR_CALLBACK callback, void* data, const char* dir);

// Copy one file. If to is a directory, append the final name of from.
// Return 0 on success and -1 on failure.
extern int os_copy_file(const char* from, const char* to);

// Copy one directory tree. If to is a directory, append the final name of from.
// Return 0 on success and -1 on failure.
extern int os_copy_dir(const char* from, const char* to);

// Create path and any missing parents: 0 created, 1 existed, 2 failed.
extern int os_mkdir(const char* path);

// Create exactly path, without parents: 0 created, 1 existed, 2 failed.
extern int os_mkdir_one(const char* path);

// Return 0 for missing, 1 for non-directory, or 2 for a real directory.
extern int os_path_type(const char* path);

// Remove one empty directory; return 0 on success and -1 on failure.
extern int os_remove_dir(const char* path);

// Remove one file or link; return 0 on success and -1 on failure.
extern int os_remove_file(const char* path);

// Update path timestamps, creating a missing file; return 0 or -1.
extern int os_touch(const char* path);
extern char* os_getcwd(void);
extern int os_setcwd(const char* path);

#endif // OS_H_
