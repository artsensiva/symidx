/* Spike: pre-fault the memory a Goose array is about to grow into, in one
   syscall rather than one page fault per 4 KB page. */
#include "goose.h"
#include <stdbool.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>

typedef struct { const uint8_t *data; int64_t len; } pf_slice;

#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif

/* extern fn prefault(at: const u8[:], bytes: i64, huge: bool) -> i32; at is an empty
   array's view, i.e. its stack top. Returns madvise's result (0 or -1). */
int32_t prefault(pf_slice at, int64_t bytes, bool huge) {
    uintptr_t lo = (uintptr_t)at.data & ~(uintptr_t)4095;
    uintptr_t hi = ((uintptr_t)at.data + (uintptr_t)bytes + 4095) & ~(uintptr_t)4095;
    if (huge) madvise((void *)lo, hi - lo, MADV_HUGEPAGE);
    return (int32_t)madvise((void *)lo, hi - lo, MADV_POPULATE_WRITE);
}

/* extern fn file_size(path: const u8[:]) -> i64; -1 on error. */
int64_t file_size(pf_slice path) {
    char buf[4096];
    if (path.len >= (int64_t)sizeof buf) return -1;
    for (int64_t i = 0; i < path.len; i++) buf[i] = (char)path.data[i];
    buf[path.len] = 0;
    struct stat st;
    return stat(buf, &st) == 0 ? (int64_t)st.st_size : -1;
}
