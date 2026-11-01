// symidx, the Goose version: see CLAUDE.md for the image layout and
// bench/SPEC.md for the behavior every implementation shares.
//   goose build symidx.goose --cc clang -o symidx

import std;
import os;
import dictionary;

extern fn list_dir_typed(path: const u8[:], out: u8[>..]&) -> bool;

// --- the image ----------------------------------------------------------------
// Three to_bytes frames after the magic: paths, files, groups. Every link is an
// index or bound type, which from_bytes checks against its array.

let MAGIC = "SYMIDX1\n";

struct File { lo: u32 upto paths, hi: u32 upto paths }
struct Occ { file: u32 in files, line: varint, kind: u8 }        // kind: 0 = def, 1 = class
struct NameGroup { name: u8[varint], occs: Occ[varint] }

// `paths` and `files` are pinned by index types, so they only ever grow, and
// only by push: from_bytes rejects an index into an array grown with append
// (spike/FINDINGS.md).
var paths: u8[>..] = [];
var files: File[>..] = [];
var groups: NameGroup[>..] = [];
var group_at: (NameGroup&<u32 in groups>)[>..] = [];      // in memory only, for binary search

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

fn occs_of(run: Sym[:]) -> Occ[>..] {
    var occs: Occ[>..] = [];
    for s in run { occs.push(Occ { file: s.file as (u32 in files), line: s.line, kind: s.kind }); }
    return occs;
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
        let lo = paths.len as (u32 upto paths);
        for c in text[s.lo..s.hi] { paths.push(c); }
        files.push(File { lo: lo, hi: paths.len as (u32 upto paths) });
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
        groups.push(NameGroup { name: name_text[sp.lo..sp.hi], occs: occs_of(syms[i..j]) });
        i = j;
    }

    var img: u8[>..] = [];
    img.append(MAGIC);
    to_bytes(paths, img);
    to_bytes(files, img);
    to_bytes(groups, img);
    guard write_file(out_path, img) else { fail(str("cannot write ", out_path)); }
    print("symbols=", syms.len, " files=", files.len);
}

// --- load -------------------------------------------------------------------------

// One LEB128 varint at s[i..]: the value and the index after it, or -1 if it runs off the end.
fn uleb(s: u8[:], i: i64) -> i64, i64 {
    var v = 0;
    var shift = 0;
    var j = i;
    loop {
        guard j < s.len && shift < 63 else { return 0, -1; }
        let b = s[j];
        j++;
        v = v | ((b & 0x7f) as i64 << shift);
        if b < 0x80 { break; }
        shift += 7;
    }
    return v, j;
}

// The frame starting at img[at..]: its bytes (prefix included) and where the next one starts.
fn frame(img: u8[:], at: i64) -> u8[:], i64 {
    let n, body = uleb(img, at);
    guard body >= 0 && n <= img.len - body else { fail("image is truncated"); }
    return img[at..body + n], body + n;
}

// SYMIDX_PROFILE=1: time and throughput of each load phase, on stderr.
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
fn load(path: u8[:]) -> i64 {
    var flag: u8[>..] = [];
    profile = env("SYMIDX_PROFILE", flag) && flag == "1";
    prof_t = clock();
    var img: u8[>..] = [];
    guard read_file(path, img) else { fail(str("cannot read ", path)); }
    phase("read_file", img.len);
    guard starts_with(img, MAGIC) else { fail("not a symidx image"); }
    var at = MAGIC.len;

    let fp, a1 = frame(img, at);
    var p, pok = from_bytes<u8[>..]>(fp);
    guard pok else { fail("invalid image: paths"); }
    phase("from_bytes paths", fp.len);
    for c in p { paths.push(c); }
    phase("push-copy paths", p.len);

    let ff, a2 = frame(img, a1);
    var f, fok = from_bytes<File[>..]>(ff);
    guard fok else { fail("invalid image: files"); }
    phase("from_bytes files", ff.len);
    for x in f {
        guard x.lo <= x.hi else { fail("invalid image: file span"); }
        files.push(x);
    }
    phase("push-copy+check files", ff.len);

    let fg, a3 = frame(img, a2);
    var gok = false;
    groups, gok = from_bytes<NameGroup[>..]>(fg);
    guard gok else { fail("invalid image: groups"); }
    guard a3 == img.len else { fail("invalid image: trailing bytes"); }
    phase("from_bytes groups", fg.len);

    var count = 0;
    for g in groups {
        guard g.name.len > 0 && g.occs.len > 0 else { fail("invalid image: empty group"); }
        for o in g.occs {
            guard o.kind <= 1 && o.line >= 1 else { fail("invalid image: occurrence"); }
        }
        count += g.occs.len;
        group_at.push(g);
    }
    phase("validate+group_at", fg.len);
    return count;
}

// --- queries ------------------------------------------------------------------------

fn find(prefix: u8[:]) {
    var lo = 0;
    var hi = group_at.len;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if compare(group_at[mid].name, prefix) < 0 { lo = mid + 1; } else { hi = mid; }
    }
    var out: u8[>..] = [];
    var i = lo;
    while i < group_at.len && starts_with(group_at[i].name, prefix) {
        let g .= group_at[i];
        for o in g.occs {
            let f = files[o.file];
            out.append(g.name);
            out.append(if o.kind == 0 { "\tdef\t" } else { "\tclass\t" });
            out.append(paths[f.lo..f.hi]);
            format(out, "\t", o.line, "\n");
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
        let n = load(argv[2]);
        var out: u8[>..] = [];
        format(out, "symbols=", n, " load_ms=");
        format_flt(out, (clock() - t0) * 1000.0, 3);
        print(out);
    } else if cmd == "find" {
        guard argv.len == 4 else { usage(); }
        load(argv[2]);
        find(argv[3]);
    } else {
        usage();
    }
}
