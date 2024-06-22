#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "bludlua.c"  // contains lua source code as C char array

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

// Example main function to demonstrate usage
int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

    fprintf(stderr, "before set_command_line\n");
    set_command_line(L, argc, argv);
    fprintf(stderr, "before execute_lua_code\n");
    execute_lua_code(L, CSTRGet("blud.lua"), "blud.lua");

    // Optional: Print the Lua table for verification
    luaL_dostring(L, "for i, v in ipairs(COMMAND_LINE) do print(i, v) end");

    lua_close(L);
    return 0;
}
