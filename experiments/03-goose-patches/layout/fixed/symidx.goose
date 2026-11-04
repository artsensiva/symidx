// Experiment 3, layout `fixed`: every record in the image is fixed-size, so `groups` can be
// binary-searched directly and no in-memory index is needed. Needs the patched compiler (from_file).
// Conforms to bench/SPEC.md: the whole image is verified during load.
//   goose build symidx.goose --cc clang -o symidx

import std;
import os;
import dictionary;

extern fn list_dir_typed(path: const u8[:], out: u8[>..]&) -> bool;

// --- the image ----------------------------------------------------------------
// Five to_bytes frames after the magic: paths, files, names, groups, occs. groups holds one extra
// sentinel: group i's name is names[groups[i].name..groups[i + 1].name], and its occurrences
// occs[groups[i].occ..groups[i + 1].occ]. Occurrences are in (name, file, line) order.

let MAGIC = "SYMIDX3\n";

struct File { lo: u32, hi: u32 }                  // a span of paths, checked by load's pass
struct Occ { file: u32 in files, lk: u32 }        // lk = (line - 1) << 1 | kind (0 def, 1 class): every value is valid
struct Group { name: u32, occ: u32 }              // checked by load's pass

// `files` is pinned by Occ's index type, so it only grows, and only by push.
var paths: u8[>..] = [];
var files: File[>..] = [];
var names: u8[>..] = [];
var groups: Group[>..] = [];
var occs: Occ[>..] = [];

fn fail(msg: u8[:]) {
    write_stderr(str("symidx: ", msg, "\n"));
    exit(1);
}

// --- parsing (workers) ----------------------------------------------------------

struct Job { file: u32, path: u8[] }                        // file = STOP ends a worker
struct Rec { line: u32, kind: u8, name: u8[varint] }
struct Parsed { file: u32, recs: Rec[] }

let STOP: u32 = 0xffffffff;

fn is_ws(c: u8) -> bool { c == ' ' || c == '\t' }
fn is_ident(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c >= 0x80
}

// bench/SPEC.md "Line parsing": the kind (0 def, 1 class, -1 not a symbol) and the name's span.
fn parse_line(s: u8[:]) -> i64, i64, i64 {
    var i = 0;
    while i < s.len && is_ws(s[i]) { i++; }
    if starts_with(s[i..], "async") && i + 5 < s.len && is_ws(s[i + 5]) {
        i += 5;
        while i < s.len && is_ws(s[i]) { i++; }
    }
    var kind = -1;
    var j = i;
    if starts_with(s[i..], "def") { kind = 0; j = i + 3; }
    else if starts_with(s[i..], "class") { kind = 1; j = i + 5; }
    guard kind >= 0 && j < s.len && is_ws(s[j]) else { return -1, 0, 0; }
    while j < s.len && is_ws(s[j]) { j++; }
    var k = j;
    while k < s.len && is_ident(s[k]) { k++; }
    guard k > j else { return -1, 0, 0; }
    return kind, j, k;
}

fn parse_file(text: u8[:]) -> Rec[>..] {
    var recs: Rec[>..] = [];
    var line: u32 = 1;
    var start = 0;
    for i in text.len + 1 {
        if i == text.len || text[i] == '\n' {
            let kind, lo, hi = parse_line(text[start..i]);
            if kind >= 0 { recs.push(Rec { line: line, kind: kind as! u8, name: text[start + lo..start + hi] }); }
            line += 1;
            start = i + 1;
        }
    }
    return recs;
}

thread_fn worker() {
    var text: u8[>..] = [];
    loop {
        let job = qget<Job>();
        guard job.file != STOP else { break; }
        text.clear();
        // An unreadable file yields no symbols rather than a dead worker the main thread waits on.
        if read_file(job.path, text) { qput(Parsed { file: job.file, recs: parse_file(text) }); }
        else { qput(Parsed { file: job.file, recs: [] }); }
    }
}

// --- build ------------------------------------------------------------------------

struct Span { lo: i64, hi: i64 }
struct Sym { name: u32, file: u32, line: u32, kind: u8 }

// Every regular *.py file under root, as relative '/'-separated paths in text.
// Breadth-first: directories are spans of their own buffer, since a stack of
// strings would need variable-size elements in a grow-shrink array.
fn walk(root: u8[:], text: u8[>..]&, out: Span[>..]&) {
    var dir_text: u8[>..] = [];
    var dirs: Span[>..] = [];
    dirs.push(Span { lo: 0, hi: 0 });
    var listing: u8[>..] = [];
    var full: u8[>..] = [];
    var next = 0;
    while next < dirs.len {
        let d = dirs[next];
        next++;
        let rel = dir_text[d.lo..d.hi];
        full.clear();
        full.append(root);
        if rel.len > 0 { full.push('/'); full.append(rel); }
        listing.clear();
        guard list_dir_typed(full, listing) else { fail(str("cannot list ", full)); }
        each_split(listing, '\n') {
            if it.len > 1 {
                let name = it[1..];
                if it[0] == 'd' {
                    let lo = dir_text.len;
                    if rel.len > 0 { dir_text.append(rel); dir_text.push('/'); }
                    dir_text.append(name);
                    dirs.push(Span { lo: lo, hi: dir_text.len });
                } else if it[0] == 'f' && ends_with(name, ".py") {
                    let lo = text.len;
                    if rel.len > 0 { text.append(rel); text.push('/'); }
                    text.append(name);
                    out.push(Span { lo: lo, hi: text.len });
                }
            }
        };
    }
}

