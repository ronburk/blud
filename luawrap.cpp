#include "luawrap.h"
#include <cassert>

bool Lua::open(){
    bool result = false;
    assert(lua_state == nullptr);
    lua_state = luaL_newstate();
    if(lua_state){
        luaL_openlibs(lua_state);
        result = true;
        }

    return result;
}

bool Lua::close(){

    bool result = true;

    assert(lua_state != nullptr);
    lua_close(lua_state);
    lua_state = nullptr;
    return result;
}

int  Lua::dostring(const char* str){
    assert(lua_state);

    return luaL_dostring(lua_state, str);
}

void Lua::dumptable(index table_index){
    LuaStackCheck stack(*this,0);

    push();  // start with nil key
    while (next(table_index)) {
        // Key is at index -2 and value is at -1
        index key{-2}, value{-1};
        printf("%s - %s", 
            type(type(key)),
            type(type(value))
            );
        auto str = tostdstring(key);
        printf(" [%s]\n", str.c_str());
        pop(); // remove value, leave key for next round
        }
    printf("stack frame size=%d\n", stackframesize());
    assert(stack.check());
}

std::optional<std::string> Lua::getfieldstr(Lua::index table_index, const char* name){
    std::string table_value;
    assert(type(table_index) == LUA_TTABLE);
    getfield(table_index, name);

    if(type(TOS) == LUA_TNIL)
        return std::nullopt;

    auto not_null = tostring();
    if(not_null)
        table_value = not_null;

    pop(); // ok to pop, since we made a copy to return
    return table_value;
}



int Lua::loadstring(const char* lua_code){
    assert(lua_state != nullptr);
    int result = luaL_loadstring(lua_state, lua_code);
}

int  Lua::loadfile(const char* filename){
    assert(lua_state != nullptr);

    int result = luaL_loadfile(lua_state, filename);
    assert(result != LUA_ERRFILE);
    return result;
}

bool Lua::loadrunfile(std::string filename){
    bool  result      = false;
    const char* c_str = filename.c_str();

    if(!loadfile(filename)){
        switch(resume()){
        case 0:
            result = true;
            break;
        case LUA_YIELD:
            printf("lua_resume for '%s' returned LUA_YIELD\n", c_str);
            break;
        default:
            printf("lua_resume for '%s' failed\n", c_str);
            }
        }
    else
        printf("loadfile of '%s' failed: %s\n", c_str, tostring());
    return result;
}

int Lua::pcall(int nargs, int nresults, int errfunc){
    int result = lua_pcall(lua_state, nargs, nresults, errfunc);
    const char* errtype;

    switch(result){
    case LUA_ERRRUN: errtype = "LUA_ERRRUN";
        break;
    case LUA_ERRMEM: errtype = "LUA_ERRMEM";
        break;
    case LUA_ERRERR: errtype = "LUA_ERRERR";
        break;
    default:
        errtype = "";
        }
    if(result){
        std::string message;
        lua_Debug   info;
        int level   = 0;
        while(lua_getstack(lua_state, level++, &info)){
            assert(lua_getinfo(lua_state, "nSl", &info));
            message += info.short_src;
            message += ":";
            message += std::to_string(info.currentline);
            message += "\n";
            }

        printf("pcall fails(%s): %s\n", errtype, lua_tostring(lua_state, -1));
        printf("%s\n", message.c_str());
        fflush(stdout);
        assert(false);
//        std::exit(EXIT_FAILURE);
        }

    return result;
}

void Lua::require(const char* libname){
    getglobal("require");
    assert(type() == LUA_TFUNCTION);
    push(libname);
    pcall(1, 1);
    printf("after Lua::require\n");
}
int  Lua::resume(int arg_count){
    assert(lua_state != nullptr);

    int result = lua_resume(lua_state, arg_count);
    if(result != 0){
        printf("error from lua_resume: %s\n", lua_tostring(lua_state, -1));
        }
    return result;
}

std::string Lua::tostdstring(index index){
    std::string result;

    push(index);
    auto existing_string = tostring();
    if(existing_string)
        result = existing_string;
    pop();
    return result;
}


void Lua::Error(const char* format, ...){
    std::string message;

    lua_getglobal(lua_state, "debug");
    if(lua_isnil(lua_state, -1))
        message = "[debug not loaded]";
    else
        message = "[debug is loaded]";
    pop();

    lua_Debug info;
    int       level = 0;
    while(lua_getstack(lua_state, level++, &info)){
        assert(lua_getinfo(lua_state, "nSl", &info));
        message += info.short_src;
        message += ":";
        message += std::to_string(info.currentline);
        message += "\n";
        }

    va_list args;
    va_start(args, format);

    // Determine the size of the buffer
    va_list tmp_args;
    va_copy(tmp_args, args);
    int required_size = vsnprintf(nullptr, 0, format, tmp_args) + 1;  // +1 for '\0'
    va_end(tmp_args);

    // Allocate a buffer and format the string
    // Allocate space directly in the string
    std::string result(required_size, '\0');

    vsnprintf(&result[0], required_size, format, args);

    va_end(args);
    message += result;
//    push(message.c_str());
//    error();
    luaL_error(lua_state, "%s", message.c_str());
        
}

