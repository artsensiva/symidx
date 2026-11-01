# symidx behavior specification

All implementations (`goose/`, `rust-idiomatic/`, `rust-expert/`) must follow these rules
byte for byte: the reference is `bench/ref.py`, the check is `bench/run.sh` (comparing the sha256 of `find ""` output).

## Walk
- Recursively from `<dir>`; only **regular files** whose name ends in `.py` are taken.
- Symlinks (to files and to directories) are neither opened nor followed.
- The file path in the index is relative to `<dir>`, with `/` as separator and no leading `./`.

## Line parsing
A file is read as bytes and split on `\n` (line numbers start at 1). For each line:
1. Skip leading spaces and tabs (`0x20`, `0x09`).
2. If `async` follows, followed by ≥1 space/tab, skip those too.
3. Keyword: `def` → kind `def`, `class` → kind `class`; otherwise the line is not a symbol.
   The keyword must be followed by ≥1 space/tab; skip them.
4. The name is the maximal run of bytes from `[A-Za-z0-9_]` or `>= 0x80`.
   An empty name → the line is not a symbol.

Strings and comments are not recognized: `def x` inside a docstring also counts as a symbol.
`async` not followed by `def` (e.g. `async class`) is not a symbol.

## String storage (mandatory for all implementations)
- **Symbol names are interned**: in the image each unique name is stored exactly once,
  and a symbol record refers to it. Same for paths: a file table, and a symbol refers to its file.
- Reason: L is 31 copies of M, so name repeats there are artificial. In M, interning
  reduces name bytes by 1.28×, in L by 39.7×. If only one implementation interns,
  the difference in image size and RAM would be an artifact of the corpus, not of the language.
- The checksum does not verify this; the rule is enforced by code review. In the report the main
  memory comparison is done on M, and L serves as a stress test.

## Output
- `symidx build <dir> -o <img>` — stdout: `symbols=<N> files=<F>`.
- `symidx load <img>` — stdout: `symbols=<N> load_ms=<float>`.
- `symidx find <img> <prefix>` — all symbols whose name starts with `<prefix>` (bytewise),
  one per line: `name\tkind\tfile\tline\n`.
  Order: name (bytewise), then file (bytewise), then line (numeric).
  An empty prefix outputs the whole index — the checksum is computed from it.
