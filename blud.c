#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <limits.h>


#include <ctype.h>
#include <stdbool.h>
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

//#include "cstr.h"  // contains lua source code as C char array
extern const char* CSTRGet(const char* filename);

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
        // printf("lua_get_dir_cache(%s)\n", dir);
        os_get_dir(callback, (void*)&info, dir);
    }
    luaL_pushresult(&info.buffer);
    lua_rawset(L, -3); // table["."] = %z-separated buffer of all dir entry names

    return 1;
}


static int pattern_match(const char* pattern, const char* input){
    const char* back_pat    = NULL;
    const char* back_input;

    for(;;){
        unsigned char c     = *input++;
        unsigned char pat_c = *pattern++;
        switch(pat_c){
        case '*' :
            while((pat_c = *pattern) == '*')
                ++pattern;
            if(pat_c == '\0')  // trailing star(s) guarantees a match
                return true;
            back_pat    = pattern; // else, remember new backtrack positions
            back_input  = --input;
            continue;
        case '[' :  {
            unsigned char   left, right;
            bool            negate  = false, match = false;
            const char*     rover   = pattern;
            if(*rover == '!'){
                negate = true;
                ++rover;
            }
            left = *rover++;
            while(!match && left != '\0'){
                if(rover[0] == '-' && (right=rover[1]) != ']' && right != '\0')
                    rover += 2;
                else
                    right = left;
                match = (c >= left && c <= right);
                if((left=*rover++) == ']')
                    break;  // break means backtrack
            }
            while(left != '\0' && left != ']') // eat remainder of [..]
                left = *rover++;
            if(left == ']'){    // if it was well-formed
                pattern = rover;
                if(match != negate)
                    continue;
                break;  // break means backtrack
            } // else fall through to treat like literal
        }
            /* fallthrough */
        default:
            if(c == pat_c || pat_c == '?'){
                if(pat_c == '\0')
                    return true;
                else
                    continue;
            }
        }
        // didn't match the current input character, backtrack
        if(c == '\0' || !back_pat)
            return false;
        pattern = back_pat;
        input   = ++back_input;
    }
        
}


static int lua_glob_expand(lua_State* L) {
    // Ensure correct number of arguments
    if (lua_gettop(L) != 3)
        return luaL_error(L, "Expected 3 arguments: words (table), pattern (string), names (string)");
    if (!lua_istable(L, 1))
        return luaL_error(L, "'words' must be a table");
    if (!lua_isstring(L, 2))
        return luaL_error(L, "'pattern' must be a string");
    if (!lua_isstring(L, 3))
        return luaL_error(L, "'names' must be NUL-separated names in string");
    const char* pattern         = lua_tostring(L, 2);
    size_t      names_length;
    const char* names           = lua_tolstring(L, 3, &names_length); // Get pointer to 'names' and its length
    const char* end             = names + names_length;
    lua_Integer size            = lua_objlen(L, 1);

    int  matched = 0;
    while(names < end){
        size_t name_len = strnlen(names, end - names);
        if(pattern_match(pattern, names)){
            /*printf("Match on '%s'\n", names); */
            ++matched;
            lua_pushinteger(L, ++size);
            lua_pushlstring(L, names, name_len);
            lua_settable(L, 1);
        }
        names += name_len + 1;
    }
#if 0
    if(matched == 0){
        lua_pushinteger(L, ++size);
        lua_pushlstring(L, pattern, strlen(pattern));
        lua_settable(L, 1);
    }
    return 0;
#else
    lua_pushinteger(L, matched);
    return 1;
#endif
}



#if 0
static int lua_glob_to_lua(lua_State* L){
    const char* glob = luaL_checkstring(L, 1);
    char        buffer[1024*2];
    char*       output = buffer;
    int         c;

    *output++ = '(';
    while((c = *glob++) != '\0'){
        if(c == '*'){
            *output++ = '.';
            *output++ = '*';
        } else if(c == '?'){
            *output++ = '.';
        } else if(c == '[' && char_class(&output, &glob)){
            ;
        } else{
            *output++ = c;
        }
    }

    return 1;
}

#endif


/* we are called only after macro expansion and operators are removed,
 * so all we care about are sequences of non-white characters
 */
