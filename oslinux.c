#define _XOPEN_SOURCE 700

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

static char* join_path(const char* parent, const char* child, size_t child_len) {
    size_t parent_len = strlen(parent);
    int add_slash = parent_len != 0 && parent[parent_len - 1] != '/';
    char* result = (char*)malloc(parent_len + add_slash + child_len + 1);

    if (result == NULL)
        return NULL;

    memcpy(result, parent, parent_len);
    if (add_slash)
        result[parent_len++] = '/';
    memcpy(result + parent_len, child, child_len);
    result[parent_len + child_len] = '\0';

    return result;
}

static char* append_final_name(const char* parent, const char* path) {
    size_t end = strlen(path);
    size_t start;

    while (end != 0 && path[end - 1] == '/')
        --end;
    if (end == 0) {
        errno = EINVAL;
        return NULL;
    }

    start = end;
    while (start != 0 && path[start - 1] != '/')
        --start;

    return join_path(parent, path + start, end - start);
}

// Interpret an existing directory destination the way cp does.
static char* copy_destination(const char* from, const char* to) {
    struct stat statbuf;

    if (from == NULL || from[0] == '\0' || to == NULL || to[0] == '\0') {
        errno = EINVAL;
        return NULL;
    }

    if (stat(to, &statbuf) == 0) {
        if (S_ISDIR(statbuf.st_mode))
            return append_final_name(to, from);
        return strdup(to);
    }

    if (errno != ENOENT)
        return NULL;
    if (to[strlen(to) - 1] == '/') {
        errno = ENOENT;
        return NULL;
    }

    return strdup(to);
}

static int copy_file_exact(const char* from, const char* to) {
    struct stat from_stat;
    struct stat to_stat;
    char buffer[64 * 1024];
    int from_fd = -1;
    int to_fd = -1;
    int created = 0;
    int result = -1;
    int saved_errno;

    from_fd = open(from, O_RDONLY);
    if (from_fd == -1)
        return -1;
    if (fstat(from_fd, &from_stat) == -1)
        goto done;
    if (!S_ISREG(from_stat.st_mode)) {
        errno = EINVAL;
        goto done;
    }

    if (stat(to, &to_stat) == 0) {
        if (!S_ISREG(to_stat.st_mode)) {
            errno = EINVAL;
            goto done;
        }
        if (from_stat.st_dev == to_stat.st_dev &&
            from_stat.st_ino == to_stat.st_ino) {
            errno = EINVAL;
            goto done;
        }
        to_fd = open(to, O_WRONLY | O_TRUNC);
    } else {
        if (errno != ENOENT)
            goto done;
        to_fd = open(to, O_WRONLY | O_CREAT | O_EXCL,
                     from_stat.st_mode & 0777);
        created = to_fd != -1;
    }
    if (to_fd == -1)
        goto done;

    for (;;) {
        ssize_t count;
        ssize_t written = 0;

        do {
            count = read(from_fd, buffer, sizeof(buffer));
        } while (count == -1 && errno == EINTR);

        if (count == 0)
            break;
        if (count == -1)
            goto done;

        while (written < count) {
            ssize_t amount;

            do {
                amount = write(to_fd, buffer + written,
                               (size_t)(count - written));
            } while (amount == -1 && errno == EINTR);

            if (amount == -1)
                goto done;
            if (amount == 0) {
                errno = EIO;
                goto done;
            }
            written += amount;
        }
    }

    if (close(to_fd) == -1) {
        to_fd = -1;
        goto done;
    }
    to_fd = -1;
    result = 0;

done:
    saved_errno = errno;
    if (to_fd != -1 && close(to_fd) == -1 && result == 0) {
        saved_errno = errno;
        result = -1;
    }
    if (from_fd != -1)
        close(from_fd);
    if (created && result != 0)
        unlink(to);
    errno = saved_errno;

    return result;
}

int os_copy_file(const char* from, const char* to) {
    char* destination = copy_destination(from, to);
    int result;
    int saved_errno;

    if (destination == NULL)
        return -1;

    result = copy_file_exact(from, destination);
    saved_errno = errno;
    free(destination);
    errno = saved_errno;

    return result;
}

