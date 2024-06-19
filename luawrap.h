#ifndef LUAWRAP_H
#define LUAWRAP_H

#include <cassert>
#include <optional>
#include <string>
#include <utility>
//#include "common.h"
#include <lua.hpp>

using std::string;
using std::to_underlying;

#if 0
template <typename E>
constexpr typename std::underlying_type<E>::type to_underlying(E e) noexcept {
    return static_cast<typename std::underlying_type<E>::type>(e);
}
#endif

/* Lua -- thinnest possible wrapper around a lua_state pointer.
 *
 * No RAII! You track lifetimes yourself.
 * default constructor is useless until you call .open().
 * Constructor that takes lua_State* is useful in callback functions.
 */


class Lua{
public:
    enum class index : int {};
    static const index TOS{-1};
    constexpr index operator[](int i) const
        { return static_cast<index>(i); }
    Lua()
        : lua_state(nullptr) {}
    Lua(lua_State* state)
        : lua_state(state) {}
    virtual ~Lua() noexcept {};

    bool open();
    bool close();
    void createtable(int array_count=0, int nonarray_count=0)
        { lua_createtable(lua_state, array_count, nonarray_count); }
    int  dostring(const char* str);
    void dumptable(index table_index);
    void error()
        { lua_error(lua_state); }
    void getfield(index table_index, const char* name)
        { lua_getfield(lua_state, to_underlying(table_index), name); }
    std::optional<std::string> getfieldstr(index, const char* name);
    void getglobal(const char* name)
        { lua_getglobal(lua_state, name); }
    void gettable(int index=-1)
        { lua_gettable(lua_state, index); }
    index  gettop() const
        { return index(lua_gettop(lua_state)); }
    int  isboolean(int index=-1)
        { return lua_isboolean(lua_state, index); }
    int  isnumber(int index=-1)
        { return lua_isnumber(lua_state, index); }
    int  islightuserdata(int index=-1)
        { return lua_islightuserdata(lua_state, index); }
    int  isfunction(int index=-1)
        { return lua_isfunction(lua_state, index); }
    int  isnil(int index=-1)
        { return lua_isnil(lua_state, index); }
    void insert(int index)
        { lua_insert(lua_state, index); }
    int  loadfile(const char* filename);
    int  loadfile(std::string filename)
        { return loadfile(filename.c_str()); }
    bool loadrunfile(std::string filename);
    int  loadstring(const char* filename);
    int  loadstring(std::string filename)
        { return loadstring(filename.c_str()); }
    void newtable()
        { lua_newtable(lua_state); }
    int next(Lua::index table_index)
        { return lua_next(lua_state, to_underlying(table_index)); }
    void registerlib(const char*libname, const luaL_Reg *apitable)
        { luaL_register(lua_state, libname, apitable); }
    int  resume(int arg_count=0);
    void pop(int n=1)
        { lua_pop(lua_state, n); }
    int  pcall(int nargs=0, int nresults=0, int errfunc=0);
    void push(index source_index)
        { lua_pushvalue(lua_state, to_underlying(source_index)); }
    void push(lua_CFunction func, int variable_count=0)
        { lua_pushcclosure(lua_state, func, variable_count); }
    void push(bool value)
        { lua_pushboolean(lua_state, value); }
    void push(int value)
        { push((double)value); }
    void push(const char* str, size_t len)
        { lua_pushlstring(lua_state, str, len); }
    void push(const char* str)
        { lua_pushstring(lua_state, str); }
    void push(const unsigned char* str)
        { lua_pushstring(lua_state, reinterpret_cast<const char*>(str)); }
    void push(const std::string str)
        { push(str.c_str()); }
    void push(double value)
        { lua_pushnumber(lua_state, value); }
    void push(void* data)
        { lua_pushlightuserdata(lua_state, data); }
    void push()
        { lua_pushnil(lua_state); }
    void pushnil() { push(); }
    void rawseti(Lua::index index, int array_offset)
        { lua_rawseti(lua_state, to_underlying(index), array_offset); }
    void register_func(const char* name, lua_CFunction func)
        { lua_register(lua_state, name, func); }
    void register_func(std::string name, lua_CFunction func)
        { lua_register(lua_state, name.c_str(), func); }
    void require(const char* libname);
    void setfield(Lua::index index, const char*field_name)
        { lua_setfield(lua_state, to_underlying(index), field_name); }
    void setfield(Lua::index index, const std::string field_name)
        { lua_setfield(lua_state, to_underlying(index), field_name.c_str()); }
    void setglobal(const char* name)
        { lua_setglobal(lua_state, name); }
    void settable(Lua::index index)
        { lua_settable(lua_state, to_underlying(index)); }
    int stackframesize()
        { return int(gettop()); }
    const char* tostring(Lua::index index=TOS, size_t* len=nullptr)
        { return lua_tolstring(lua_state, to_underlying(index), len); }
    std::string tostdstring(Lua::index index=TOS);
//    void* touserdata(int index=-1)
//        { return lua_touserdata(lua_state, index); }
    void* touserdata(Lua::index index=TOS)
        { return lua_touserdata(lua_state, to_underlying(index)); }
    lua_CFunction tocfunction(int index=-1)
        { return lua_tocfunction(lua_state, index); }
    int type(Lua::index var_index=TOS)
        {return lua_type(lua_state, static_cast<int>(var_index)); }
    const char* type(int type)
        {return lua_typename(lua_state, type); }
    Lua::index upvalueindex(int i)
        { return static_cast<Lua::index>lua_upvalueindex(i); }

    void* getcppobject();

    void Error(const char* format, ...);


private:
    lua_State* lua_state = nullptr;
};

class LuaStackCheck{
    Lua L;
    int change;
    int start;
public:
    LuaStackCheck(Lua L, int change):L(L),change(change){
        start = to_underlying(L.gettop());
        }
    bool check() { return to_underlying(L.gettop()) == start + change; }
    ~LuaStackCheck(){
        assert(to_underlying(L.gettop()) == start + change);
        }
};


#if 0
class Callable    {
public:
    
};


void* FetchObjectFromLuaStack(Lua L);

template <typename T, typename F>
    int   LuaCallback(lua_State* state){
    Lua L(state);
    // fetch C++ object ptr from stack
    T* Object = (T*)L.getcppobject();
    return Object->F(L);
}

class Foo{
    int Callback(Lua L);
    void Register(Lua L){
        lua_CFunction func = &LuaCallback<Foo,Callback>;
        dummy(L, func);
    }
};

#endif

#endif
