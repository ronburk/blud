#include "os.h"

#include <assert.h>
#include <limits.h>
#include <stdio.h>     // For fprintf()
#include <windows.h>
#include <stdlib.h>    // For malloc(), realloc(), and free()
#include <string.h>
#include <wchar.h>

// Windows APIs accept both separators; recognizing both preserves portable paths.
static int is_separator(char c) {
    return c == '/' || c == '\\';
}

static int is_wide_separator(wchar_t c) {
    return c == L'/' || c == L'\\';
}

// Paths crossing os.h are UTF-8; Windows filesystem APIs receive UTF-16.
static wchar_t* utf8_to_utf16(const char* text) {
    wchar_t* result;
    int length;

    if (text == NULL) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return NULL;
    }
    length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                 text, -1, NULL, 0);
    if (length == 0)
        return NULL;
    result = (wchar_t*)malloc((size_t)length * sizeof *result);
    if (result == NULL) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                            text, -1, result, length) == 0) {
        DWORD error = GetLastError();

        free(result);
        SetLastError(error);
        return NULL;
    }
    return result;
}

static char* utf16_to_utf8(const wchar_t* text) {
    char* result;
    int length;

    if (text == NULL) {
        SetLastError(ERROR_INVALID_PARAMETER);
        return NULL;
    }
    length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                 text, -1, NULL, 0, NULL, NULL);
    if (length == 0)
        return NULL;
    result = (char*)malloc((size_t)length);
    if (result == NULL) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            text, -1, result, length, NULL, NULL) == 0) {
        DWORD error = GetLastError();

        free(result);
        SetLastError(error);
        return NULL;
    }
    return result;
}

static DWORD get_file_attributes(const char* path) {
    wchar_t* wide_path = utf8_to_utf16(path);
    DWORD result;
    DWORD error;

    if (wide_path == NULL)
        return INVALID_FILE_ATTRIBUTES;
    result = GetFileAttributesW(wide_path);
    error = GetLastError();
    free(wide_path);
    SetLastError(error);
    return result;
}

static BOOL create_directory(const char* path) {
    wchar_t* wide_path = utf8_to_utf16(path);
    BOOL result;
    DWORD error;

    if (wide_path == NULL)
        return FALSE;
    result = CreateDirectoryW(wide_path, NULL);
    error = GetLastError();
    free(wide_path);
    SetLastError(error);
    return result;
}

static BOOL copy_file(const char* from, const char* to) {
    wchar_t* wide_from = utf8_to_utf16(from);
    wchar_t* wide_to;
    BOOL result;
    DWORD error;

    if (wide_from == NULL)
        return FALSE;
    wide_to = utf8_to_utf16(to);
    if (wide_to == NULL) {
        error = GetLastError();
        free(wide_from);
        SetLastError(error);
        return FALSE;
    }
    result = CopyFileW(wide_from, wide_to, FALSE);
    error = GetLastError();
    free(wide_to);
    free(wide_from);
    SetLastError(error);
    return result;
}

static BOOL remove_directory(const char* path) {
    wchar_t* wide_path = utf8_to_utf16(path);
    BOOL result;
    DWORD error;

    if (wide_path == NULL)
        return FALSE;
    result = RemoveDirectoryW(wide_path);
    error = GetLastError();
    free(wide_path);
    SetLastError(error);
    return result;
}

static BOOL delete_file(const char* path) {
    wchar_t* wide_path = utf8_to_utf16(path);
    BOOL result;
    DWORD error;

    if (wide_path == NULL)
        return FALSE;
    result = DeleteFileW(wide_path);
    error = GetLastError();
    free(wide_path);
    SetLastError(error);
    return result;
}

char* os_get_executable_path(void) {
    wchar_t* wide_path = NULL;
    DWORD capacity = 256;

    while (1) {
        wchar_t* resized = (wchar_t*)realloc(
            wide_path,
            (size_t)capacity * sizeof *wide_path
        );
        DWORD length;

        if (resized == NULL) {
            free(wide_path);
            return NULL;
        }
        wide_path = resized;
        length = GetModuleFileNameW(NULL, wide_path, capacity);
        if (length == 0) {
            free(wide_path);
            return NULL;
        }
        if (length < capacity) {
            char* path = utf16_to_utf8(wide_path);
            free(wide_path);
            return path;
        }
        if (capacity > MAXDWORD / 2) {
            free(wide_path);
            return NULL;
        }
        capacity *= 2;
    }
}

