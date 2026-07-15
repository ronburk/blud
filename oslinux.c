#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <utime.h>
#include "os.h"

#include <unistd.h>  // For getcwd()


// Test for an existing directory when distinguishing EEXIST from failure.
static int dir_exists(const char* path) {
    struct stat statbuf;

    return stat(path, &statbuf) == 0 && S_ISDIR(statbuf.st_mode);
}

// Normalize mkdir(2) to the shared 0-created, 1-existed, 2-error contract.
static int make_one_dir(const char* path) {
    if (mkdir(path, 0777) == 0)
        return 0;
    if (errno == EEXIST && dir_exists(path))
        return 1;
    return 2;
}

// Create only path; unlike os_mkdir(), do not synthesize parent directories.
int os_mkdir_one(const char* path) {
    if (path == NULL || path[0] == '\0')
        return 2;
    return make_one_dir(path);
}

int os_mkdir(const char* path) {
    size_t      len;
    char*       buffer;
    char*       p;
    int         result;

    if (path == NULL || path[0] == '\0')
        return 2;

    if (dir_exists(path))
        return 1;

    len     = strlen(path);
    buffer  = (char*)malloc(len + 1);
    if (buffer == NULL)
        return 2;
    memcpy(buffer, path, len + 1);

    while (len > 1 && buffer[len - 1] == '/')
        buffer[--len] = '\0';

    p = buffer;
    while (*p == '/')
        ++p;

    for (; *p != '\0'; ++p) {
        if (*p == '/') {
            *p = '\0';
            if (buffer[0] != '\0') {
                result = make_one_dir(buffer);
                if (result == 2) {
                    free(buffer);
                    return 2;
                }
            }
            *p = '/';
            while (p[1] == '/')
                ++p;
        }
    }

    result = make_one_dir(buffer);
    free(buffer);

    return result == 2 ? 2 : 0;
}

char* os_getcwd(void) {
    char*   buffer;
    size_t  size = 256;

    while (1) {
        buffer = (char*)malloc(size);
        if (buffer == NULL)
            return NULL;

        if (getcwd(buffer, size) != NULL)
            return buffer;

        free(buffer);
        if (errno != ERANGE)
            return NULL;

        size *= 2;
    }
}

int os_setcwd(const char* path) {
    if (path == NULL || path[0] == '\0')
        return -1;

    return chdir(path) == 0 ? 0 : -1;
}

// Classify without following a symlink, preventing recursive rm from crossing it.
int os_path_type(const char* path) {
    struct stat statbuf;

    if (path == NULL || path[0] == '\0' || lstat(path, &statbuf) != 0)
        return 0;
    return S_ISDIR(statbuf.st_mode) ? 2 : 1;
}

// Remove one empty directory. Recursive traversal is implemented in shell.lua.
int os_remove_dir(const char* path) {
    return rmdir(path) == 0 ? 0 : -1;
}

// Remove a file or symlink without treating its target as a directory.
int os_remove_file(const char* path) {
    return unlink(path) == 0 ? 0 : -1;
}

// Set access/modification time to now, creating a regular file only when absent.
int os_touch(const char* path) {
    int fd;

    if (path == NULL || path[0] == '\0')
        return -1;
    if (utime(path, NULL) == 0)
        return 0;
    if (errno != ENOENT)
        return -1;

    fd = open(path, O_WRONLY | O_CREAT, 0666);
    if (fd < 0)
        return -1;
    return close(fd) == 0 ? 0 : -1;
}

int os_get_dir(BLUD_DIR_CALLBACK callback, void* data,const char* dir){
    DIR*            dp;
    struct dirent*  entry;
    struct stat     statbuf;
    const  char*    name;
    int             result = -1;

    if ((dp = opendir(dir)) == NULL) {
        fprintf(stderr, "os_get_dir: opendir failed\n");
        fprintf(stderr, "    dir: %s\n", dir);
        perror("    opendir");
    }
    else {
        while ((entry = readdir(dp)) != NULL) { // for each directory entry
            name = entry->d_name;
            if(name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0')))
                continue;
            if (fstatat(dirfd(dp), name, &statbuf, 0) == -1) {
                fprintf(stderr, "os_get_dir: fstatat failed\n");
                fprintf(stderr, "    dir:  %s\n", dir);
                fprintf(stderr, "    name: %s\n", name);
                perror("    fstatat");
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

