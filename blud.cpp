/* blud.cpp - main C++ source for blud
 */

#include "luawrap.h"
#include <filesystem>
namespace fs = std::filesystem;

string bludfile_path = "bludfile";
std::string blud_source = R"(
#include "blud.lua"
)";

int main(int /*arg_count*/, char** /*args*/){
    Lua L;
    assert(L.open());

    if(!fs::exists(bludfile_path)){
        fprintf(stderr, "%s: doesn't exist\n", bludfile_path.c_str());
        return 1;
    } else if(!fs::is_regular_file(bludfile_path)) {
        fprintf(stderr, "%s: is not a regular file type\n", bludfile_path.c_str());
        return 1;
    }
    printf("There will be blud!\n");

    auto error_code = L.loadstring(blud_source);
    
    return 0;
}
