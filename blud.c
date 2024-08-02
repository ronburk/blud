#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>


#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
    #include <windows.h>
#else
    #include <sys/stat.h>
    #include <time.h>
    #include <errno.h>
    #include <unistd.h>
#endif



static int lua_get_executable_path(lua_State *L) {
    int         result_count = 2;
    size_t      size         = PATH_MAX;
    ssize_t     bytes_read   = 0;
    char*       path;
    const char* error_message = "Failed to get executable path for some reason.";

#ifdef _WIN32
    path            = _strdup(_pgmptr);
    result_count    = 1;
#else
    for(;;){
        path = (char*)malloc(size);
        assert(path != 0);
        bytes_read = readlink("/proc/self/exe", path, size);
        if (bytes_read == -1) // if error
            break;
        else if(bytes_read < (ssize_t)(size)){
            path[bytes_read] = '\0';
            result_count     = 1;
            break;
        } else{
            size *= 2;
            free(path);
        }
    }
#endif

    if(result_count == 2){
        lua_pushnil(L);
        lua_pushstring(L, error_message);
    } else
        lua_pushstring(L, path);
    free(path);
    return result_count;
}



char* get_cwd() {
    char *buffer;
    size_t size = 256;

    while (1) {
        buffer = (char*)malloc(size);
        if (buffer == NULL) {
            return NULL; // Allocation failed
        }

#ifdef _WIN32
        if (GetCurrentDirectory(size, buffer) != 0) {
            return buffer;
        }
#else
        if (getcwd(buffer, size) != NULL) {
            return buffer;
        }
#endif

        free(buffer); // Free the buffer if it was too small
        size *= 2; // Double the buffer size and try again
    }
}

static int lua_get_cwd(lua_State *L) {
    char *cwd = get_cwd();
    if (cwd == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "Failed to get current working directory");
        return 2;
    }

    lua_pushstring(L, cwd);
    free(cwd);
    return 1;
}


// Returns microseconds since Unix epoch, or -1 on error
int64_t get_high_res_timestamp(const char* path) {
    if (!path || path[0] == '\0') {
        return -1; // Invalid path
    }

    int64_t timestamp = 0;

#ifdef _WIN32
    WIN32_FILE_ATTRIBUTE_DATA file_info;
    if (GetFileAttributesEx(path, GetFileExInfoStandard, &file_info)) {
        ULARGE_INTEGER uli;
        uli.LowPart = file_info.ftLastWriteTime.dwLowDateTime;
        uli.HighPart = file_info.ftLastWriteTime.dwHighDateTime;

        // Convert to Unix epoch (January 1, 1970) and to microseconds
        timestamp = (uli.QuadPart - 116444736000000000ULL) / 10;
    } else {
        // Optionally handle GetLastError() for more detailed error information
        return -1;
    }
#else
    struct stat st;
    if (stat(path, &st) == 0) {
        #if defined(__APPLE__) && defined(__MACH__)
            timestamp = ((int64_t)st.st_mtimespec.tv_sec * 1000000LL) + (st.st_mtimespec.tv_nsec / 1000);
        #elif defined(__linux__)
            timestamp = ((int64_t)st.st_mtim.tv_sec * 1000000LL) + (st.st_mtim.tv_nsec / 1000);
        #else
            timestamp = (int64_t)st.st_mtime * 1000000LL;
        #endif
    } else {
        // Optionally handle errno for more detailed error information
        return -1;
    }
#endif

    return timestamp;
}

static int lua_get_path_timestamp(lua_State* L) {
    const char *path = luaL_checkstring(L, 1);
    int64_t timestamp = get_high_res_timestamp(path);

    if (timestamp == -1) {
        lua_pushnil(L);
        lua_pushstring(L, "Failed to get timestamp");
        return 2;
    }

    lua_pushinteger(L, timestamp);
    return 1;
}

#include "cstr.h"  // contains lua source code as C char array

int execute_lua_code(lua_State* L, const char* code, const char* name) {
    int status = luaL_loadbuffer(L, code, strlen(code), name);
    if (status != LUA_OK) {
        // If loading failed, error message is on top of the stack
        const char* error_msg = lua_tostring(L, -1);
        fprintf(stderr, "Failed to load Lua code: %s\n", error_msg);
        lua_pop(L, 1);  // Remove error message from stack
        return status;
    }
    
    // Execute the loaded code
    status = lua_pcall(L, 0, LUA_MULTRET, 0);
    if (status != LUA_OK) {
        // If execution failed, error message is on top of the stack
        const char* error_msg = lua_tostring(L, -1);
        fprintf(stderr, "Failed to execute Lua code: %s\n", error_msg);
        lua_pop(L, 1);  // Remove error message from stack
    }
    
    return status;
}

void set_command_line(lua_State* L, int argc, char** argv) {
    lua_newtable(L);

    for (int i = 0; i < argc; i++) {
        lua_pushinteger(L, i+1);
        lua_pushstring(L, argv[i]);
        lua_settable(L, -3);
    }
    lua_setglobal(L, "COMMAND_LINE");
}

int luaopen_mylib(lua_State *L) {
    lua_register(L, "get_path_timestamp", lua_get_path_timestamp);
    lua_register(L, "get_cwd", lua_get_cwd);
    lua_register(L, "get_executable_path", lua_get_executable_path);
    return 0;
}

// Example main function to demonstrate usage
int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    luaopen_mylib(L);

    set_command_line(L, argc, argv);

    fprintf(stderr, "before execute_lua_code\n");
    execute_lua_code(L, CSTRGet("blud.lua"), "blud.lua");

    // Optional: Print the Lua table for verification
//    luaL_dostring(L, "for i, v in ipairs(COMMAND_LINE) do print(i, v) end");

    lua_close(L);
    return 0;
}