// Test for an existing directory when distinguishing collision from failure.
static int dir_exists(const char* path) {
    DWORD attributes = get_file_attributes(path);

    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

// Normalize CreateDirectoryW() to the shared 0-created, 1-existed, 2-error contract.
static int make_one_dir(const char* path) {
    if (create_directory(path))
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
    if (value.QuadPart < 116444736000000000ULL) {
        fprintf(stderr, "Windows file timestamp predates the Unix epoch\n");
        abort();
    }
    value.QuadPart -= 116444736000000000ULL;
    timestamp->seconds = (int64_t)(value.QuadPart / 10000000ULL);
    timestamp->nanoseconds = (int32_t)(value.QuadPart % 10000000ULL) * 100;
    return 0;
}

static int timestamp_to_filetime(
    FILETIME* file_time,
    const BLUD_TIMESTAMP* timestamp
) {
    ULARGE_INTEGER value;

    if (timestamp->seconds < 0)
        return -1;
    value.QuadPart = (uint64_t)timestamp->seconds * 10000000ULL +
                     116444736000000000ULL +
                     (uint64_t)timestamp->nanoseconds / 100;
    file_time->dwLowDateTime = value.LowPart;
    file_time->dwHighDateTime = value.HighPart;
    return 0;
}

int os_get_system_timestamp(BLUD_TIMESTAMP* timestamp) {
    FILETIME now;

    assert(timestamp != NULL);
    GetSystemTimeAsFileTime(&now);
    return filetime_to_timestamp(timestamp, now);
}

int os_timestamp_to_fields(
    const BLUD_TIMESTAMP* timestamp,
    BLUD_TIMESTAMP_FIELDS* fields,
    int utc
) {
    FILETIME file_time;
    SYSTEMTIME system_time;
    SYSTEMTIME local_time;
    ULARGE_INTEGER value;

    assert(timestamp != NULL);
    assert(fields != NULL);
    value.QuadPart = (uint64_t)timestamp->seconds * 10000000ULL +
                     116444736000000000ULL;
    value.QuadPart += (uint64_t)timestamp->nanoseconds / 100;
    file_time.dwLowDateTime = value.LowPart;
    file_time.dwHighDateTime = value.HighPart;
    if (!FileTimeToSystemTime(&file_time, &system_time))
        return -1;
    if (utc) {
        local_time = system_time;
    } else if (!SystemTimeToTzSpecificLocalTime(NULL, &system_time, &local_time)) {
        return -1;
    }
    fields->year = local_time.wYear;
    fields->month = local_time.wMonth;
    fields->day = local_time.wDay;
    fields->hour = local_time.wHour;
    fields->minute = local_time.wMinute;
    fields->second = local_time.wSecond;
    fields->nanosecond = timestamp->nanoseconds;
    return 0;
}

int os_fields_to_timestamp(
    const BLUD_TIMESTAMP_FIELDS* fields,
    BLUD_TIMESTAMP* timestamp,
    int utc
) {
    SYSTEMTIME input;
    SYSTEMTIME universal;
    FILETIME file_time;
    ULARGE_INTEGER value;

    assert(fields != NULL);
    assert(timestamp != NULL);
    input.wYear = (WORD)fields->year;
    input.wMonth = (WORD)fields->month;
    input.wDay = (WORD)fields->day;
    input.wHour = (WORD)fields->hour;
    input.wMinute = (WORD)fields->minute;
    input.wSecond = (WORD)fields->second;
    input.wMilliseconds = (WORD)(fields->nanosecond / 1000000);
    input.wDayOfWeek = 0;
    if (utc) {
        universal = input;
    } else if (!TzSpecificLocalTimeToSystemTime(NULL, &input, &universal)) {
        return -1;
    }
    if (!SystemTimeToFileTime(&universal, &file_time))
        return -1;
    value.LowPart = file_time.dwLowDateTime;
    value.HighPart = file_time.dwHighDateTime;
    if (value.QuadPart < 116444736000000000ULL)
        return -1;
    value.QuadPart -= 116444736000000000ULL;
    timestamp->seconds = (int64_t)(value.QuadPart / 10000000ULL);
    timestamp->nanoseconds = fields->nanosecond;
    return 0;
}

// Create only path; recursive creation is handled by the Lua binding.
int os_mkdir(const char* path) {
    if (path == NULL || path[0] == '\0')
        return 2;
    return make_one_dir(path);
}

char* os_getcwd(void) {
    wchar_t* wide_path = NULL;
    DWORD capacity = 256;

    while (1) {
        wchar_t* resized = (wchar_t*)realloc(
            wide_path,
            (size_t)capacity * sizeof *wide_path
        );
        DWORD length;

        if (resized == NULL) {
            free(wide_path);
            return NULL;
        }
        wide_path = resized;
        length = GetCurrentDirectoryW(capacity, wide_path);
        if (length == 0) {
            free(wide_path);
            return NULL;
        }
        if (length < capacity) {
            char* path = utf16_to_utf8(wide_path);
            free(wide_path);
            return path;
        }
        capacity = length;
    }
}

int os_setcwd(const char* path) {
    wchar_t* wide_path;
    BOOL result;

    if (path == NULL || path[0] == '\0')
        return -1;
    wide_path = utf8_to_utf16(path);
    if (wide_path == NULL)
        return -1;
    result = SetCurrentDirectoryW(wide_path);
    free(wide_path);
    return result ? 0 : -1;
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

    attributes = get_file_attributes(to);
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
    result = copy_file(from, destination) ? 0 : -1;
    free(destination);
    return result;
}

static int copy_directory_tree(const char* from, const char* to) {
    WIN32_FIND_DATAW entry;
    HANDLE find;
    char* pattern;
    wchar_t* wide_pattern;
    int created = 0;
    int result = -1;

    if (create_directory(to)) {
        created = 1;
    } else if (GetLastError() != ERROR_ALREADY_EXISTS || !dir_exists(to)) {
        return -1;
    }

    pattern = join_path(from, "*", 1);
    if (pattern == NULL)
        goto done;
    wide_pattern = utf8_to_utf16(pattern);
    free(pattern);
    if (wide_pattern == NULL)
        goto done;
    find = FindFirstFileW(wide_pattern, &entry);
    free(wide_pattern);
    if (find == INVALID_HANDLE_VALUE)
        goto done;
    result = 0;

    do {
        char* name;
        char* from_child;
        char* to_child;

        if (wcscmp(entry.cFileName, L".") == 0 ||
            wcscmp(entry.cFileName, L"..") == 0)
            continue;
        name = utf16_to_utf8(entry.cFileName);
        if (name == NULL) {
            result = -1;
            break;
        }

        from_child = join_path(from, name, strlen(name));
        to_child = join_path(to, name, strlen(name));
        free(name);
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
            result = copy_file(from_child, to_child) ? 0 : -1;
        }

        free(from_child);
        free(to_child);
        if (result != 0)
            break;
    } while (FindNextFileW(find, &entry));

    if (result == 0 && GetLastError() != ERROR_NO_MORE_FILES)
        result = -1;
    FindClose(find);

done:
    if (created && result != 0)
        remove_directory(to);
    return result;
}

