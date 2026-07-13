#include "os.h"

#include <windows.h>  // For GetCurrentDirectory()
#include <stdlib.h>    // For malloc(), realloc(), and free()

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
