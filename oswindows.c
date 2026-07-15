#include "os.h"

#include <windows.h>  // For GetCurrentDirectory()
#include <stdlib.h>    // For malloc(), realloc(), and free()
#include <string.h>

// Windows APIs accept both separators; recognizing both preserves portable paths.
static int is_separator(char c) {
    return c == '/' || c == '\\';
}

// Test for an existing directory when distinguishing collision from failure.
static int dir_exists(const char* path) {
    DWORD attributes = GetFileAttributesA(path);

    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

// Normalize CreateDirectoryA() to the shared 0-created, 1-existed, 2-error contract.
static int make_one_dir(const char* path) {
    if (CreateDirectoryA(path, NULL))
        return 0;
    if (GetLastError() == ERROR_ALREADY_EXISTS && dir_exists(path))
        return 1;
    return 2;
}

// Create only path; unlike os_mkdir(), do not synthesize parent directories.
int os_mkdir_one(const char* path) {
    if (path == NULL || path[0] == '\0')
        return 2;
    return make_one_dir(path);
}

// Create every missing component. Skip drive and UNC roots while splitting.
int os_mkdir(const char* path) {
    size_t len;
    char* buffer;
    char* p;
    int result;

    if (path == NULL || path[0] == '\0')
        return 2;
    if (dir_exists(path))
        return 1;

    len = strlen(path);
    buffer = (char*)malloc(len + 1);
    if (buffer == NULL)
        return 2;
    memcpy(buffer, path, len + 1);

    while (len > 1 && is_separator(buffer[len - 1]) &&
           !(len == 3 && buffer[1] == ':'))
        buffer[--len] = '\0';

    p = buffer;
    if (is_separator(p[0]) && is_separator(p[1])) {
        p += 2;
        while (*p != '\0' && !is_separator(*p))
            ++p;
        while (is_separator(*p))
            ++p;
        while (*p != '\0' && !is_separator(*p))
            ++p;
    } else if (p[0] != '\0' && p[1] == ':') {
        p += 2;
    }
    while (is_separator(*p))
        ++p;

    for (; *p != '\0'; ++p) {
        if (is_separator(*p)) {
            char separator = *p;
            *p = '\0';
            result = make_one_dir(buffer);
            *p = separator;
            if (result == 2) {
                free(buffer);
                return 2;
            }
            while (is_separator(p[1]))
                ++p;
        }
    }

    result = make_one_dir(buffer);
    free(buffer);
    return result == 2 ? 2 : 0;
}

char* os_getcwd(void) {
    char *buffer = NULL;
    DWORD size = 256;

    while (1) {
        // Use realloc to resize the buffer
        buffer = (char*)realloc(buffer, size);
        if (buffer == NULL) {
            return NULL; // Allocation failed
        }

        // Use GetCurrentDirectory for Windows
        DWORD result = GetCurrentDirectoryA(size, buffer);
        if (result != 0 && result < size) {
            return buffer; // Successfully got the current directory
        } else if (result > size) {
            size = result; // Buffer was too small, resize based on the result
        } else {
            free(buffer);  // Some error occurred, free memory and return NULL
            return NULL;
        }
    }
}

int os_setcwd(const char* path) {
    if (path == NULL || path[0] == '\0')
        return -1;

    return SetCurrentDirectoryA(path) ? 0 : -1;
}

// Return directory only for real directories. Reparse points remain leaf objects
// so recursive rm does not traverse junctions or directory symlinks.
int os_path_type(const char* path) {
    DWORD attributes;

    if (path == NULL || path[0] == '\0')
        return 0;
    attributes = GetFileAttributesA(path);
    if (attributes == INVALID_FILE_ATTRIBUTES)
        return 0;
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0)
        return 2;
    return 1;
}

// Remove one empty directory. Recursive traversal is implemented in shell.lua.
int os_remove_dir(const char* path) {
    return RemoveDirectoryA(path) ? 0 : -1;
}

// Remove a leaf object. Directory reparse points require RemoveDirectoryA().
int os_remove_file(const char* path) {
    DWORD attributes = GetFileAttributesA(path);

    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
        return RemoveDirectoryA(path) ? 0 : -1;
    return DeleteFileA(path) ? 0 : -1;
}

// Update access/modification time and create a missing regular file. Directories
// require FILE_FLAG_BACKUP_SEMANTICS to obtain an attribute-write handle.
int os_touch(const char* path) {
    DWORD attributes;
    DWORD flags = 0;
    DWORD creation = OPEN_EXISTING;
    HANDLE file;
    FILETIME now;
    BOOL result;

    if (path == NULL || path[0] == '\0')
        return -1;

    attributes = GetFileAttributesA(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        creation = OPEN_ALWAYS;
        flags = FILE_ATTRIBUTE_NORMAL;
    } else if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        flags = FILE_FLAG_BACKUP_SEMANTICS;
    }

    file = CreateFileA(
        path,
        FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        creation,
        flags,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE)
        return -1;

    GetSystemTimeAsFileTime(&now);
    result = SetFileTime(file, NULL, &now, &now);
    CloseHandle(file);
    return result ? 0 : -1;
}

// Enumerate a directory for the existing Lua directory-cache bridge. Convert
// FILETIME to Unix seconds and report each child's directory attribute.
int os_get_dir(BLUD_DIR_CALLBACK callback, void* data, const char* dir) {
    WIN32_FIND_DATAA entry;
    HANDLE find;
    char* pattern;
    size_t len;
    int result = -1;

    if (dir == NULL || dir[0] == '\0')
        return -1;

    len = strlen(dir);
    pattern = (char*)malloc(len + 3);
    if (pattern == NULL)
        return -1;
    memcpy(pattern, dir, len);
    if (len > 0 && !is_separator(pattern[len - 1]))
        pattern[len++] = '\\';
    pattern[len++] = '*';
    pattern[len] = '\0';

    find = FindFirstFileA(pattern, &entry);
    free(pattern);
    if (find == INVALID_HANDLE_VALUE)
        return -1;

    do {
        const char* name = entry.cFileName;
        ULARGE_INTEGER time;
        int64_t seconds;
        int is_dir;

        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;

        time.LowPart = entry.ftLastWriteTime.dwLowDateTime;
        time.HighPart = entry.ftLastWriteTime.dwHighDateTime;
        seconds = (int64_t)((time.QuadPart - 116444736000000000ULL) /
                            10000000ULL);
        is_dir = (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        callback(data, name, seconds, is_dir);
    } while (FindNextFileA(find, &entry));

    if (GetLastError() == ERROR_NO_MORE_FILES)
        result = 0;
    FindClose(find);
    return result;
}
