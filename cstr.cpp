/* cstr.c - Utility to transform text file into compilable C array of char.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <vector>
#include <string>
#include <filesystem>
namespace fs = std::filesystem;

using std::vector;
using std::string;


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
    void    PutFile(FILE* Input);
    int     GetOffset() { return Offset; }
    void    EndLine();
private:
    enum    {RIGHTCOL=68, INITINDENT=4, ITEMWIDTH=8};
    FILE*   Output;
    int     Column, Offset;
    bool    NeedComma;
    };

void    Columnator::PutFile(FILE* Input)
    {
    int  C;

    while(( C = fgetc(Input)) != EOF)
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

)END";


int     main(int ArgCount, char**Args)
    {
    FILE*           Output  = stdout;
    vector<int>     Offsets;
    vector<string>  Names;
    Columnator      Dest(Output);
    
    if(ArgCount < 2)
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
#include <cstring.h>
#endif
)");

    fprintf(Output, "static char FileData[] =\n    {\n");

    for(int iArg = 1; iArg < ArgCount; ++iArg)
        {
        auto Input   = fopen(Args[iArg], "r");
        if(Input == NULL)
            {
            fprintf(stderr, "Can't open '%s' for reading!\n", Args[iArg]);
            Usage();
            }
        else
            {
//            string simpleName {fs::path(Args[iArg]).filename().u8string()};
            string simpleName {fs::path(Args[iArg]).filename()};
            fprintf(stderr, "name='%s'\n", simpleName.c_str());
            // remember filename and its offset within big array.
            Names.push_back(simpleName);
            Offsets.push_back(Dest.GetOffset());

            Dest.PutComment(Args[iArg]);
            Dest.PutQuotedStr(simpleName);
            Dest.PutQuotedChar('\0');
            Dest.PutFile(Input);
            Dest.PutQuotedChar('\0');
            Dest.EndLine();
            fclose(Input);
            }
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