static int copy_dir_exact(const char* from, const char* to) {
    struct stat from_stat;
    struct stat to_stat;
    DIR* directory = NULL;
    struct dirent* entry;
    int created = 0;
    int result = -1;
    int saved_errno;

    if (stat(from, &from_stat) == -1)
        return -1;
    if (!S_ISDIR(from_stat.st_mode)) {
        errno = ENOTDIR;
        return -1;
    }

    if (stat(to, &to_stat) == 0) {
        if (!S_ISDIR(to_stat.st_mode)) {
            errno = ENOTDIR;
            return -1;
        }
    } else {
        if (errno != ENOENT)
            return -1;
        if (mkdir(to, 0700) == -1)
            return -1;
        created = 1;
        if (chmod(to, 0700) == -1)
            return -1;
    }

    directory = opendir(from);
    if (directory == NULL)
        return -1;

    for (;;) {
        char* from_child;
        char* to_child;
        struct stat child_stat;

        errno = 0;
        entry = readdir(directory);
        if (entry == NULL) {
            if (errno == 0)
                result = 0;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0)
            continue;

        from_child = join_path(from, entry->d_name, strlen(entry->d_name));
        to_child = join_path(to, entry->d_name, strlen(entry->d_name));
        if (from_child == NULL || to_child == NULL) {
            free(from_child);
            free(to_child);
            errno = ENOMEM;
            break;
        }

        if (stat(from_child, &child_stat) == -1) {
            free(from_child);
            free(to_child);
            break;
        }

        if (S_ISDIR(child_stat.st_mode))
            result = copy_dir_exact(from_child, to_child);
        else if (S_ISREG(child_stat.st_mode))
            result = copy_file_exact(from_child, to_child);
        else {
            errno = EINVAL;
            result = -1;
        }

        saved_errno = errno;
        free(from_child);
        free(to_child);
        errno = saved_errno;
        if (result != 0)
            break;
    }

    saved_errno = errno;
    if (closedir(directory) == -1 && result == 0) {
        saved_errno = errno;
        result = -1;
    }
    if (created && chmod(to, from_stat.st_mode & 0777) == -1 && result == 0) {
        saved_errno = errno;
        result = -1;
    }
    errno = saved_errno;

    return result;
}

static char* canonical_missing_path(const char* path) {
    const char* slash = strrchr(path, '/');
    const char* name;
    char* parent;
    char* canonical_parent;
    char* result;

    if (slash == NULL) {
        parent = strdup(".");
        name = path;
    } else if (slash == path) {
        parent = strdup("/");
        name = slash + 1;
    } else {
        size_t parent_len = (size_t)(slash - path);

        parent = (char*)malloc(parent_len + 1);
        if (parent != NULL) {
            memcpy(parent, path, parent_len);
            parent[parent_len] = '\0';
        }
        name = slash + 1;
    }

    if (parent == NULL)
        return NULL;
    if (name[0] == '\0') {
        free(parent);
        errno = EINVAL;
        return NULL;
    }

    canonical_parent = realpath(parent, NULL);
    free(parent);
    if (canonical_parent == NULL)
        return NULL;

    result = join_path(canonical_parent, name, strlen(name));
    free(canonical_parent);

    return result;
}

static char* canonical_destination(const char* path) {
    struct stat statbuf;

    if (stat(path, &statbuf) == 0)
        return realpath(path, NULL);
    if (errno != ENOENT)
        return NULL;

    return canonical_missing_path(path);
}

static int same_or_child_path(const char* parent, const char* path) {
    size_t parent_len = strlen(parent);

    if (strcmp(parent, path) == 0)
        return 1;
    if (strcmp(parent, "/") == 0)
        return path[0] == '/';

    return strncmp(parent, path, parent_len) == 0 && path[parent_len] == '/';
}

int os_copy_dir(const char* from, const char* to) {
    char* destination = copy_destination(from, to);
    char* canonical_from;
    char* canonical_to;
    int result;
    int saved_errno;

    if (destination == NULL)
        return -1;

    canonical_from = realpath(from, NULL);
    if (canonical_from == NULL) {
        saved_errno = errno;
        free(destination);
        errno = saved_errno;
        return -1;
    }

    canonical_to = canonical_destination(destination);
    if (canonical_to == NULL) {
        saved_errno = errno;
        free(canonical_from);
        free(destination);
        errno = saved_errno;
        return -1;
    }

    if (same_or_child_path(canonical_from, canonical_to)) {
        free(canonical_to);
        free(canonical_from);
        free(destination);
        errno = EINVAL;
        return -1;
    }

    free(canonical_to);
    free(canonical_from);

    result = copy_dir_exact(from, destination);
    saved_errno = errno;
    free(destination);
    errno = saved_errno;

    return result;
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
    int             error_number = 0;

    dp = opendir(dir);
    if(dp == NULL)
        return -1;

    for(;;) {
        errno = 0;
        entry = readdir(dp);
        if(entry == NULL) {
            if(errno != 0)
                error_number = errno;
            break;
        }

        name = entry->d_name;
        if(strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;

        if(fstatat(dirfd(dp), name, &statbuf, 0) == -1) {
            if(errno == ENOENT)
                continue;
            error_number = errno;
            break;
        }

        {
            int64_t mod_time = (int64_t)statbuf.st_mtime;
            int is_dir = S_ISDIR(statbuf.st_mode);

            callback(data, name, mod_time, is_dir);
        }
    }

    if(closedir(dp) == -1 && error_number == 0)
        error_number = errno;

    if(error_number != 0) {
        errno = error_number;
        return -1;
    }
    return 0;
}
