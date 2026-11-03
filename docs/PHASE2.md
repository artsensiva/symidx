# Phase 2 plan: an instant-start code navigation index for AI coding agents

Status: **draft, not started, pending decision.** Nothing here is implemented.

## Goal

An MCP server that gives coding agents precise, fast symbol navigation in large monorepos, so they stop
spending tool calls and context on `grep` round-trips. It should start instantly (load an index image in
milliseconds rather than re-indexing) and stay small in memory, as Phase 1's rust-expert does.

MCP tools, first cut:

| Tool | Input | Output |
|---|---|---|
| `search_symbols` | name or prefix, optional kind/path filter, limit | definitions: name, kind, file, line, container (class) |
| `find_definition` | a symbol name, or file + line + column of a use | the defining location(s), ranked |
| `find_references` | a definition (file + line), or a name | reference locations, grouped by file, with a one-line context each |
| `index_status` | – | files indexed, staleness, last update |

Results are token-budgeted: capped and grouped, with a count of what was left out, since the client is an LLM.

## Design (from Phase 1's rust-expert)

- **Parsing:** tree-sitter, with each grammar's `tags.scm` queries (definitions and references) plus our
  own queries where those are thin. Python first, then TypeScript/TSX. Parsing is per file, in parallel,
  and streams into the builder through a bounded channel (Phase 1's fairness lesson).
- **Index image:** names and paths interned into arenas; definitions grouped by name; references stored
  as (name, file, line, column) occurrences grouped by name, plus per-file containers for scoping. rkyv
  over an mmap, eager validation by default; segmented validation only if SPEC is amended (Phase 1 experiment).
- **Resolution, in stages:**
  1. by name, as Phase 1 did;
  2. scope-aware within a file: locals shadow globals, and methods are qualified by their class;
  3. cross-file through imports (`from a.b import c`, relative imports, `__init__` re-exports; for TS,
     ES imports and `tsconfig` paths).

  No type inference: `x.method()` falls back to name matching, and results say so (exact vs. heuristic).
- **Incremental updates:** a base image plus an in-memory overlay for changed files. Each file's
  contribution is replaced as a unit, and tombstones hide its old entries in the base. Changes are found
  by mtime and content hash, with optional file watching. The overlay is compacted into a new base image
  in the background past a size threshold. Target: an edited file is queryable again in under 50 ms.
- **Packaging:** one static binary, `symidx serve --repo <dir>` (MCP over stdio), and `symidx build`.

## Milestones

| | Scope | Exit check |
|---|---|---|
| M1 | Python definitions via tree-sitter, `search_symbols` and `find_definition` by name, MCP stdio | the Phase 1 checksum corpus still builds; MCP smoke test with a real agent client |
| M2 | references and in-file scoping, `find_references`, token-budgeted output | accuracy measured against the oracle (below) |
| M3 | import resolution, incremental overlay, file watching | edit-to-queryable latency measured |
| M4 | TypeScript/TSX | the same metrics on a TS monorepo |
| M5 | agent-level evaluation, report with the kill criterion | `docs/PHASE2_REPORT.md` |

## Competitors to benchmark against

- **ripgrep, as agents use it today:** the agent's own `grep`/`rg` loop. This is the real incumbent, and the
  agent-level metric below is measured against it.
- **universal-ctags + readtags:** definitions only, no references. The Phase 1 baseline.
- **pyright `workspace/symbol`** (and TS `tsserver` navto): accurate, but slow to start on large repos.
  Driven through a small LSP client.
- **Serena** (an MCP server over language servers): the closest existing product. It answers the "why not
  wrap an LSP?" question directly.
- **Sourcegraph zoekt** (trigram code search) and **SCIP** (`scip-python`/`scip-typescript` indexes). If
  their setup is feasible on this machine, they serve as the accuracy oracle and as a precomputed-index
  competitor.

## Corpora

Phase 1's M and L for scale. One real Python monorepo and one real TS monorepo (candidates: a large
open-source Python service, and `microsoft/vscode` for TS), each pinned to a tag. An agent task set: about
50 navigation questions per repo ("where is X defined", "who calls Y", "what implements Z"), with answers
checked against the oracle.

## Metrics

| Metric | How |
|---|---|
| Cold start to first answer | process start → first MCP response, warm and cold page cache |
| Query latency | p50/p99 per tool over the task set |
| Serving memory | peak RSS while answering the task set (the Phase 1 metric) |
| Index size, full build time and RAM | as in Phase 1 |
| Incremental update | latency from a file edit until queries reflect it; overlay RSS growth |
| Accuracy | precision and recall of `find_definition` and `find_references` against SCIP or pyright on a sample |
| Agent-level | on the task set, with one fixed agent and model: success rate, tool calls, and context tokens, with vs. without the server (ripgrep only) |

## Kill criterion

At M5, stop the product effort if **neither** holds:
1. **Agent value:** on the task set, the server cuts agent context tokens or tool calls by ≥ 2× against
   ripgrep alone, at an equal or better success rate.
2. **Tool value:** cold start to first answer is ≥ 10× faster than pyright/tsserver workspace symbols,
   at ≥ 90% of their `find_definition` precision and recall.

An earlier checkpoint at M2: if reference accuracy is below 70% precision against the oracle on Python,
re-plan resolution before adding TypeScript.

## Open questions for you

1. **Thresholds:** are 2× (agent) and 10× / 90% (tool) the right bars? Should agent value alone be enough?
2. **Agent setup:** which agent and model for the agent-level evaluation, and is a paid API budget available for it?
3. **Repos:** which real monorepos? A private one of yours would be the most honest test, if that's possible.
4. **Scope of "references":** is name-plus-import resolution enough, or is type-aware resolution (calls on
   `self`/instances) required to be useful? The latter pulls us toward wrapping pyright, which changes the design.
5. **Validation:** amend SPEC to allow segmented validation (3.5× less serving RSS on selective queries,
   Phase 1 experiment), or keep eager?
6. **Packaging and licensing:** MCP over stdio only, or also an HTTP transport? Is MIT fine for the product too?
7. **Repo:** continue in this repository (Phase 1 released as v1.0), or start a new one?
