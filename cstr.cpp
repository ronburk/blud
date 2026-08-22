/* cstr.c - Utility to transform text file into compilable C array of char.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <cassert>
#include <vector>
#include <string>
#include <filesystem>

extern "C"
    {
#include <lua.h>
#include <lauxlib.h>
    }

namespace fs = std::filesystem;

using std::vector;
using std::string;

bool Debug = false;

vector<string> ParseCommandLine(int ArgCount, char** Args)
    {
    vector<string> Result;

    for(int iArg = 1; iArg < ArgCount; ++iArg)
        {
        if(strcmp(Args[iArg], "-d") == 0)
            Debug = true;
        else
            Result.push_back(Args[iArg]);
        }
    return Result;
    }


class   Columnator
    {
public:
    Columnator(FILE* Output_) : Output(Output_), Column(0), Offset(0) {};
//    void    Output(const char* Str);
    void    PutComment(const char* Comment);
    void    PutQuotedChar(int C);
    void    PutChar(int C, int Rep=1);
    void    PutStr(const char* Str);
    void    PutQuotedStr(const char* Str);
    void    PutQuotedStr(string Str) { PutQuotedStr(Str.c_str()); }
    void    PutString(const string& Str);
    int     GetOffset() { return Offset; }
    void    EndLine();
private:
    enum    {RIGHTCOL=68, INITINDENT=4, ITEMWIDTH=8};
    FILE*   Output;
    int     Column, Offset;
    bool    NeedComma;
    };

void    Columnator::PutString(const string& Str)
    {
    for(unsigned char C : Str)
        PutQuotedChar(C);
    }
void Columnator::EndLine()
    {
    if(Column > 0)
        PutChar('\n');
    }

void Columnator::PutComment(const char* Comment)
    {
    EndLine();
    fprintf(Output, "    // %s\n", Comment);
    }

void Columnator::PutStr(const char* Str)
    {
    while(*Str)
        PutChar(*Str++);
    }

void Columnator::PutChar(int C, int Rep)
    {
    while(Rep-- > 0)
        {
        fputc(C, Output);
        if(C == '\n')
            Column  = 0;
        else
            ++Column;
        }
    }

void    Columnator::PutQuotedStr(const char* Str)
    {
    while(*Str)
        PutQuotedChar(*Str++);
    }

/* PutQuotedChar() - output a char as a C++ character literal.
 */
void Columnator::PutQuotedChar(int C)
    {
    char    Buffer[16];

    if(Column >= RIGHTCOL)
        EndLine();
    if(Column == 0)     // add initial indent, if needed
        PutChar(' ', INITINDENT);
    else
        PutChar(' ', ITEMWIDTH - (Column-INITINDENT)%ITEMWIDTH);
    PutChar('\'');
    if(isgraph(C) && C != '\\' && C != '\'')
        PutChar(C);
    else if(C == ' ')
        PutChar(C);
    else
        {
        PutChar('\\');
        switch(C)
            {
            case    '\\'    :   PutChar('\\');      break;
            case    '\b'    :   PutChar('b');       break;
            case    '\f'    :   PutChar('f');       break;
            case    '\r'    :   PutChar('r');       break;
            case    '\n'    :   PutChar('n');       break;
            case    '\t'    :   PutChar('t');       break;
            case    '\0'    :   PutChar('0');       break;
            case    '\''    :   PutChar('\'');      break;
            default :
                sprintf(Buffer, "x%02X", C&0x00FF);
                PutStr(Buffer);
            }
        }
    PutChar('\'');
    PutChar(',');

    ++Offset;
    }

void    Usage()
    {
    fprintf(stderr, "Usage: cstr [filename]+ [>output.cpp]\n");
    exit(EXIT_FAILURE);
    }

string LoadFile(const string& Filename)
    {
    string Contents;
    char Buffer[4096];
    auto Input = fopen(Filename.c_str(), "r");

    if(Input == NULL)
        {
        fprintf(stderr, "Can't open '%s' for reading!\n", Filename.c_str());
        Usage();
        }

    size_t Count;
    while((Count = fread(Buffer, 1, sizeof(Buffer), Input)) != 0)
        Contents.append(Buffer, Count);

    auto ReadFailed = ferror(Input);
    fclose(Input);
    if(ReadFailed)
        {
        fprintf(stderr, "Can't read '%s'!\n", Filename.c_str());
        Usage();
        }

    size_t LineNumber = 1;
    for(char C : Contents)
        {
        if(C == '\0')
            {
            fprintf(stderr, "NUL byte found in '%s' on line %zu!\n",
                Filename.c_str(), LineNumber);
            Usage();
            }
        if(C == '\n')
            ++LineNumber;
        }
    return Contents;
    }

