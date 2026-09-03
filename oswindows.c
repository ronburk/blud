#include "os.h"

#include <assert.h>
#include <windows.h>  // For GetCurrentDirectory()
#include <stdlib.h>    // For malloc(), realloc(), and free()
#include <string.h>

// Windows APIs accept both separators; recognizing both preserves portable paths.
static int is_separator(char c) {
    return c == '/' || c == '\\';
}

char* os_get_executable_path(void) {
    return _strdup(_pgmptr);
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

static int filetime_to_timestamp(
    BLUD_TIMESTAMP* timestamp,
    FILETIME file_time
) {
    ULARGE_INTEGER value;

    value.LowPart = file_time.dwLowDateTime;
    value.HighPart = file_time.dwHighDateTime;
    if (value.QuadPart < 116444736000000000ULL)
        return -1;
    value.QuadPart -= 116444736000000000ULL;
    timestamp->seconds = (int64_t)(value.QuadPart / 10000000ULL);
    timestamp->nanoseconds = (uint32_t)(value.QuadPart % 10000000ULL) * 100;
    return 0;
}

int os_get_system_timestamp(BLUD_TIMESTAMP* timestamp) {
    FILETIME now;

    assert(timestamp != NULL);
    GetSystemTimeAsFileTime(&now);
    return filetime_to_timestamp(timestamp, now);
}

int os_get_path_timestamp(BLUD_TIMESTAMP* timestamp, const char* path) {
    WIN32_FILE_ATTRIBUTE_DATA attributes;

    assert(timestamp != NULL);
    if (!GetFileAttributesExA(path, GetFileExInfoStandard, &attributes))
        return -1;
    return filetime_to_timestamp(timestamp, attributes.ftLastWriteTime);
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

static char* join_path(const char* parent, const char* child,
                       size_t child_len) {
    size_t parent_len = strlen(parent);
    int add_separator = parent_len != 0 &&
                        !is_separator(parent[parent_len - 1]);
    char* result = (char*)malloc(parent_len + add_separator + child_len + 1);

    if (result == NULL)
        return NULL;

    memcpy(result, parent, parent_len);
    if (add_separator)
        result[parent_len++] = '\\';
    memcpy(result + parent_len, child, child_len);
    result[parent_len + child_len] = '\0';
    return result;
}

static char* duplicate_path(const char* path) {
    size_t len = strlen(path);
    char* result = (char*)malloc(len + 1);

    if (result != NULL)
        memcpy(result, path, len + 1);
    return result;
}

static char* append_final_name(const char* parent, const char* path) {
    size_t end = strlen(path);
    size_t start;

    while (end != 0 && is_separator(path[end - 1]))
        --end;
    if (end == 0 || (end == 2 && path[1] == ':'))
        return NULL;

    start = end;
    while (start != 0 && !is_separator(path[start - 1]))
        --start;
    return join_path(parent, path + start, end - start);
}

// Interpret an existing directory destination the way cp does.
static char* copy_destination(const char* from, const char* to) {
    DWORD attributes;
    DWORD error;

    if (from == NULL || from[0] == '\0' || to == NULL || to[0] == '\0')
        return NULL;

    attributes = GetFileAttributesA(to);
    if (attributes != INVALID_FILE_ATTRIBUTES) {
        if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
            return append_final_name(to, from);
        return duplicate_path(to);
    }

    error = GetLastError();
    if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
        return NULL;
    if (is_separator(to[strlen(to) - 1]))
        return NULL;
    return duplicate_path(to);
}

int os_copy_file(const char* from, const char* to) {
    char* destination = copy_destination(from, to);
    int result;

    if (destination == NULL)
        return -1;
    result = CopyFileA(from, destination, FALSE) ? 0 : -1;
    free(destination);
    return result;
}

static int copy_directory_tree(const char* from, const char* to) {
    WIN32_FIND_DATAA entry;
    HANDLE find;
    char* pattern;
    int created = 0;
    int result = -1;

    if (CreateDirectoryA(to, NULL)) {
        created = 1;
    } else if (GetLastError() != ERROR_ALREADY_EXISTS || !dir_exists(to)) {
        return -1;
    }

    pattern = join_path(from, "*", 1);
    if (pattern == NULL)
        goto done;
    find = FindFirstFileA(pattern, &entry);
    free(pattern);
    if (find == INVALID_HANDLE_VALUE)
        goto done;
    result = 0;

    do {
        const char* name = entry.cFileName;
        char* from_child;
        char* to_child;

        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;

        from_child = join_path(from, name, strlen(name));
        to_child = join_path(to, name, strlen(name));
        if (from_child == NULL || to_child == NULL) {
            free(from_child);
            free(to_child);
            result = -1;
            break;
        }

        if ((entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            result = -1;
        } else if ((entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            result = copy_directory_tree(from_child, to_child);
        } else {
            result = CopyFileA(from_child, to_child, FALSE) ? 0 : -1;
        }

        free(from_child);
        free(to_child);
        if (result != 0)
            break;
    } while (FindNextFileA(find, &entry));

    if (result == 0 && GetLastError() != ERROR_NO_MORE_FILES)
        result = -1;
    FindClose(find);

done:
    if (created && result != 0)
        RemoveDirectoryA(to);
    return result;
}

static char* full_path(const char* path) {
    DWORD size = GetFullPathNameA(path, 0, NULL, NULL);
    char* result;

    if (size == 0)
        return NULL;
    result = (char*)malloc(size);
    if (result == NULL)
        return NULL;
    if (GetFullPathNameA(path, size, result, NULL) == 0) {
        free(result);
        return NULL;
    }
    return result;
}

static int same_or_child_path(const char* parent, const char* path) {
    size_t parent_len = strlen(parent);

    while (parent_len > 0 && is_separator(parent[parent_len - 1]) &&
           !(parent_len == 3 && parent[1] == ':'))
        --parent_len;
    if (_strnicmp(parent, path, parent_len) != 0)
        return 0;
    if (parent_len == 3 && parent[1] == ':' &&
        is_separator(parent[2]))
        return 1;
    return path[parent_len] == '\0' || is_separator(path[parent_len]);
}

int os_copy_dir(const char* from, const char* to) {
    DWORD attributes;
    char* destination;
    char* canonical_from;
    char* canonical_to;
    int result;

    if (from == NULL || from[0] == '\0')
        return -1;
    attributes = GetFileAttributesA(from);
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        return -1;

    destination = copy_destination(from, to);
    if (destination == NULL)
        return -1;
    canonical_from = full_path(from);
    canonical_to = full_path(destination);
    if (canonical_from == NULL || canonical_to == NULL ||
        same_or_child_path(canonical_from, canonical_to)) {
        free(canonical_to);
        free(canonical_from);
        free(destination);
        return -1;
    }

    free(canonical_to);
    free(canonical_from);
    result = copy_directory_tree(from, destination);
    free(destination);
    return result;
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
        BLUD_TIMESTAMP timestamp;
        int is_dir;

        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;

        if (filetime_to_timestamp(&timestamp, entry.ftLastWriteTime) != 0)
            continue;
        is_dir = (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        callback(data, name, &timestamp, is_dir);
    } while (FindNextFileA(find, &entry));

    if (GetLastError() == ERROR_NO_MORE_FILES)
        result = 0;
    FindClose(find);
    return result;
}
