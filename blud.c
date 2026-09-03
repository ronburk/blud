#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <assert.h>
#include <errno.h>
#include <inttypes.h>
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
    #include <unistd.h>
#endif

#include "blud.h"
#include "cstr.h"
#include "os.h"


static const char blud_timestamp_metatable[] = "blud.timestamp";
static const char blud_timestamp_api_metatable[] = "blud.timestamp_api";

static BLUD_TIMESTAMP* new_blud_timestamp(lua_State* L) {
    BLUD_TIMESTAMP* timestamp = (BLUD_TIMESTAMP*)lua_newuserdata(
        L,
        sizeof *timestamp
    );

    luaL_getmetatable(L, blud_timestamp_metatable);
    assert(lua_istable(L, -1));
    lua_setmetatable(L, -2);
    return timestamp;
}

static BLUD_TIMESTAMP* check_blud_timestamp(lua_State* L, int index) {
    return (BLUD_TIMESTAMP*)luaL_checkudata(
        L,
        index,
        blud_timestamp_metatable
    );
}

static int compare_blud_timestamps(
    const BLUD_TIMESTAMP* left,
    const BLUD_TIMESTAMP* right
) {
    if(left->seconds != right->seconds)
        return left->seconds < right->seconds ? -1 : 1;
    if(left->nanoseconds != right->nanoseconds)
        return left->nanoseconds < right->nanoseconds ? -1 : 1;
    return 0;
}

static int lua_blud_timestamp_equal(lua_State* L) {
    const BLUD_TIMESTAMP* left = check_blud_timestamp(L, 1);
    const BLUD_TIMESTAMP* right = check_blud_timestamp(L, 2);

    lua_pushboolean(L, compare_blud_timestamps(left, right) == 0);
    return 1;
}

static int lua_blud_timestamp_less_than(lua_State* L) {
    const BLUD_TIMESTAMP* left = check_blud_timestamp(L, 1);
    const BLUD_TIMESTAMP* right = check_blud_timestamp(L, 2);

    lua_pushboolean(L, compare_blud_timestamps(left, right) < 0);
    return 1;
}

static int lua_blud_timestamp_less_equal(lua_State* L) {
    const BLUD_TIMESTAMP* left = check_blud_timestamp(L, 1);
    const BLUD_TIMESTAMP* right = check_blud_timestamp(L, 2);

    lua_pushboolean(L, compare_blud_timestamps(left, right) <= 0);
    return 1;
}

static int lua_blud_timestamp_tostring(lua_State* L) {
    const BLUD_TIMESTAMP* timestamp = check_blud_timestamp(L, 1);
    char text[64];
    int length = snprintf(
        text,
        sizeof text,
        "timestamp(%" PRId64 ".%09" PRIu32 ")",
        timestamp->seconds,
        timestamp->nanoseconds
    );

    assert(length >= 0 && (size_t)length < sizeof text);
    lua_pushlstring(L, text, (size_t)length);
    return 1;
}


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
    const char*   directory;
    luaL_Buffer   buffer;
} BLUD_DIR_INFO;

static void push_child_path(lua_State* L, const char* directory, const char* name) {
    size_t length = strlen(directory);
    int has_separator = length > 0 &&
                        (directory[length - 1] == '/' ||
                         directory[length - 1] == '\\');

    lua_pushfstring(L, "%s%s%s", directory, has_separator ? "" : "/", name);
}

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

        if (is_dir) {
            lua_pushliteral(info->L, "path");
            push_child_path(info->L, info->directory, name);
            lua_settable(info->L, -3);
        }
    }
    // now stack is [name][table_of_attributes]
    assert(lua_istable(info->L, info->table_index));
    lua_rawset(info->L, info->table_index);
}