void ExcludeUnitTests(string& Source)
    {
    const string Marker = "---[=[UNIT_TESTS";

    for(size_t LineStart = 0; LineStart < Source.size();)
        {
        if(Source.compare(LineStart, Marker.size(), Marker) == 0)
            Source.erase(LineStart, 1);
        auto Newline = Source.find('\n', LineStart);
        if(Newline == string::npos)
            break;
        LineStart = Newline+1;
        }
    }

string CompileString(const string& Source, const string& Filename)
    {
    auto Lua = luaL_newstate();
    assert(Lua != NULL);

    auto ChunkName = "@" + Filename;
    if(luaL_loadbuffer(Lua, Source.data(), Source.size(), ChunkName.c_str()) != 0)
        {
        fprintf(stderr, "Can't compile '%s': %s\n", Filename.c_str(),
            lua_tostring(Lua, -1));
        lua_close(Lua);
        Usage();
        }

    string Bytecode;
    auto Writer = [](lua_State*, const void* Data, size_t Size, void* Result)
        {
        static_cast<string*>(Result)->append(static_cast<const char*>(Data), Size);
        return 0;
        };
    auto DumpResult = lua_dump(Lua, Writer, &Bytecode);
    assert(DumpResult == 0);

    lua_close(Lua);
    return Bytecode;
    }

const char* GetFuncText = R"END(
char* CSTRGet(const char* filename)
    {
    char* result = 0;

    if(filename && *filename != '\0')
        {
        size_t iname = 0;
        for(iname=0; iname < sizeof(FileIndex)/sizeof(*FileIndex); ++iname)
            if(!strcmp(filename, FileIndex[iname]))
                {
                result = FileIndex[iname];
                break;
                }
        }
    else
        result = FileIndex[0];
    if(result)   // skip over filename
        result = strchr(result, '\0')+1;
    return result;
    }

const char* CSTRGetCompiled(const char* filename, size_t* size)
    {
    char* result = 0;
    size_t iname = 0;

    *size = 0;
    if(filename && *filename != '\0')
        {
        for(iname=0; iname < sizeof(FileIndex)/sizeof(*FileIndex); ++iname)
            if(!strcmp(filename, FileIndex[iname]))
                {
                result = FileIndex[iname];
                break;
                }
        }
    else
        result = FileIndex[0];
    if(result)
        {
        result = strchr(result, '\0')+1;  // skip over filename
        result = strchr(result, '\0')+1;  // skip over source
        char* end = iname+1 < sizeof(FileIndex)/sizeof(*FileIndex)
            ? FileIndex[iname+1] : FileData+sizeof(FileData);
        *size = end-result;
        if(*size == 0)
            result = 0;
        }
    return result;
    }

)END";


int     main(int ArgCount, char**Args)
    {
    FILE*           Output  = stdout;
    vector<int>     Offsets;
    vector<string>  Names;
    Columnator      Dest(Output);
    auto            InputNames = ParseCommandLine(ArgCount, Args);
    
    if(InputNames.empty())
        Usage();

    fprintf(Output, "/* machine generated -- do not edit!\n");
    fprintf(Output, " * \n");
    fprintf(Output, " * ");
    for(auto iArg = 0; iArg < ArgCount; ++iArg)
        fprintf(Output, " %s", Args[iArg]);
    fprintf(Output, "\n */\n\n");
    fprintf(Output, "%s",R"(
#ifdef __cplusplus
#include <cstring>
#else
#include <string.h>
#endif
)");

    fprintf(Output, "static char FileData[] =\n    {\n");

    for(const auto& InputName : InputNames)
        {
        auto Contents = LoadFile(InputName);
        auto IsLua = fs::path(InputName).extension() == ".lua";
        if(IsLua && !Debug)
            ExcludeUnitTests(Contents);
//            string simpleName {fs::path(InputName).filename().u8string()};
        string simpleName {fs::path(InputName).filename()};
        // fprintf(stderr, "name='%s'\n", simpleName.c_str());
        // remember filename and its offset within big array.
        Names.push_back(simpleName);
        Offsets.push_back(Dest.GetOffset());

        Dest.PutComment(InputName.c_str());
        Dest.PutQuotedStr(simpleName);
        Dest.PutQuotedChar('\0');
        Dest.PutString(Contents);
        Dest.PutQuotedChar('\0');
        if(IsLua)
            Dest.PutString(CompileString(Contents, InputName));
        Dest.EndLine();
        }
    fprintf(Output, "    };\n");
    fprintf(Output, "char*  FileIndex[%zd] =\n    {\n", Names.size());
    for(unsigned i=0; i < Names.size(); ++i)
        {
        fprintf(Output, "    &FileData[%6d], // %s\n", Offsets[i], Names[i].c_str());
        }
    fprintf(Output, "    };\n");
    fprintf(Output, "%s", GetFuncText);

    exit(EXIT_SUCCESS);
    }