static wchar_t* full_path(const char* path) {
    wchar_t* wide_path = utf8_to_utf16(path);
    wchar_t* result = NULL;
    DWORD capacity;

    if (wide_path == NULL)
        return NULL;
    capacity = GetFullPathNameW(wide_path, 0, NULL, NULL);
    if (capacity == 0) {
        free(wide_path);
        return NULL;
    }
    while (1) {
        wchar_t* resized = (wchar_t*)realloc(
            result,
            (size_t)capacity * sizeof *result
        );
        DWORD length;

        if (resized == NULL) {
            free(result);
            free(wide_path);
            return NULL;
        }
        result = resized;
        length = GetFullPathNameW(wide_path, capacity, result, NULL);
        if (length == 0) {
            free(result);
            free(wide_path);
            return NULL;
        }
        if (length < capacity) {
            free(wide_path);
            return result;
        }
        capacity = length;
    }
}

static int same_or_child_path(const wchar_t* parent, const wchar_t* path) {
    size_t parent_len = wcslen(parent);
    size_t path_len = wcslen(path);

    while (parent_len > 0 && is_wide_separator(parent[parent_len - 1]) &&
           !(parent_len == 3 && parent[1] == L':'))
        --parent_len;
    if (parent_len > INT_MAX || path_len < parent_len ||
        CompareStringOrdinal(parent, (int)parent_len,
                             path, (int)parent_len, TRUE) != CSTR_EQUAL)
        return 0;
    if (parent_len == 3 && parent[1] == L':' &&
        is_wide_separator(parent[2]))
        return 1;
    return path[parent_len] == L'\0' || is_wide_separator(path[parent_len]);
}