static int lua_get_dir_cache(lua_State *L) {
    BLUD_DIR_INFO   info;
    const char*     dir = luaL_checkstring(L, 1);

    info.L              = L;
    info.directory      = dir;
    lua_newtable(L);        // table return value
    info.table_index    = lua_gettop(L);
    lua_pushstring(L, "."); // key to store big buffer of all dir entry names
    {
        int status;

        luaL_buffinit(L, &info.buffer);
        // printf("lua_get_dir_cache(%s)\n", dir);
        errno = 0;
        status = os_get_dir(callback, (void*)&info, dir);
        if(status != 0) {
            int error_number = errno;

            lua_settop(L, 1); // discard the partial table and buffer fragments
            if(error_number != 0)
                return luaL_error(L, "could not enumerate directory: %s: %s",
                                  dir, strerror(error_number));
            return luaL_error(L, "could not enumerate directory: %s", dir);
        }
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


/* We are called only after macro expansion and operators are removed,
 * so all we care about are sequences of non-white characters.
 * Also used for arguments of 'include' directive.
 */
static int lua_tokenize_dependency_line(lua_State *L) {
    const char* input       = luaL_checkstring(L, 1);
    const char* rover       = input;
    int         index       = 0;
    const char* start;

    lua_newtable(L);   // create table to return
    for(;;){
        while(*rover && isspace((unsigned char)*rover))
            ++rover;
        if(!*rover)    // if end of string
            break;
        start = rover; // mark possible start of word
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

int lua_CSTRGetCompiled(lua_State* L) {
    const char* filename = luaL_checkstring(L, 1);
    size_t size;
    const char* result = CSTRGetCompiled(filename, &size);

    if (result == NULL) {
        lua_pushnil(L);
    } else {
        lua_pushlstring(L, result, size);
    }

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

// Lua: status = os_copy_file(from, to)
// status is 0 on success or -1 on failure.
static int lua_os_copy_file(lua_State *L) {
    const char* from = luaL_checkstring(L, 1);
    const char* to = luaL_checkstring(L, 2);

    lua_pushinteger(L, os_copy_file(from, to));
    return 1;
}

// Lua: status = os_copy_dir(from, to)
// status is 0 on success or -1 on failure.
static int lua_os_copy_dir(lua_State *L) {
    const char* from = luaL_checkstring(L, 1);
    const char* to = luaL_checkstring(L, 2);

    lua_pushinteger(L, os_copy_dir(from, to));
    return 1;
}

static int lua_os_mkdir(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_mkdir(path));
    return 1;
}

// Lua: result = os_mkdir_one(path)
// result is 0 when created, 1 when a directory already exists, or 2 on error.
static int lua_os_mkdir_one(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_mkdir_one(path));
    return 1;
}

// Lua: type = os_path_type(path)
// type is 0 for missing, 1 for a leaf object, or 2 for a real directory.
static int lua_os_path_type(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_path_type(path));
    return 1;
}

// Lua: status = os_remove_dir(path)
// status is 0 on success or -1 when the empty directory cannot be removed.
static int lua_os_remove_dir(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_remove_dir(path));
    return 1;
}

// Lua: status = os_remove_file(path)
// status is 0 on success or -1 when the file/link cannot be removed.
static int lua_os_remove_file(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_remove_file(path));
    return 1;
}

// Lua: status = os_touch(path)
// status is 0 after updating/creating path, or -1 on failure.
static int lua_os_touch(lua_State *L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushinteger(L, os_touch(path));
    return 1;
}

// Lua: timestamp = blud.timestamp.get_system()
// timestamp is a blud timestamp userdata value.
static int lua_get_system_timestamp(lua_State* L) {
    BLUD_TIMESTAMP* timestamp = new_blud_timestamp(L);

    if (os_get_system_timestamp(timestamp) != 0)
        return luaL_error(L, "could not read system clock");
    return 1;
}

static int lua_blud_timestamp_api_index(lua_State* L) {
    const char* key;

    luaL_checkudata(L, 1, blud_timestamp_api_metatable);
    key = luaL_checkstring(L, 2);
    if (strcmp(key, "oldest") == 0) {
        lua_pushvalue(L, lua_upvalueindex(1));
        return 1;
    }
    if (strcmp(key, "get_system") == 0) {
        lua_pushcfunction(L, lua_get_system_timestamp);
        return 1;
    }
    return 0;
}

static int lua_blud_timestamp_api_newindex(lua_State* L) {
    return luaL_error(L, "blud.timestamp is read-only");
}


