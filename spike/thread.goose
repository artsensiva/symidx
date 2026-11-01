// Spike: walk a directory with a C helper, parse *.py files in thread_fn
// workers, and pass each file's symbols back through a queue as one flat value.
//   goose build thread.goose --cc clang && ./thread <dir>

import std;
import os;

extern fn list_dir_typed(path: const u8[:], out: u8[>..]&) -> bool;

struct Job { file: u32, path: u8[] }               // file = u32::MAX means stop
struct Rec { line: u32, kind: u8, name: u8[varint] }
struct Parsed { file: u32, recs: Rec[] }

fn is_ws(c: u8) -> bool { c == ' ' || c == '\t' }
fn is_ident(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c >= 0x80
}

// bench/SPEC.md "Line parsing": kind 0 = def, 1 = class, -1 = not a symbol.
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
        guard job.file != 0xffffffff else { break; }
        text.clear();
        guard read_file(job.path, text) else { abort(str("cannot read ", job.path)); }
        qput(Parsed { file: job.file, recs: parse_file(text) });
    }
}

// Collects every regular *.py file under root, relative paths, '/'-separated.
// Breadth-first: directory paths live in one byte buffer, indexed by spans.
struct Span { lo: i64, hi: i64 }

fn walk(root: u8[:], out: u8[][>..]&) {
    var dir_text: u8[>..] = [];
    var dirs: Span[>..] = [];
    dirs.push(Span { lo: 0, hi: 0 });
    var listing: u8[>..] = [];
    var full: u8[>..] = [];
    var p: u8[>..] = [];
    var next = 0;
    while next < dirs.len {
        let d = dirs[next];
        next++;
        let rel = dir_text[d.lo..d.hi];
        full.clear();
        full.append(root);
        if rel.len > 0 { full.push('/'); full.append(rel); }
        listing.clear();
        guard list_dir_typed(full, listing) else { abort(str("cannot list ", full)); }
        each_split(listing, '\n') {
            if it.len > 1 {
                let name = it[1..];
                p.clear();
                if rel.len > 0 { p.append(rel); p.push('/'); }
                p.append(name);
                if it[0] == 'd' {
                    let lo = dir_text.len;
                    dir_text.append(p);
                    dirs.push(Span { lo: lo, hi: dir_text.len });
                }
                else if it[0] == 'f' && ends_with(name, ".py") { out.push(copy(p)); }
            }
        };
    }
}

fn main() {
    let argv = args();
    guard argv.len == 2 else { print("usage: thread <dir>"); exit(2); }
    let root = argv[1];
    let t0 = clock();
    var files: u8[][>..] = [];
    walk(root, files);
    let t1 = clock();
    let n = max(1, hardware_threads());
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker)); }
    var full: u8[>..] = [];
    for p, i in files {
        full.clear();
        full.append(root); full.push('/'); full.append(p);
        qput(Job { file: i as! u32, path: copy(full) });
    }
    for i in n { qput(Job { file: 0xffffffff, path: "" }); }
    var syms = 0;
    var defs = 0;
    var check: u64 = 0;
    for i in files.len {
        let r = qget<Parsed>();
        syms += r.recs.len;
        for rec in r.recs {
            if rec.kind == 0 { defs++; }
            check = check * 31 + rec.line + r.file;
        }
    }
    for id in ids { thread_wait(id); }
    print("files=", files.len, " symbols=", syms, " defs=", defs, " workers=", n,
          " walk_ms=", ((t1 - t0) * 1000.0) as! i64, " total_ms=", ((clock() - t0) * 1000.0) as! i64);
}