int os_copy_dir(const char* from, const char* to) {
    DWORD attributes;
    char* destination;
    wchar_t* canonical_from;
    wchar_t* canonical_to;
    int result;

    if (from == NULL || from[0] == '\0')
        return -1;
    attributes = get_file_attributes(from);
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
    attributes = get_file_attributes(path);
    if (attributes == INVALID_FILE_ATTRIBUTES)
        return 0;
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0)
        return 2;
    return 1;
}

// Remove one empty directory. Recursive traversal is implemented in shell.lua.
int os_remove_dir(const char* path) {
    return remove_directory(path) ? 0 : -1;
}

// Remove a leaf object. Directory reparse points require RemoveDirectoryW().
int os_remove_file(const char* path) {
    DWORD attributes = get_file_attributes(path);

    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
        return remove_directory(path) ? 0 : -1;
    return delete_file(path) ? 0 : -1;
}

// Update access/modification time and create a missing regular file. Directories
// require FILE_FLAG_BACKUP_SEMANTICS to obtain an attribute-write handle.
int os_touch(const char* path, const BLUD_TIMESTAMP* timestamp) {
    DWORD attributes;
    DWORD flags = 0;
    DWORD creation = OPEN_EXISTING;
    HANDLE file;
    FILETIME file_time;
    BOOL result;
    wchar_t* wide_path;

    if (path == NULL || path[0] == '\0')
        return -1;

    wide_path = utf8_to_utf16(path);
    if (wide_path == NULL)
        return -1;
    attributes = GetFileAttributesW(wide_path);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        creation = OPEN_ALWAYS;
        flags = FILE_ATTRIBUTE_NORMAL;
    } else if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        flags = FILE_FLAG_BACKUP_SEMANTICS;
    }

    file = CreateFileW(
        wide_path,
        FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        creation,
        flags,
        NULL
    );
    free(wide_path);
    if (file == INVALID_HANDLE_VALUE)
        return -1;

    if (timestamp == NULL)
        GetSystemTimeAsFileTime(&file_time);
    else if (timestamp_to_filetime(&file_time, timestamp) != 0) {
        CloseHandle(file);
        return -1;
    }
    result = SetFileTime(file, NULL, &file_time, &file_time);
    CloseHandle(file);
    return result ? 0 : -1;
}

// Enumerate a directory for the existing Lua directory-cache bridge. Convert
// FILETIME to Unix seconds and report each child's directory attribute.
int os_get_dir(BLUD_DIR_CALLBACK callback, void* data, const char* dir) {
    WIN32_FIND_DATAW entry;
    HANDLE find;
    char* pattern;
    wchar_t* wide_pattern;
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

    wide_pattern = utf8_to_utf16(pattern);
    free(pattern);
    if (wide_pattern == NULL)
        return -1;
    find = FindFirstFileW(wide_pattern, &entry);
    free(wide_pattern);
    if (find == INVALID_HANDLE_VALUE)
        return -1;
    result = 0;

    do {
        char* name;
        BLUD_TIMESTAMP timestamp;
        int is_dir;

        if (wcscmp(entry.cFileName, L".") == 0 ||
            wcscmp(entry.cFileName, L"..") == 0)
            continue;
        name = utf16_to_utf8(entry.cFileName);
        if (name == NULL) {
            result = -1;
            break;
        }

        filetime_to_timestamp(&timestamp, entry.ftLastWriteTime);
        is_dir = (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        callback(data, name, &timestamp, is_dir);
        free(name);
    } while (FindNextFileW(find, &entry));

    if (result == 0 && GetLastError() != ERROR_NO_MORE_FILES)
        result = -1;
    FindClose(find);
    return result;
}