int initialize_lua(lua_State* L, const char* init_code, size_t init_size) {
    assert(init_code != NULL);
    // Create the "blud" table in the global Lua environment
    lua_newtable(L);           // Push a new empty table onto the stack
    lua_setglobal(L, "blud");  // Set the table as a global variable called "blud"

    // Load and execute init.lua so the error handler is available for main.lua.
    if (luaL_loadbuffer(L, init_code, init_size, "[init.lua]") != LUA_OK) {
        fprintf(stderr, "Error loading init code: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);  // Pop the error message from the stack
        return -1;
    }

    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        fprintf(stderr, "Error running init code: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);  // Pop the error message
        return -1;
    }

    return 0;  // Success
}


int execute_lua_code(
    lua_State* L,
    const char* code,
    size_t code_size,
    const char* name
) {
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

    int status = luaL_loadbuffer(L, code, code_size, name);
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
        const char* compile_error_prefix = "BLUD_COMPILE_ERROR:";
        size_t compile_error_prefix_len = strlen(compile_error_prefix);
        if (strncmp(
                error_msg,
                compile_error_prefix,
                compile_error_prefix_len
            ) == 0) {
            fprintf(stderr, "%s\n", error_msg + compile_error_prefix_len);
        } else {
            fprintf(stderr, "Failed to execute Lua code: %s\n", error_msg);
        }
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
    BLUD_TIMESTAMP* oldest_timestamp;

    luaL_newmetatable(L, blud_timestamp_metatable);
    lua_pushcfunction(L, lua_blud_timestamp_equal);
    lua_setfield(L, -2, "__eq");
    lua_pushcfunction(L, lua_blud_timestamp_less_than);
    lua_setfield(L, -2, "__lt");
    lua_pushcfunction(L, lua_blud_timestamp_less_equal);
    lua_setfield(L, -2, "__le");
    lua_pushcfunction(L, lua_blud_timestamp_tostring);
    lua_setfield(L, -2, "__tostring");
    lua_pushliteral(L, "blud timestamp");
    lua_setfield(L, -2, "__metatable");
    lua_pop(L, 1);

    luaL_newmetatable(L, blud_timestamp_api_metatable);
    oldest_timestamp = new_blud_timestamp(L);
    oldest_timestamp->seconds = 0;
    oldest_timestamp->nanoseconds = 0;
    lua_pushcclosure(L, lua_blud_timestamp_api_index, 1);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, lua_blud_timestamp_api_newindex);
    lua_setfield(L, -2, "__newindex");
    lua_pushliteral(L, "blud timestamp API");
    lua_setfield(L, -2, "__metatable");
    lua_pop(L, 1);

    lua_getglobal(L, "blud");
    lua_newuserdata(L, 1);
    luaL_getmetatable(L, blud_timestamp_api_metatable);
    lua_setmetatable(L, -2);
    lua_setfield(L, -2, "timestamp");
    lua_pushinteger(L, BUILD_ID);
    lua_setfield(L, -2, "build_id");
    lua_pop(L, 1);

    lua_register(L, "CSTRGet", lua_CSTRGet);
    lua_register(L, "CSTRGetCompiled", lua_CSTRGetCompiled);
    lua_register(L, "glob_expand", lua_glob_expand);
    lua_register(L, "os_getcwd", lua_os_getcwd);
    lua_register(L, "os_setcwd", lua_os_setcwd);
    lua_register(L, "get_dir_cache", lua_get_dir_cache);
    lua_register(L, "os_copy_file", lua_os_copy_file);
    lua_register(L, "os_copy_dir", lua_os_copy_dir);
    lua_register(L, "os_mkdir", lua_os_mkdir);
    // Filesystem primitives used by shell.lua; wrapper comments above document
    // their exact global Lua signatures and return values.
    lua_register(L, "os_mkdir_one", lua_os_mkdir_one);
    lua_register(L, "os_path_type", lua_os_path_type);
    lua_register(L, "os_remove_dir", lua_os_remove_dir);
    lua_register(L, "os_remove_file", lua_os_remove_file);
    lua_register(L, "os_touch", lua_os_touch);
    lua_register(L, "get_executable_path", lua_get_executable_path);
    lua_register(L, "tokenize_dependency_line", lua_tokenize_dependency_line);
    return 0;
}

static int run_lua_vm(int argc, char** argv) {
    // printf("blud build %d\n", BUILD_ID);
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    size_t init_size;
    const char* init_code = CSTRGetCompiled("init.lua", &init_size);
    assert(init_code != NULL);
    if (initialize_lua(L, init_code, init_size) != 0) {
        lua_close(L);
        return 1;
    }
    luaopen_mylib(L);

    set_command_line(L, argc, argv);

    size_t main_size;
    const char* main_code = CSTRGetCompiled("main.lua", &main_size);
    assert(main_code != NULL);
    int status = execute_lua_code(
        L,
        main_code,
        main_size,
        "[main.lua]"
    );

    // Optional: Print the Lua table for verification
//    luaL_dostring(L, "for i, v in ipairs(COMMAND_LINE) do print(i, v) end");

    lua_close(L);
    return status == LUA_OK ? 0 : 1;
}

int main(int argc, char** argv) {
    return run_lua_vm(argc, argv);
}