fn send_job(root: u8[:], i: i64, full: u8[>..]&) {
    let f = files[i];
    full.clear();
    full.append(root);
    full.push('/');
    full.append(paths[f.lo..f.hi]);
    qput(Job { file: i as! u32, path: copy(full) });
}

fn build(root: u8[:], out_path: u8[:]) {
    // Files, in path order: their position is their id.
    var text: u8[>..] = [];
    var found: Span[>..] = [];
    walk(root, text, found);
    sort(found) { a, b => compare(text[a.lo..a.hi], text[b.lo..b.hi]) < 0 };
    for s in found {
        let lo = paths.len as! u32;
        for c in text[s.lo..s.hi] { paths.push(c); }
        files.push(File { lo: lo, hi: paths.len as! u32 });
    }

    // Parse in workers, a bounded window of jobs in flight; intern names as results arrive.
    let n = max(1, hardware_threads());
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker)); }
    var full: u8[>..] = [];
    var next = 0;
    while next < files.len && next < 4 * n { send_job(root, next, full); next++; }

    var name_text: u8[>..] = [];
    var name_spans: Span[>..] = [];
    var name_ids = dictionary<const u8[:], u32> {};
    var syms: Sym[>..] = [];
    for k in files.len {
        let r = qget<Parsed>();
        if next < files.len { send_job(root, next, full); next++; }
        for rec in r.recs {
            var id: u32 = 0;
            let known = get(name_ids, rec.name);
            if known { id = known; }
            else {
                id = name_spans.len as! u32;
                let lo = name_text.len;
                name_text.append(rec.name);
                name_spans.push(Span { lo: lo, hi: name_text.len });
                insert(name_ids, name_text[lo..], id);
            }
            syms.push(Sym { name: id, file: r.file, line: rec.line, kind: rec.kind });
        }
    }
    for i in n { qput(Job { file: STOP, path: "" }); }
    for id in ids { thread_wait(id); }

    // Rank the unique names bytewise, then order symbols by (name, file, line).
    var order: u32[>..] = [];
    for i in name_spans.len { order.push(i as! u32); }
    sort(order) { a, b =>
        let x = name_spans[a];
        let y = name_spans[b];
        compare(name_text[x.lo..x.hi], name_text[y.lo..y.hi]) < 0
    };
    var rank: u32[>..] = [];
    for i in name_spans.len { rank.push(0); }
    for id, r in order { rank[id] = r as! u32; }
    for &s in syms { s.name = rank[s.name]; }
    sort(syms) { a, b =>
        if a.name != b.name { a.name < b.name }
        else if a.file != b.file { a.file < b.file }
        else { a.line < b.line }
    };

    // One group per name run.
    var i = 0;
    while i < syms.len {
        var j = i + 1;
        while j < syms.len && syms[j].name == syms[i].name { j++; }
        let sp = name_spans[order[syms[i].name]];
        groups.push(Group { name: names.len as! u32, occ: occs.len as! u32 });
        names.append(name_text[sp.lo..sp.hi]);
        for s in syms[i..j] { occs.push(Occ { file: s.file as (u32 in files), lk: ((s.line - 1) << 1) | s.kind }); }
        i = j;
    }
    groups.push(Group { name: names.len as! u32, occ: occs.len as! u32 });

    // The same bytes as to_bytes of each array after the magic, written frame by frame so that
    // no copy of the image is built in memory.
    var head: u8[>..] = [];
    head.append(MAGIC);
    format_uleb(head, bytes_of(paths).len);
    var ok = write_file(out_path, head) && append_file(out_path, bytes_of(paths));
    head.clear();
    format_uleb(head, bytes_of(files).len);
    ok = ok && append_file(out_path, head) && append_file(out_path, bytes_of(files));
    head.clear();
    format_uleb(head, bytes_of(names).len);
    ok = ok && append_file(out_path, head) && append_file(out_path, bytes_of(names));
    head.clear();
    format_uleb(head, bytes_of(groups).len);
    ok = ok && append_file(out_path, head) && append_file(out_path, bytes_of(groups));
    head.clear();
    format_uleb(head, bytes_of(occs).len);
    ok = ok && append_file(out_path, head) && append_file(out_path, bytes_of(occs));
    guard ok else { fail(str("cannot write ", out_path)); }
    print("symbols=", syms.len, " files=", files.len);
}

// --- load -------------------------------------------------------------------------

var profile = false;
var prof_t = 0.0;

