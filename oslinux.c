#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <dirent.h>
#include "os.h"

#include <unistd.h>  // For getcwd()
#include <stdlib.h>  // For malloc() and free()

char* get_cwd() {
    char *buffer;
    size_t size = 256;

    while (1) {
        buffer = (char*)malloc(size);
        if (buffer == NULL) {
            return NULL; // Allocation failed
        }

        // Use getcwd for Unix-like systems (Linux, macOS, etc.)
        if (getcwd(buffer, size) != NULL) {
            return buffer;
        }

        free(buffer); // Free the buffer if it was too small
        size *= 2;    // Double the buffer size and try again
    }
}


int os_get_dir(BLUD_DIR_CALLBACK callback, void* data,const char* dir){
    DIR*            dp;
    struct dirent*  entry;
    struct stat     statbuf;
    const  char*    name;
    char*           path = (char*)malloc(PATH_MAX+1);
    int             result = -1;

    if(path == NULL)
        perror("malloc");
    else if ((dp = opendir(dir)) == NULL)
        perror("opendir");
    else {
        while ((entry = readdir(dp)) != NULL) { // for each directory entry
            name = entry->d_name;
            if(name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0')))
                continue;
            if(snprintf(path, PATH_MAX, "%s/%s", dir, name) >= PATH_MAX){
                perror("snprintf");
                break;
            }
            if (stat(path, &statbuf) == -1) {
                perror("stat");
                break;
            }
            int64_t mod_time    = (int64_t)statbuf.st_mtime;
            int     is_dir      = S_ISDIR(statbuf.st_mode);
            callback(data, name, mod_time, is_dir);
        }
        closedir(dp);
        if(entry == NULL)
            result = 0;
    }

    return result;
}

