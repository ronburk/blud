#include <stdio.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s script.lua\n", argv[0]);
        return 2;
    }

    lua_State *lua = luaL_newstate();
    if (!lua) {
        fputs("could not create Lua state\n", stderr);
        return 2;
    }

    luaL_openlibs(lua);
    int status = luaL_dofile(lua, argv[1]);
    if (status != 0) {
        const char *message = lua_tostring(lua, -1);
        fprintf(stderr, "%s\n", message ? message : "Lua test failed");
    }

    lua_close(lua);
    return status == 0 ? 0 : 1;
}