fn phase(name: u8[:], bytes: i64) {
    guard profile else { return; }
    let now = clock();
    let ms = (now - prof_t) * 1000.0;
    var line: u8[>..] = [];
    format(line, "profile ", name, ": ");
    format_flt(line, ms, 3);
    format(line, " ms, ", bytes, " bytes");
    if ms > 0.0 { line.append(", "); format_flt(line, bytes / 1000.0 / ms, 1); line.append(" MB/s"); }
    line.push('\n');
    write_stderr(line);
    prof_t = clock();
}

// Verifies the whole image and builds group_at (bench/SPEC.md "Image validation"):
// from_bytes checks structure and every index and bound; this pass checks the rest.
// Non-empty names and occurrence runs: both offsets strictly rise from 0 to their array's end.
fn check_groups(gs: Group[:], names_len: i64, total: i64) {
    guard gs[0].name == 0 && gs[0].occ == 0 else { fail("invalid image: group"); }
    var i = 1;
    while i < gs.len {
        guard gs[i - 1].name < gs[i].name && gs[i - 1].occ < gs[i].occ else { fail("invalid image: group"); }
        i++;
    }
    let last = gs[gs.len - 1];
    guard last.name == names_len && last.occ == total else { fail("invalid image: group"); }
}

// The arrays are locals of this one function, on purpose: `var a, n, ok = from_file(...)` reads straight
// into a's storage, whereas assigning to an existing variable (`a, n, ok = from_file(...)`) builds a
// temporary and copies it over. So loading and querying share a scope.
fn serve(path: u8[:], prefix: u8[:], query: bool) -> i64 {
    var flag: u8[>..] = [];
    profile = env("SYMIDX_PROFILE", flag) && flag == "1";
    prof_t = clock();
    var head: u8[>..] = [];
    guard read_file_range(path, 0, MAGIC.len, head) else { fail(str("cannot read ", path)); }
    guard head == MAGIC else { fail("not a symidx image"); }
    phase("read magic", head.len);

    var ps, a1, pok = from_file<u8[>..]>(path, MAGIC.len);
    guard pok else { fail("invalid image: paths"); }
    phase("from_file paths", a1);

    var f, a2, fok = from_file<File[>..]>(path, a1);
    guard fok else { fail("invalid image: files"); }
    phase("from_file files", a2 - a1);
    for x in f {
        guard x.lo <= x.hi && x.hi <= ps.len else { fail("invalid image: file span"); }
        files.push(x);
    }
    phase("push-copy+check files", a2 - a1);

    var nm, a3, nok = from_file<u8[>..]>(path, a2);
    guard nok else { fail("invalid image: names"); }
    phase("from_file names", a3 - a2);

    var gs, a4, gok = from_file<Group[>..]>(path, a3);
    guard gok && gs.len >= 1 else { fail("invalid image: groups"); }
    phase("from_file groups", a4 - a3);

    var oc, a5, ook = from_file<Occ[>..]>(path, a4);
    guard ook else { fail("invalid image: occurrences"); }
    phase("from_file occs", a5 - a4);
    var tail: u8[>..] = [];
    guard read_file_range(path, a5, 1, tail) && tail.len == 0 else { fail("invalid image: trailing bytes"); }

    check_groups(gs, nm.len, oc.len);
    phase("check groups", a4 - a3);
    if query { find(prefix, ps, nm, gs, oc); }
    return oc.len;
}

// --- queries ------------------------------------------------------------------------

fn find(prefix: u8[:], ps: u8[:], nm: u8[:], gs: Group[:], oc: Occ[:]) {
    var lo = 0;
    let n = gs.len - 1;
    var hi = n;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if compare(nm[gs[mid].name..gs[mid + 1].name], prefix) < 0 { lo = mid + 1; } else { hi = mid; }
    }
    var out: u8[>..] = [];
    var i = lo;
    while i < n && starts_with(nm[gs[i].name..gs[i + 1].name], prefix) {
        let name = nm[gs[i].name..gs[i + 1].name];
        for o in oc[gs[i].occ..gs[i + 1].occ] {
            let f = files[o.file];
            out.append(name);
            out.append(if o.lk & 1 == 0 { "\tdef\t" } else { "\tclass\t" });
            out.append(ps[f.lo..f.hi]);
            format(out, "\t", (o.lk >> 1) + 1, "\n");
        }
        if out.len >= 1 << 20 { write_stdout(out); out.clear(); }
        i++;
    }
    write_stdout(out);
}

fn usage() {
    fail("usage: symidx build <dir> -o <img> | symidx load <img> | symidx find <img> <prefix>");
}

fn main() {
    let argv = args();
    guard argv.len >= 3 else { usage(); }
    let cmd = argv[1];
    if cmd == "build" {
        guard argv.len == 5 && argv[3] == "-o" else { usage(); }
        build(argv[2], argv[4]);
    } else if cmd == "load" {
        guard argv.len == 3 else { usage(); }
        let t0 = clock();
        let n = serve(argv[2], "", false);
        var out: u8[>..] = [];
        format(out, "symbols=", n, " load_ms=");
        format_flt(out, (clock() - t0) * 1000.0, 3);
        print(out);
    } else if cmd == "find" {
        guard argv.len == 4 else { usage(); }
        serve(argv[2], argv[3], true);
    } else {
        usage();
    }
}