static int lua_tokenize_dependency_line(lua_State *L) {
    const char* input       = luaL_checkstring(L, 1);
    const char* rover       = input;
    int         index       = 0;
    const char* start;

    lua_newtable(L);  // create table to return
    for(;;){
        while(*rover && isspace((unsigned char)*rover))
            ++rover;
        if(!*rover) // if end of string
            break;
        start = rover;      // mark possible start of word
        while(*rover && !isspace((unsigned char)*rover))
            ++rover;
        // printf("token='%*.*s'\n", (int)(rover-start), (int)(rover-start), start);
        lua_pushlstring(L, start, rover - start);
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



// The Lua C function that wraps the CSTRGet function
int lua_CSTRGet(lua_State* L) {
    // Check that the first argument is a string (filename)
    const char* filename = luaL_checkstring(L, 1);
    
    // Call the actual C function
    const char* result = CSTRGet(filename);
    
    // If result is NULL, return nil to Lua
    if (result == NULL) {
        lua_pushnil(L);
    } else {
        // Push the result as a Lua string
        lua_pushstring(L, result);
    }
    
    // Return one value to Lua (the string or nil)
    return 1;
}

static int lua_os_getcwd(lua_State *L) {
    char *cwd = os_getcwd();
    if (cwd == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "Failed to get current working directory");
        return 2;
    }

    lua_pushstring(L, cwd);
    free(cwd);
    return 1;
}

static int lua_os_setcwd(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_setcwd(path));
    return 1;
}

static int lua_os_mkdir(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_mkdir(path));
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


int initialize_lua(lua_State* L, const char* init_str) {
    assert(init_str != NULL);
    // Create the "blud" table in the global Lua environment
    lua_newtable(L);           // Push a new empty table onto the stack
    lua_setglobal(L, "blud");  // Set the table as a global variable called "blud"

    // Now compile and execute the init_str (should define error handling in the "blud" table)
    if (luaL_loadbuffer(L, init_str, strlen(init_str), "init_code") != LUA_OK) {
        fprintf(stderr, "Error loading init code: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);  // Pop the error message from the stack
        return -1;
    }

    // Execute the loaded init code (init_str), which sets up things in the "blud" table
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        fprintf(stderr, "Error running init code: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);  // Pop the error message
        return -1;
    }

    return 0;  // Success
}


int execute_lua_code(lua_State* L, const char* code, const char* name) {
    // Get the error handler function (blud.error_handler) onto the stack
    lua_getglobal(L, "blud");
    if (!lua_istable(L, -1)) {
        fprintf(stderr, "Error: 'blud' is not a table\n");
        lua_pop(L, 1);  // Pop the non-table value from the stack
        return -1;
    }
    lua_getfield(L, -1, "error_handler");
    if (!lua_isfunction(L, -1)) {
        fprintf(stderr, "Error: blud.error_handler not found or not a function\n");
        lua_pop(L, 2);  // Pop the non-function value and 'blud' table from the stack
        return -1;
    }
    lua_remove(L, -2);  // Remove the 'blud' table from the stack, leaving only the error handler

    int status = luaL_loadbuffer(L, code, strlen(code), name);
    if (status != LUA_OK) {
        // If loading failed, error message is on top of the stack
        const char* error_msg = lua_tostring(L, -1);
        fprintf(stderr, "Failed to load Lua code: %s\n", error_msg);
        lua_pop(L, 2);  // Remove error message and error handler from stack
        return status;
    }
    
    // Execute the loaded code
    status = lua_pcall(L, 0, 0, -2);
    if (status != LUA_OK) {
        // If execution failed, error message is on top of the stack
        const char* error_msg = lua_tostring(L, -1);
        fprintf(stderr, "Failed to execute Lua code: %s\n", error_msg);
        lua_pop(L, 1);  // Remove error message from stack
    }
    
    lua_pop(L, 1); // pop error handler
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
    lua_register(L, "CSTRGet", lua_CSTRGet);
    lua_register(L, "glob_expand", lua_glob_expand);
    lua_register(L, "os_getcwd", lua_os_getcwd);
    lua_register(L, "os_setcwd", lua_os_setcwd);
    lua_register(L, "get_dir_cache", lua_get_dir_cache);
    lua_register(L, "os_mkdir", lua_os_mkdir);
    lua_register(L, "get_executable_path", lua_get_executable_path);
    lua_register(L, "get_path_timestamp", lua_get_path_timestamp);
    lua_register(L, "tokenize_dependency_line", lua_tokenize_dependency_line);
    return 0;
}

int main(int argc, char** argv) {
    // printf("blud build %d\n", BUILD_ID);
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    // fprintf(stderr, "before initialize_lua\n");
    initialize_lua(L, CSTRGet("init.lua"));
    luaopen_mylib(L);

    set_command_line(L, argc, argv);

    // fprintf(stderr, "before execute_lua_code\n");
//    execute_lua_code(L, CSTRGet("blud.lua"), "blud.lua");
    execute_lua_code(L, CSTRGet("main.lua"), "[main.lua]");

    // Optional: Print the Lua table for verification
//    luaL_dostring(L, "for i, v in ipairs(COMMAND_LINE) do print(i, v) end");

    lua_close(L);
    return 0;
}
