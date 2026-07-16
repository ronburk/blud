#include <stdio.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

int main(int argc, char **argv)
{
    lua_State *lua;

    if (argc != 2) {
        fprintf(stderr, "usage: %s script.lua\n", argv[0]);
        return 2;
    }

    lua = luaL_newstate();
    if (!lua) {
        fputs("could not create Lua state\n", stderr);
        return 2;
    }

    luaL_openlibs(lua);
    if (luaL_dofile(lua, argv[1]) != 0) {
        const char *message = lua_tostring(lua, -1);
        fprintf(stderr, "%s\n", message ? message : "Lua test failed");
        lua_close(lua);
        return 1;
    }

    lua_close(lua);
    return 0;
}
