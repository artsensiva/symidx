/* File I/O for sanitize.goose. os.goose reads whole files and has no descriptor-level writes, and this tool needs streaming input,
   stdin, and write errors it can report. Nothing but opening, reading, writing and closing is done here. */
#include "goose.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { const uint8_t *data; int64_t len; } lx_slice;

static int lx_open_mode(lx_slice path, int flags) {
    char *p = malloc((size_t)path.len + 1);
    if (!p) return -1;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    int fd = open(p, flags, 0666);
    free(p);
    return fd;
}

/* extern fn lx_open(path: const u8[:]) -> i64;  a file descriptor, or -1 */
int64_t lx_open(lx_slice path) { return lx_open_mode(path, O_RDONLY); }

/* extern fn lx_create(path: const u8[:]) -> i64;  created or truncated for writing; a file descriptor, or -1 */
int64_t lx_create(lx_slice path) { return lx_open_mode(path, O_WRONLY | O_CREAT | O_TRUNC); }

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

/* extern fn lx_write(fd: i64, data: const u8[:]) -> bool;  all of it, or false */
uint8_t lx_write(int64_t fd, lx_slice data) {
    int64_t done = 0;
    while (done < data.len) {
        ssize_t w = write((int)fd, data.data + done, (size_t)(data.len - done));
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return 0;
        done += w;
    }
    return 1;
}

/* extern fn lx_close(fd: i64) -> bool; */
uint8_t lx_close(int64_t fd) { return close((int)fd) == 0; }

/* extern fn lx_ignore_sigpipe();  a closed pipe becomes a write error, which the tool reports, not a silent death */
void lx_ignore_sigpipe(void) { signal(SIGPIPE, SIG_IGN); }
