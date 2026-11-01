# Development log

Time spent per session, for the "development hours per version" metric in CLAUDE.md.
Times are wall clock from the session's tool timestamps.

| Date | Session | Version | Start | End | Minutes | Notes |
|---|---|---|---|---|---|---|
| 2026-11-01 | Goose spike | goose | 12:34 | 12:45 | 11 | hello, serialization + tampering, threads, C directory walk; see `spike/FINDINGS.md` |
| 2026-11-01 | Goose v1 | goose | 12:45 | 12:48 | 3 | `goose/symidx.goose` compiled first try; checksums match on S and M; corruption fuzz: exit 0/1 only |
| 2026-11-01 | Load profiling, L run | goose | 12:54 | 13:00 | 6 | `SYMIDX_PROFILE`; page faults + verify dominate; prefault and layout options measured, not applied; L checksum matches |
