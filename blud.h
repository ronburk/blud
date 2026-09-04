#ifndef BLUD_H_
#define BLUD_H_

#include <stdint.h>

// Absolute timestamp as seconds and nanoseconds since
// 1970-01-01 00:00:00 UTC, the Unix epoch.
// OS-specific time formats and epochs are converted to this representation.
typedef struct BLUD_TIMESTAMP {
    int64_t  seconds;
    int32_t  nanoseconds;
} BLUD_TIMESTAMP;

#endif // BLUD_H_
