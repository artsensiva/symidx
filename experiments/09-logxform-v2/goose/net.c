/* System calls for logxform.goose: sockets, positional file I/O, signals. Goose has no socket API, and
   its os package has no descriptor-level I/O. No logic beyond calling the system lives here. */
#define _GNU_SOURCE
#include "goose.h"
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { const uint8_t *data; int64_t len; } lx_slice;

static char *cstr(lx_slice s) {
    char *p = malloc((size_t)s.len + 1);
    if (!p) return NULL;
    memcpy(p, s.data, (size_t)s.len);
    p[s.len] = 0;
    return p;
}

static volatile sig_atomic_t term_flag, hup_flag;
static void on_term(int s) { (void)s; term_flag = 1; }
static void on_hup(int s) { (void)s; hup_flag = 1; }
void lx_signals(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGHUP, on_hup);
}
uint8_t lx_term(void) { return term_flag != 0; }
uint8_t lx_hup_take(void) { uint8_t h = hup_flag != 0; hup_flag = 0; return h; }

int64_t lx_listen(int64_t port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 4096) < 0) { close(fd); return -1; }
    return fd;
}

int64_t lx_poll(int64_t fd, int64_t ms) {
    struct pollfd p = { (int)fd, POLLIN, 0 };
    int r;
    do { r = poll(&p, 1, (int)ms); } while (r < 0 && errno == EINTR && !term_flag);
    return r;
}

/* A connection, -1 if none arrived in ms, -2 on error. */
int64_t lx_accept(int64_t fd, int64_t ms) {
    if (lx_poll(fd, ms) <= 0) return -1;
    int c = accept4((int)fd, NULL, NULL, SOCK_CLOEXEC);
    if (c < 0) return errno == EINTR || errno == EAGAIN ? -1 : -2;
    int on = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
    return c;
}

/* The peer's port, with its address appended to host. */
int64_t lx_peer(int64_t fd, gs_rref host) {
    struct sockaddr_in a;
    socklen_t n = sizeof a;
    char t[64];
    if (getpeername((int)fd, (struct sockaddr *)&a, &n) < 0 || !inet_ntop(AF_INET, &a.sin_addr, t, sizeof t)) return 0;
    gs_bld_append(host, t, (int64_t)strlen(t));
    return ntohs(a.sin_port);
}

int64_t lx_connect(lx_slice host, int64_t port) {
    char *h = cstr(host), ps[16];
    if (!h) return -1;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int i = 0, d = 10000;
    for (; d > 1 && port / d == 0; d /= 10) {}
    for (; d >= 1; d /= 10) ps[i++] = (char)('0' + (port / d) % 10);
    ps[i] = 0;
    int e = getaddrinfo(h, ps, &hints, &res);
    free(h);
    if (e != 0 || !res) return -1;
    int fd = socket(res->ai_family, res->ai_socktype | SOCK_CLOEXEC, 0);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        if (fd >= 0) close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    int on = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
    return fd;
}

int64_t lx_read(int64_t fd, gs_rref out, int64_t n) {
    ssize_t r;
    do { r = read((int)fd, out.stk->top, (size_t)n); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    out.stk->top += r;
    out.hdr->len += r;
    return (int64_t)r;
}

int64_t lx_pread(int64_t fd, gs_rref out, int64_t n, int64_t off) {
    ssize_t r;
    do { r = pread((int)fd, out.stk->top, (size_t)n, (off_t)off); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    out.stk->top += r;
    out.hdr->len += r;
    return (int64_t)r;
}

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

void lx_close(int64_t fd) { close((int)fd); }

/* Files: read and append, created if missing. */
int64_t lx_open_log(lx_slice path) {
    char *p = cstr(path);
    if (!p) return -1;
    int fd = open(p, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    free(p);
    return fd;
}
int64_t lx_open_rw(lx_slice path) {
    char *p = cstr(path);
    if (!p) return -1;
    int fd = open(p, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    free(p);
    return fd;
}
int64_t lx_open_ro(lx_slice path) {
    char *p = cstr(path);
    if (!p) return -1;
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    free(p);
    return fd;
}
int64_t lx_size(int64_t fd) { struct stat s; return fstat((int)fd, &s) < 0 ? -1 : (int64_t)s.st_size; }
int64_t lx_links(int64_t fd) { struct stat s; return fstat((int)fd, &s) < 0 ? 0 : (int64_t)s.st_nlink; }
int64_t lx_inode(lx_slice path) {
    char *p = cstr(path);
    if (!p) return -1;
    struct stat s;
    int r = stat(p, &s);
    free(p);
    return r < 0 ? -1 : (int64_t)s.st_ino;
}
uint8_t lx_sync(int64_t fd) { return fdatasync((int)fd) == 0; }
uint8_t lx_truncate(int64_t fd) { return ftruncate((int)fd, 0) == 0; }
/* A number kept in the first 8 bytes of a small file. */
int64_t lx_get8(int64_t fd) {
    int64_t v = 0;
    return pread((int)fd, &v, 8, 0) == 8 ? v : 0;
}
uint8_t lx_put8(int64_t fd, int64_t v) { return pwrite((int)fd, &v, 8, 0) == 8; }
