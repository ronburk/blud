#ifndef CSTR_H_
#define CSTR_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

extern char* CSTRGet(const char* filename);
extern const char* CSTRGetCompiled(const char* filename, size_t* size);

#ifdef __cplusplus
}
#endif

#endif
