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
| 2026-11-01 | Phase 1 close, lazy validation, Phase 2 plan | rust-expert, docs | 13:48 | 13:53 | 5 | tag `v0.1-experiment`, MIT license; segmented-validation experiment (L selective RSS 43→12 MB); draft zero-copy issue; `docs/PHASE2.md` |
| 2026-11-01 | Reproducible benchmarks across machines | bench, CI | 19:44 | 19:57 | 13 | env.txt capture, `bench/check-machine.sh`, PIN=, portable scripts (macOS), sha256-pinned Goose fetch, `bench/check-sums.sh`; CI on ubuntu + macOS green (2nd run; 1st was green with empty macOS time columns, hyperfine 2.0 JSON) |
| 2026-11-03 | Finalize: cold cache, report, release | bench, CI, docs | 13:53 | 14:14 | 21 | CI cold-cache runs (fixed COLD=1: hyperfine 1.x ran --prepare without a shell); REPORT criterion refinement + cross-platform/cold tables; README TL;DR; consistency pass; filed aardappel/goose#221; v1.0 release |
| 2026-11-03 | Opportunity analysis, README, v1.1 | docs | 14:39 | 14:51 | 12 | `docs/GOOSE_OPPORTUNITIES.md` (11 candidates, 3 strong, web-sourced); README expanded with CI badge; CHANGELOG; .gitignore covers spike binaries; consistency pass; v1.1 |
| 2026-11-03 | Experiment 2: CI housekeeping, SPEC, corpus, reference | CI, logxform | 17:23 | 17:37 | 14 | actions on Node 24, runners pinned; pre-registered SPEC committed at 17:35 before any code; Loghub fetch with sha256s; ref.py |
| 2026-11-03 | Experiment 2: implementations | goose, rust-arena, rust-idiomatic | 17:37 | 17:52 | 15 | goose 4 min (correct on first run), rust-arena 5, rust-idiomatic 4; edge-case corpus caught a missing check in rust-idiomatic. A usage-limit pause followed, until 18:53 |
| 2026-11-03 | Experiment 2: harness, CI, audit, fixes, measurement, report, v1.2 | logxform, docs | 18:53 | 20:28 | 95 | run.sh, check-sums.sh; fairness audit by a separate agent (25 min); fixes both ways, amendment A1 (rust-arena v2, 6 min); local S/M/L, pre-audit, layout spread; REPORT; verdict: not met |
| 2026-11-03 | Audit prep, profiling, build flags, improvement plan, v1.2.1 | docs, logxform | 21:05 | 21:30 | 25 | excluding the CI wait before the release. AUDIT.md, CLAIMS.md; build-flag row (manual bitcode LTO: no lld or gold); perf blocked from this shell (paranoid 4), so phase timers and an ablation; GOOSE_IMPROVEMENT_PLAN.md; draft goose#221 comment (not posted); repomix bundle on v1.2.1 |
| 2026-11-04 | Experiment 3: Goose from source, patch 1, patch 2, tests | goose patches | ≈00:25 | 01:12 | ≈47 | times approximate, from timestamps seen in the session; a measurement bug (RSS floor) was found and fixed |
| 2026-11-04 | Experiment 3: layouts, Rust stream mode, huge-page switch | goose patches, rust | 01:15 | 02:10 | ≈55 | includes two matrix runs; a hidden copy was found from an impossible RSS |
| 2026-11-04 | Experiment 4: Vector, Fluent Bit | tools | ≈02:25 | 04:15 | ≈110 | about 80 min is the unattended run |
| 2026-11-04 | Experiment 5: F1, F2, F3, fairness check | goose patches | ≈04:20 | 05:25 | ≈65 | about 35 min is unattended runs |
| 2026-11-04 | Consolidated run, report, docs | docs | 05:28 | 07:34 | ≈126 | about 120 min is the unattended run |
| 2026-11-04 | Experiment 6 measurements, documentation for a second review | parallelism, docs | ≈07:35 | 08:04 | — | includes unattended runs |
| 2026-11-04 | Independent review: F3 fix, corrections, fail-closed checks, pilot spec | goose patches, docs, harness | ≈08:50 | 09:35 | — | times approximate; includes unattended runs |
