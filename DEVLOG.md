# Development log

Time spent per session, for the "development hours per version" metric in CLAUDE.md.
Times are wall clock from the session's tool timestamps.

| Date | Session | Version | Start | End | Minutes | Notes |
|---|---|---|---|---|---|---|
| 2026-11-01 | Goose spike | goose | 12:34 | 12:45 | 11 | hello, serialization + tampering, threads, C directory walk; see `spike/FINDINGS.md` |
| 2026-11-01 | Goose v1 | goose | 12:45 | 12:48 | 3 | `goose/symidx.goose` compiled first try; checksums match on S and M; corruption fuzz: exit 0/1 only |
| 2026-11-01 | Load profiling, L run | goose | 12:54 | 13:00 | 6 | `SYMIDX_PROFILE`; page faults + verify dominate; prefault and layout options measured, not applied; L checksum matches |
| 2026-11-01 | Issue draft, SQLite baseline | - | 13:00 | 13:03 | 3 | `spike/ISSUE_from_bytes_append.md` (root cause: stale register-cached length); SQLite matches checksum; ctags waits on install |
| 2026-11-01 | rust-idiomatic v1 | rust-idiomatic | 13:08 | 13:10 | 2 | serde + bincode 1.3 + rayon; checksums match on S and M. Pitfall: plain `Vec<u8>` deserialized byte by byte (M load ~40 ms) until `serde_bytes` (~13 ms) |
| 2026-11-01 | rust-expert v1 | rust-expert | 13:11 | 13:14 | 3 | FxHash interning, string arenas + sentinel offset tables, 8-byte occs, rkyv over mmap + explicit validation; checksums match on S and M |
