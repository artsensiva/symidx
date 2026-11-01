# Development log

Time spent per session, for the "development hours per version" metric in CLAUDE.md.
Times are wall clock from the session's tool timestamps. All versions were written by the same AI agent,
so the minutes measure agent effort and compare versions with each other, not human hours.

| Date | Session | Version | Start | End | Minutes | Notes |
|---|---|---|---|---|---|---|
| 2026-11-01 | Goose spike | goose | 12:34 | 12:45 | 11 | hello, serialization + tampering, threads, C directory walk; see `spike/FINDINGS.md` |
| 2026-11-01 | Goose v1 | goose | 12:45 | 12:48 | 3 | `goose/symidx.goose` compiled first try; checksums match on S and M; corruption fuzz: exit 0/1 only |
| 2026-11-01 | Load profiling, L run | goose | 12:54 | 13:00 | 6 | `SYMIDX_PROFILE`; page faults + verify dominate; prefault and layout options measured, not applied; L checksum matches |
| 2026-11-01 | Issue draft, SQLite baseline | - | 13:00 | 13:03 | 3 | `spike/ISSUE_from_bytes_append.md` (root cause: stale register-cached length); SQLite matches checksum; ctags waits on install |
| 2026-11-01 | rust-idiomatic v1 | rust-idiomatic | 13:08 | 13:10 | 2 | serde + bincode 1.3 + rayon; checksums match on S and M. Pitfall: plain `Vec<u8>` deserialized byte by byte (M load ~40 ms) until `serde_bytes` (~13 ms) |
| 2026-11-01 | rust-expert v1 | rust-expert | 13:11 | 13:12 | 1 | FxHash interning, string arenas + sentinel offset tables, 8-byte occs, rkyv over mmap + explicit validation; checksums match on S and M |
| 2026-11-01 | Full S/M/L run, README | - | 13:12 | 13:15 | 3 | all three match on S/M/L; README results, assessment, plan, known issues |
| 2026-11-01 | Fairness, serving memory, layout D′ | all | 13:19 | 13:25 | 6 | filed aardappel/goose#177; serving-RSS columns; streaming rust-expert build (batch kept); goose writes frames without an image copy; D′ measured, not adopted |
| 2026-11-01 | Final S/M/L + baselines, report | - | 13:25 | 13:39 | 14 | all checksums match; ctags + SQLite baselines; `bench/REPORT.md`: kill criterion triggered, recommend Rust |
