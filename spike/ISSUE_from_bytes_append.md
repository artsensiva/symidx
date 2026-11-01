<!-- Draft, not filed. Title: -->
# from_bytes rejects valid index types into a global grown with `append` (stale length in the verifier)

**Version:** goose v2026.3 release (`goose version`: runtime `4d3da949e563`), Linux x64.
Same result in-process (`goose file.goose`, at `-O0`, `-O2` and `--debug`) and with `goose build` (clang 21, gcc 15).

## Repro

```goose
var bytes: u8[>..] = [];
fn main() {
    bytes.append("abcd");
    let i = 2 as (u32 in bytes);          // the checked cast accepts it
    var b: (u32 in bytes)[>..] = [];
    b.push(i);
    let img = b.to_bytes();               // 4 2 0 0 0
    var rb, bok = from_bytes<(u32 in bytes)[>..]>(img);
    print("from_bytes: ", bok, " len ", rb.len);
}
```

**Observed:** `from_bytes: false len 0`

**Expected:** `from_bytes: true len 1`. Index 2 is below `bytes.len` (4), the image is the one `to_bytes` just
produced, and `from_bytes<T[>..]>(a.to_bytes())` should round-trip (`docs/design/serialization.md` §5).

## Control

The same program, with the global filled by `push` instead of `append`, prints `true`:

```goose
    for c in "abcd" { bytes.push(c); }
```

- An executed `append` breaks it whether it runs before or after `push`es. An `append` in dead code doesn't.
- `u32 upto x` (bound types) fails the same way.
- Index types into a global that was only `push`ed work, including into struct and `i32` arrays.

## Likely cause

In the generated C for `main`, after `append` the global's length lives in a local and is written back to
`GS_GL->bytes_g.len` only at the end of the function:

```c
int64_t t47 = GS_GL->bytes_g.len;
...                                   /* append: */ t47 += t0;
...
int64_t t35 = t32 ? gs_verify_u32x0(t30, t31, NULL) : -1;
...
GS_GL->bytes_g.len = t47;             /* written back at function exit */
```

while the verifier reads the global directly:

```c
static int64_t gs_verify_u32x0(const uint8_t *p, int64_t n, uint8_t *bm) {
    ... if ((uint64_t)v0 >= (uint64_t)GS_GL->bytes_g.len) return -1; ...
}
```

So it checks the index against the stale length, 0. Calls to ordinary Goose functions seem to get the
length written back first: a helper `fn seen() -> i64 { bytes.len }` reads 4. The verifier call doesn't.

## Impact and workaround

A loader that grows a pinned array with `append`, then verifies an image whose index types point into it,
rejects every valid image. Workaround: grow such arrays with `push` only. That costs a per-element loop on
load in place of one `append` (~2% of load time in our case).

Found while building https://github.com/artsensiva/symidx (`spike/bug_from_bytes_append.goose`,
`spike/bug_from_bytes_append_control.goose`).
