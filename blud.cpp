/* blud.cpp - main C++ source for blud
 */

#include "luawrap.h"
#include <filesystem>
namespace fs = std::filesystem;


//const char* blud_source = CSTRGet("blud.lua");

string bludfile_path = "bludfile";
#include "bludlua.cpp"

class Bludfile {
public:
    Bludfile() : path("bludfile"), luac_path(path + ".luac"), lua_source(CSTRGet("blud.lua")) {}
    void    load(Lua L);
    void    check_valid_file(string path);
    bool    needs_compile();
private:
    string  path, luac_path, lua_source;
};


bool Bludfile::needs_compile(){
    bool result = false;
    if(!fs::exists(luac_path))
        result = true;
    else if(fs::last_write_time(luac_path) < fs::last_write_time(path))
        result = true;
    return result;
}

void Bludfile::check_valid_file(string path){
    if(!fs::exists(path))
        fprintf(stderr, "%s: doesn't exist\n", path.c_str());
    else if(!fs::is_regular_file(path))
        fprintf(stderr, "%s: is not a regular file type\n", path.c_str());
    else
        return;
    exit(1);
}

void Bludfile::load(Lua L){
    check_valid_file(path);
    if(needs_compile()) {
        auto error_code = L.loadstring(lua_source);
        assert(error_code == 0);
    }
}


int main(int /*arg_count*/, char** /*args*/){
    Lua L;
    assert(L.open());
    Bludfile bludfile;
    bludfile.load(L);
    printf("There will be blud!\n");
    string luac_path = bludfile_path + ".luac";
    if(fs::exists(luac_path)){
        
    }


    return 0;
}
