#ifndef OS_H_
#define OS_H_

#include <stdint.h>

#include "blud.h"

// Path strings crossing this interface are encoded as UTF-8.

typedef struct BLUD_TIMESTAMP_FIELDS {
    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;
    int nanosecond;
} BLUD_TIMESTAMP_FIELDS;

// Convert an absolute timestamp to UTC or local calendar fields.
extern int os_timestamp_to_fields(
    const BLUD_TIMESTAMP* timestamp,
    BLUD_TIMESTAMP_FIELDS* fields,
    int utc
);

// Convert UTC or local calendar fields to an absolute timestamp.
extern int os_fields_to_timestamp(
    const BLUD_TIMESTAMP_FIELDS* fields,
    BLUD_TIMESTAMP* timestamp,
    int utc
);

// The callback receives each child's filesystem timestamp, including directories.
typedef void (*BLUD_DIR_CALLBACK)(
    void*,
    const char*,
    const BLUD_TIMESTAMP*,
    int is_dir
);

// Enumerate dir and invoke callback once for each child. Returns 0 on success.
extern int os_get_dir(BLUD_DIR_CALLBACK callback, void* data, const char* dir);

// Copy one file. If to is a directory, append the final name of from.
// Return 0 on success and -1 on failure.
extern int os_copy_file(const char* from, const char* to);

// Copy one directory tree. If to is a directory, append the final name of from.
// Return 0 on success and -1 on failure.
extern int os_copy_dir(const char* from, const char* to);

// Create exactly path, without parents: 0 created, 1 existed, 2 failed.
extern int os_mkdir(const char* path);

// Return 0 for missing, 1 for non-directory, or 2 for a real directory.
extern int os_path_type(const char* path);

// Store the Unix-epoch system time in timestamp; return 0 or -1.
extern int os_get_system_timestamp(BLUD_TIMESTAMP* timestamp);

// Return the executable path in a heap-allocated string, or NULL on failure.
extern char* os_get_executable_path(void);

// Remove one empty directory; return 0 on success and -1 on failure.
extern int os_remove_dir(const char* path);

// Remove one file or link; return 0 on success and -1 on failure.
extern int os_remove_file(const char* path);

// Update path timestamps, creating a missing file; return 0 or -1.
extern int os_touch(const char* path);
extern char* os_getcwd(void);
extern int os_setcwd(const char* path);

#endif // OS_H_
