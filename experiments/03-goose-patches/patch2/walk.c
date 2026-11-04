/* Directory listing for symidx.goose: os.goose's list_dir and is_dir
   follow symlinks, and bench/SPEC.md says a walk must not. */
#include "goose.h"
#include <dirent.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct { const uint8_t *data; int64_t len; } walk_slice;

/* extern fn list_dir_typed(path: const u8[:], out: u8[>..]&) -> bool;
   Appends one line per entry: a type byte ('d' directory, 'f' regular file,
   'o' anything else, symlinks included), the name, '\n'. Unsorted. */
bool list_dir_typed(walk_slice path, gs_rref out) {
    char *p = malloc((size_t)path.len + 1);
    if (!p) return false;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    DIR *d = opendir(p);
    if (!d) { free(p); return false; }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        const char *n = e->d_name;
        if (n[0] == '.' && (n[1] == 0 || (n[1] == '.' && n[2] == 0))) continue;
        char t;
        if (e->d_type == DT_DIR) t = 'd';
        else if (e->d_type == DT_REG) t = 'f';
        else if (e->d_type != DT_UNKNOWN) t = 'o';
        else {
            /* Filesystems that do not fill d_type: ask lstat, which does not follow links. */
            size_t pl = strlen(p), nl = strlen(n);
            char *full = malloc(pl + nl + 2);
            struct stat st;
            t = 'o';
            if (full) {
                memcpy(full, p, pl); full[pl] = '/'; memcpy(full + pl + 1, n, nl + 1);
                if (lstat(full, &st) == 0) t = S_ISDIR(st.st_mode) ? 'd' : S_ISREG(st.st_mode) ? 'f' : 'o';
                free(full);
            }
        }
        gs_bld_append(out, &t, 1);
        gs_bld_append(out, n, (int64_t)strlen(n));
        gs_bld_append(out, "\n", 1);
    }
    closedir(d);
    free(p);
    return true;
}
