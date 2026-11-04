/* File input for logxform.goose: os.goose only reads whole files, and the SPEC streams a file in 1 MiB
   blocks with read(2). Nothing but opening, reading and closing is done here. */
#include "goose.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { const uint8_t *data; int64_t len; } lx_slice;

/* extern fn lx_open(path: const u8[:]) -> i64;  a file descriptor, or -1 */
int64_t lx_open(lx_slice path) {
    char *p = malloc((size_t)path.len + 1);
    if (!p) return -1;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    int fd = open(p, O_RDONLY);
    free(p);
    return fd;
}

/* extern fn lx_read(fd: i64, out: u8[>..]&, n: i64) -> i64;
   One read(2) of up to n bytes, appended to out: like gs_bld_append, the bytes go at the top of the
   resizable's data stack, here written there by read(2) itself instead of copied. 0 at the end, -1 on error. */
int64_t lx_read(int64_t fd, gs_rref out, int64_t n) {
    ssize_t r;
    do { r = read((int)fd, out.stk->top, (size_t)n); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    out.stk->top += r;
    out.hdr->len += r;
    return (int64_t)r;
}

/* extern fn lx_close(fd: i64); */
void lx_close(int64_t fd) { close((int)fd); }
