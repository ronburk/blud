#include "os.h"

#include <windows.h>  // For GetCurrentDirectory()
#include <stdlib.h>    // For malloc(), realloc(), and free()

char* get_cwd() {
    char *buffer = NULL;
    DWORD size = 256;

    while (1) {
        // Use realloc to resize the buffer
        buffer = (char*)realloc(buffer, size);
        if (buffer == NULL) {
            return NULL; // Allocation failed
        }

        // Use GetCurrentDirectory for Windows
        DWORD result = GetCurrentDirectory(size, buffer);
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
