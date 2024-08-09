#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>


#include <ctype.h>
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

#include "os.h"


#if 0
static int  is_pattern(const char* pattern, int len){
    const char *wildcards = "[*?{";
    for (int i = 0; i < len; ++i) {
        if (memchr(wildcards, pattern[i], strlen(wildcards))) {
            return 1; // Found a wildcard character
        }
    }
    return 0; // No wildcard characters found
}
#endif

typedef struct BLUD_DIR_INFO {
    lua_State*    L;
    int           table_index;
    luaL_Buffer   buffer;
} BLUD_DIR_INFO;

static void callback(void* data, const char* name, int64_t timestamp, int is_dir){
    BLUD_DIR_INFO*  info = (BLUD_DIR_INFO*) data;
    size_t          name_len = strlen(name);
    printf("callback(%s) %d\n", name, info->table_index);
    
    luaL_addlstring(&info->buffer, name, name_len + 1); // add name & null byte
    lua_pushlstring(info->L, name, name_len);           // put in position for later lua_rawset()
    {
        lua_newtable(info->L);

        lua_pushstring(info->L, "name");
        lua_pushlstring(info->L, name, name_len);
        lua_settable(info->L, -3);

        lua_pushstring(info->L, "timestamp");
        lua_pushinteger(info->L, timestamp);
        lua_settable(info->L, -3);

        lua_pushstring(info->L, "is_dir");
        lua_pushboolean(info->L, is_dir);
        lua_settable(info->L, -3);
    }
    // now stack is [name][table_of_attributes]
    assert(lua_istable(info->L, info->table_index));
    lua_rawset(info->L, info->table_index);
}

static int lua_get_dir_cache(lua_State *L) {
    BLUD_DIR_INFO   info;
    const char*     dir = luaL_checkstring(L, 1);

    info.L              = L;
    lua_newtable(L);        // table return value
    info.table_index    = lua_gettop(L);
    lua_pushstring(L, "."); // key to store big buffer of all dir entry names
    {
        luaL_buffinit(L, &info.buffer);
        printf("lua_get_dir_cache(%s)\n", dir);
        os_get_dir(callback, (void*)&info, dir);
    }
    luaL_pushresult(&info.buffer);
    lua_rawset(L, -3); // table["."] = %z-separated buffer of all dir entry names

    return 1;
}

static int lua_glob_to_lua(lua_State* L){

}



static int lua_expand_path_patterns(lua_State *L) {
    const char* input       = luaL_checkstring(L, 1);
    const char* rover       = input;
//    size_t      len         = strlen(input);
//    int*        indices     = (int*)malloc(sizeof(int)*len*2);
    int         index       = 0;
    int         c;
    const char* start;
    size_t      wordlen;

    lua_newtable(L);  // create table to return
    printf("input='%s'\n", input);
    for(;;){
        while((c = *rover) != '\0')  // skip whitespace
            if(c != ' ' && c != '\t')
                break;
            else
                ++rover;
        printf("    c = '%c'\n", c);
        start = rover; // mark possible start of word
        if(c == '\0')
            break;
        else if(c == ':'){
            const char* peek = ++rover;
            while((c=*peek++) != '\0' && (isalnum(c) || c == '_'))
                ;
            if(c == ':'){
                wordlen = peek - start;
                rover   = peek;
            } else {
                wordlen    = 1;
            }
        } else if(c == '[' && *rover == '['){
            assert(0); // not written yet
        } else {
            while(c != ' ' && c != '\t' && c != '\0' && c != ':')
                c = *++rover;
            wordlen     =  (rover - start);
        }
        printf("    [%d]>%s\n", (int)wordlen, start);
        lua_pushlstring(L, start, wordlen);
        lua_rawseti(L, -2, ++index);
    }

    return 1;
}

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
    lua_register(L, "get_cwd", lua_get_cwd);
    lua_register(L, "get_dir_cache", lua_get_dir_cache);
    lua_register(L, "get_executable_path", lua_get_executable_path);
    lua_register(L, "get_path_timestamp", lua_get_path_timestamp);
    lua_register(L, "expand_path_patterns", lua_expand_path_patterns);
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
