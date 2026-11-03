// logxform, the Goose version: see experiments/02-logxform/SPEC.md.
//   goose build logxform.goose --cc clang -o logxform
// Each batch's records live in one resizable array on a data stack: every
// record is a contiguous variable-size value (component, message and its
// key-value pairs inline), and the whole batch is released when process()
// returns. Workers get batches and send rendered output through typed queues.

import std;
import os;
import json;

// io.c: os.goose only reads whole files, and the SPEC streams in 1 MiB blocks.
extern fn lx_open(path: const u8[:]) -> i64;
extern fn lx_read(fd: i64, out: u8[>..]&, n: i64) -> i64;    // appends up to n bytes; 0 at the end, -1 on error
extern fn lx_close(fd: i64);

let BATCH = 65536;
let BLOCK = 1048576;

let HDFS = 0;
let SSH = 1;
let APACHE = 2;

// Level ranks, in filter order.
let TRACE = 0;
let DEBUG = 1;
let INFO = 2;
let NOTICE = 3;
let WARN = 4;
let ERROR = 5;
let FATAL = 6;

let MONTHS = "JanFebMarAprMayJunJulAugSepOctNovDec";
let WEEKDAYS = "MonTueWedThuFriSatSun";

struct Pair { key: u8[varint], val: u8[varint] }
struct Rec {
    year: u16, mon: u8, day: u8, hour: u8, min: u8, sec: u8, level: u8,
    comp: u8[varint], msg: u8[varint], kv: Pair[varint],
}
struct Counts { lines: i64, kept: i64, dropped: i64, malformed: i64 }

// What a format parser finds in a line: the timestamp, the level, spans of
// the component and the message, and up to two format-specific pairs.
struct Head {
    y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64, level: i64,
    clo: i64, chi: i64, mlo: i64,
    nf: i64, k1: i64, v1lo: i64, v1hi: i64, k2: i64, v2lo: i64, v2hi: i64,
}
// Format pair keys.
let K_PID = 0;
let K_BLK = 1;
let K_HOST = 2;

fn key_name(k: i64) -> u8[:] {
    if k == K_PID { return "pid"; }
    if k == K_BLK { return "blk"; }
    return "host";
}

fn level_name(l: i64) -> u8[:] {
    if l == INFO { return "INFO"; }
    if l == WARN { return "WARN"; }
    if l == ERROR { return "ERROR"; }
    if l == NOTICE { return "NOTICE"; }
    if l == FATAL { return "FATAL"; }
    if l == DEBUG { return "DEBUG"; }
    return "TRACE";
}

fn sev_of(l: i64) -> i64 {
    if l == FATAL { return 2; }
    if l == ERROR { return 3; }
    if l == WARN { return 4; }
    if l == NOTICE { return 5; }
    if l == INFO { return 6; }
    return 7;
}

fn fail(msg: u8[:]) {
    write_stderr(str("logxform: ", msg, "\n"));
    exit(1);
}

// --- parsing ----------------------------------------------------------------------

fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

fn digits(s: u8[:], lo: i64, hi: i64) -> bool {
    for c in s[lo..hi] { if !is_digit(c) { return false; } }
    return true;
}

fn d2(s: u8[:], i: i64) -> i64 { (s[i] - '0') * 10 + (s[i + 1] - '0') }

// The month at s[i..i + 3], 1-12, or 0.
fn month(s: u8[:], i: i64) -> i64 {
    for m in 12 { if s[i..i + 3] == MONTHS[m * 3..m * 3 + 3] { return m + 1; } }
    return 0;
}

fn weekday(s: u8[:], i: i64) -> bool {
    for w in 7 { if s[i..i + 3] == WEEKDAYS[w * 3..w * 3 + 3] { return true; } }
    return false;
}

// HH:MM:SS at s[i..i + 8].
fn clock_at(s: u8[:], i: i64, h: Head&) -> bool {
    guard digits(s, i, i + 2) && s[i + 2] == ':' && digits(s, i + 3, i + 5) && s[i + 5] == ':'
          && digits(s, i + 6, i + 8) else { return false; }
    h.h = d2(s, i);
    h.mi = d2(s, i + 3);
    h.s = d2(s, i + 6);
    return true;
}

fn ts_ok(h: Head&) -> bool {
    h.mo >= 1 && h.mo <= 12 && h.d >= 1 && h.d <= 31 && h.h <= 23 && h.mi <= 59 && h.s <= 59
}

fn hdfs_level(t: u8[:]) -> i64 {
    if t == "INFO" { return INFO; }
    if t == "WARN" { return WARN; }
    if t == "ERROR" { return ERROR; }
    if t == "FATAL" { return FATAL; }
    if t == "DEBUG" { return DEBUG; }
    if t == "TRACE" { return TRACE; }
    return -1;
}

// YYMMDD HHMMSS PID LEVEL COMPONENT: MSG
fn parse_hdfs(s: u8[:], h: Head&) -> bool {
    guard s.len >= 14 && digits(s, 0, 6) && s[6] == ' ' && digits(s, 7, 13) && s[13] == ' ' else { return false; }
    h.y = 2000 + d2(s, 0);
    h.mo = d2(s, 2);
    h.d = d2(s, 4);
    h.h = d2(s, 7);
    h.mi = d2(s, 9);
    h.s = d2(s, 11);
    var i = 14;
    while i < s.len && is_digit(s[i]) { i++; }
    guard i > 14 && i < s.len && s[i] == ' ' else { return false; }
    h.nf = 1;
    h.k1 = K_PID;
    h.v1lo = 14;
    h.v1hi = i;
    i++;
    let l0 = i;
    while i < s.len && s[i] != ' ' { i++; }
    guard i < s.len else { return false; }
    h.level = hdfs_level(s[l0..i]);
    guard h.level >= 0 else { return false; }
    i++;
    // The component runs to the first ": " and has no space: so it is the
    // next space-free token, ending in a colon.
    let c0 = i;
    while i < s.len && s[i] != ' ' { i++; }
    guard i < s.len && i - 1 > c0 && s[i - 1] == ':' else { return false; }
    h.clo = c0;
    h.chi = i - 1;
    h.mlo = i + 1;
    // blk: the first message token starting with blk_, cut to blk_-?[0-9]+.
    var t = h.mlo;
    while t < s.len {
        while t < s.len && s[t] == ' ' { t++; }
        let t0 = t;
        while t < s.len && s[t] != ' ' { t++; }
        if t > t0 && starts_with(s[t0..t], "blk_") {
            var e = t0 + 4;
            if e < t && s[e] == '-' { e++; }
            let dg = e;
            while e < t && is_digit(s[e]) { e++; }
            if e > dg {
                h.nf = 2;
                h.k2 = K_BLK;
                h.v2lo = t0;
                h.v2hi = e;
            }
            break;
        }
    }
    return ts_ok(h);
}

// Mmm DD HH:MM:SS HOST PROG[PID]: MSG
fn parse_ssh(s: u8[:], h: Head&) -> bool {
    guard s.len >= 16 && s[3] == ' ' && s[6] == ' ' && s[15] == ' ' else { return false; }
    h.mo = month(s, 0);
    guard h.mo > 0 else { return false; }
    if s[4] == ' ' && is_digit(s[5]) { h.d = s[5] - '0'; }
    else if digits(s, 4, 6) { h.d = d2(s, 4); }
    else { return false; }
    guard clock_at(s, 7, h) else { return false; }
    h.y = if h.mo >= 7 { 2017 } else { 2018 };
    var i = 16;
    let host = i;
    while i < s.len && s[i] != ' ' { i++; }
    guard i > host && i < s.len else { return false; }
    let host_hi = i;
    i++;
    let prog = i;
    while i < s.len && s[i] != ' ' && s[i] != '[' { i++; }
    guard i > prog && i < s.len && s[i] == '[' else { return false; }
    let prog_hi = i;
    i++;
    let pid = i;
    while i < s.len && is_digit(s[i]) { i++; }
    guard i > pid && i + 3 <= s.len && s[i..i + 3] == "]: " else { return false; }
    h.clo = prog;
    h.chi = prog_hi;
    h.mlo = i + 3;
    h.nf = 2;
    h.k1 = K_HOST;
    h.v1lo = host;
    h.v1hi = host_hi;
    h.k2 = K_PID;
    h.v2lo = pid;
    h.v2hi = i;
    let m = s[h.mlo..];
    if starts_with(m, "error: ") { h.level = ERROR; }
    else if starts_with(m, "fatal: ") { h.level = FATAL; }
    else if starts_with(m, "Failed ") || starts_with(m, "Invalid user ") || starts_with(m, "reverse mapping ") { h.level = WARN; }
    else { h.level = INFO; }
    return ts_ok(h);
}

fn apache_level(t: u8[:]) -> i64 {
    if t == "error" { return ERROR; }
    if t == "notice" { return NOTICE; }
    if t == "warn" { return WARN; }
    if t == "info" { return INFO; }
    if t == "debug" { return DEBUG; }
    if t == "emerg" || t == "alert" || t == "crit" { return FATAL; }
    return -1;
}

// [Www Mmm DD HH:MM:SS YYYY] [level] MSG
fn parse_apache(s: u8[:], h: Head&) -> bool {
    guard s.len >= 29 && s[0] == '[' && s[4] == ' ' && s[8] == ' ' && s[11] == ' ' && s[20] == ' '
          && s[25] == ']' && s[26] == ' ' && s[27] == '[' else { return false; }
    guard weekday(s, 1) else { return false; }
    h.mo = month(s, 5);
    guard h.mo > 0 && digits(s, 9, 11) && clock_at(s, 12, h) && digits(s, 21, 25) else { return false; }
    h.d = d2(s, 9);
    h.y = d2(s, 21) * 100 + d2(s, 23);
    var i = 28;
    while i < s.len && s[i] != ']' { i++; }
    guard i + 1 < s.len && s[i + 1] == ' ' else { return false; }
    h.level = apache_level(s[28..i]);
    guard h.level >= 0 else { return false; }
    h.clo = 0;
    h.chi = 0;
    h.mlo = i + 2;
    h.nf = 0;
    return ts_ok(h);
}

// --- transform ------------------------------------------------------------------

fn min_level(comp: u8[:]) -> i64 {
    if comp == "dfs.DataNode$PacketResponder" || comp == "dfs.FSDataset" { return WARN; }
    return INFO;
}

// Exactly four groups of 1-3 digits joined by single dots (s holds digits and dots).
fn is_ipv4(s: u8[:]) -> bool {
    var groups = 0;
    var n = 0;
    for c in s {
        if c == '.' {
            if n == 0 || n > 3 { return false; }
            groups++;
            n = 0;
        } else {
            n++;
        }
    }
    return groups == 3 && n >= 1 && n <= 3;
}

fn redact(msg: u8[:], out: u8[>..]&) {
    var start = 0;
    var i = 0;
    while i < msg.len {
        let c = msg[i];
        if is_digit(c) && (i == 0 || !(is_digit(msg[i - 1]) || msg[i - 1] == '.')) {
            var j = i;
            while j < msg.len && (is_digit(msg[j]) || msg[j] == '.') { j++; }
            var k = j;
            while k > i && msg[k - 1] == '.' { k--; }
            if is_ipv4(msg[i..k]) {
                out.append(msg[start..i]);
                out.append("<ip>");
                start = k;
            }
            i = j;
        } else {
            i++;
        }
    }
    out.append(msg[start..]);
}

fn is_key_byte(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) || c == '_' || c == '.' || c == '-'
}

// A pair's key and value, as spans of the line's pair text.
struct KSpan { klo: i64, khi: i64, vlo: i64, vhi: i64 }

// Dictionary semantics: an existing key keeps its place and takes the new value.
fn add_pair(text: u8[>..]&, sp: KSpan[>..]&, k: u8[:], v: u8[:]) {
    for &x in sp {
        if text[x.klo..x.khi] == k {
            x.vlo = text.len;
            text.append(v);
            x.vhi = text.len;
            return;
        }
    }
    let klo = text.len;
    text.append(k);
    let khi = text.len;
    text.append(v);
    sp.push(KSpan { klo: klo, khi: khi, vlo: khi, vhi: text.len });
}

fn pairs_of(sp: KSpan[:], text: u8[:]) -> Pair[>..] {
    var ps: Pair[>..] = [];
    for x in sp { ps.push(Pair { key: text[x.klo..x.khi], val: text[x.vlo..x.vhi] }); }
    return ps;
}

// --- one batch: build, transform, render, drop ----------------------------------

fn put2(out: u8[>..]&, v: i64) {
    out.push((48 + v / 10) as! u8);
    out.push((48 + v % 10) as! u8);
}

fn render(out: u8[>..]&, r: Rec&) {
    out.append("{\"ts\":\"");
    put2(out, r.year / 100);
    put2(out, r.year % 100);
    out.push('-');
    put2(out, r.mon);
    out.push('-');
    put2(out, r.day);
    out.push('T');
    put2(out, r.hour);
    out.push(':');
    put2(out, r.min);
    out.push(':');
    put2(out, r.sec);
    out.append("Z\",\"level\":\"");
    out.append(level_name(r.level));
    out.append("\",\"sev\":");
    out.push((48 + sev_of(r.level)) as! u8);
    out.append(",\"component\":");
    json::format_string(out, r.comp);
    out.append(",\"msg\":");
    json::format_string(out, r.msg);
    out.append(",\"kv\":{");
    var first = true;
    for p in r.kv {
        if !first { out.push(','); }
        first = false;
        json::format_string(out, p.key);
        out.push(':');
        json::format_string(out, p.val);
    }
    out.append("}}\n");
}

let NL = byte_set("\n");

var t_build = 0.0;
var t_render = 0.0;
var t_read = 0.0;
var t_write = 0.0;
var t_drop = 0.0;

fn process(fmt: i64, data: u8[:], out: u8[>..]&, c: Counts&) {
    let p0 = clock();
    var recs: Rec[>..] = [];
    var start = 0;
    while start < data.len {
        var e = find_any(data[start..], NL);
        e = if e < 0 { data.len } else { start + e };
        var s = data[start..e];
        start = e + 1;
        if s.len > 0 && s[s.len - 1] == '\r' { s = s[..s.len - 1]; }
        c.lines++;
        var h = Head { y: 0, mo: 0, d: 0, h: 0, mi: 0, s: 0, level: 0, clo: 0, chi: 0, mlo: 0,
                       nf: 0, k1: 0, v1lo: 0, v1hi: 0, k2: 0, v2lo: 0, v2hi: 0 };
        var ok = false;
        if fmt == HDFS { ok = parse_hdfs(s, h); }
        else if fmt == SSH { ok = parse_ssh(s, h); }
        else { ok = parse_apache(s, h); }
        if !ok { c.malformed++; continue; }
        let comp = if fmt == APACHE { "httpd"[..] } else { s[h.clo..h.chi] };
        if h.level < min_level(comp) { c.dropped++; continue; }
        c.kept++;
        // Per-line scratch, released at the end of each iteration.
        var red: u8[>..] = [];
        redact(s[h.mlo..], red);
        var text: u8[>..] = [];
        var sp: KSpan[>..] = [];
        if h.nf >= 1 { add_pair(text, sp, key_name(h.k1), s[h.v1lo..h.v1hi]); }
        if h.nf >= 2 { add_pair(text, sp, key_name(h.k2), s[h.v2lo..h.v2hi]); }
        var t = 0;
        while t < red.len {
            while t < red.len && red[t] == ' ' { t++; }
            let t0 = t;
            while t < red.len && red[t] != ' ' { t++; }
            var p = t0;
            while p < t && red[p] != '=' && is_key_byte(red[p]) { p++; }
            if p > t0 && p < t && red[p] == '=' { add_pair(text, sp, red[t0..p], red[p + 1..t]); }
        }
        recs.push(Rec {
            year: h.y as! u16, mon: h.mo as! u8, day: h.d as! u8, hour: h.h as! u8, min: h.mi as! u8,
            sec: h.s as! u8, level: h.level as! u8, comp: comp, msg: red[..], kv: pairs_of(sp, text),
        });
    }
    let p1 = clock();
    for r in recs { render(out, r); }
    t_build += p1 - p0;
    t_render += clock() - p1;
}

// --- reading batches ------------------------------------------------------------

// The end of the next batch in buf (after its 65,536th newline), reading more
// blocks as needed; buf.len at the end of the file. Returns the end and
// whether the file has ended.
fn next_batch(fd: i64, buf: u8[>..]&, eof_in: bool) -> i64, bool {
    var eof = eof_in;
    var lines = 0;
    var scan = 0;
    loop {
        while true {
            let k = find_any(buf[scan..], NL);
            if k < 0 { scan = buf.len; break; }
            scan += k + 1;
            lines++;
            if lines == BATCH { return scan, eof; }
        }
        if eof { return buf.len, eof; }
        let n = lx_read(fd, buf, BLOCK);
        guard n >= 0 else { fail("read error"); }
        if n == 0 { eof = true; }
    }
    return buf.len, eof;
}

fn drop_front(buf: u8[>..]&, n: i64) {
    let k = buf.len - n;
    for i in k { buf[i] = buf[n + i]; }
    buf.pop_n(n);
}

// --- threads ----------------------------------------------------------------------

struct Job { seq: i64, fmt: i64, data: u8[] }                 // seq -1 stops a worker
struct Done { seq: i64, c: Counts, out: u8[] }
struct Pend { seq: i64, lo: i64, hi: i64 }

thread_fn worker() {
    var out: u8[>..] = [];
    loop {
        let job = qget<Job>();
        guard job.seq >= 0 else { break; }
        out.clear();
        var c = Counts { lines: 0, kept: 0, dropped: 0, malformed: 0 };
        process(job.fmt, job.data, out, c);
        qput(Done { seq: job.seq, c: c, out: out[..] });
    }
}

fn add(t: Counts&, c: Counts) {
    t.lines += c.lines;
    t.kept += c.kept;
    t.dropped += c.dropped;
    t.malformed += c.malformed;
}

// Main's side of the pipeline: results arrive in any order and are written
// in sequence; early ones wait in `pend`, a byte pool with spans.
var total = Counts { lines: 0, kept: 0, dropped: 0, malformed: 0 };
var next_write = 0;
var in_flight = 0;
var pend: u8[>..] = [];
var spans: Pend[>..] = [];

fn receive() {
    let d = qget<Done>();
    add(total, d.c);
    if d.seq != next_write {
        let lo = pend.len;
        pend.append(d.out);
        spans.push(Pend { seq: d.seq, lo: lo, hi: pend.len });
        return;
    }
    write_stdout(d.out);
    next_write++;
    in_flight--;
    var wrote = false;
    var found = true;
    while found {
        found = false;
        for &p in spans {
            if p.seq == next_write {
                write_stdout(pend[p.lo..p.hi]);
                p.seq = -1;
                next_write++;
                in_flight--;
                found = true;
                wrote = true;
            }
        }
    }
    guard wrote else { return; }
    var live = 0;
    for p in spans { if p.seq >= 0 { live += p.hi - p.lo; } }
    if live == 0 {
        pend.clear();
        spans.clear();
        return;
    }
    // Compact only when written bytes outweigh the ones still waiting.
    guard pend.len - live > live else { return; }
    var np: u8[>..] = [];
    var ns: Pend[>..] = [];
    for p in spans {
        if p.seq >= 0 {
            let lo = np.len;
            np.append(pend[p.lo..p.hi]);
            ns.push(Pend { seq: p.seq, lo: lo, hi: np.len });
        }
    }
    pend = copy(np);
    spans = copy(ns);
}

// --- main -----------------------------------------------------------------------

fn format_id(name: u8[:]) -> i64 {
    if name == "hdfs" { return HDFS; }
    if name == "ssh" { return SSH; }
    if name == "apache" { return APACHE; }
    fail(str("unknown format ", name));
    return -1;
}

fn usage() { fail("usage: logxform [-t N] FORMAT FILE [FORMAT FILE ...]"); }

fn main() {
    let argv = args();
    var a = 1;
    var threads = 1;
    if argv.len > 2 && argv[1] == "-t" {
        let n, ok = parse_int(argv[2]);
        guard ok && n >= 1 else { usage(); }
        threads = n;
        a = 3;
    }
    guard argv.len > a && (argv.len - a) % 2 == 0 else { usage(); }

    var ids: i64[>..] = [];
    for i in (if threads > 1 { threads } else { 0 }) { ids.push(thread_spawn(worker)); }
    var seq = 0;
    var out: u8[>..] = [];
    var buf: u8[>..] = [];
    while a < argv.len {
        let fmt = format_id(argv[a]);
        let fd = lx_open(argv[a + 1]);
        guard fd >= 0 else { fail(str("cannot open ", argv[a + 1])); }
        a += 2;
        buf.clear();
        var eof = false;
        loop {
            let q0 = clock();
            let end, e = next_batch(fd, buf, eof);
            t_read += clock() - q0;
            eof = e;
            if end == 0 { break; }
            if threads == 1 {
                out.clear();
                process(fmt, buf[..end], out, total);
                let q1 = clock();
                write_stdout(out);
                t_write += clock() - q1;
            } else {
                while in_flight >= 2 * threads { receive(); }
                qput(Job { seq: seq, fmt: fmt, data: buf[..end] });
                seq++;
                in_flight++;
            }
            let q2 = clock();
            drop_front(buf, end);
            t_drop += clock() - q2;
        }
        lx_close(fd);
    }
    while in_flight > 0 { receive(); }
    for i in ids.len { qput(Job { seq: -1, fmt: 0, data: "" }); }
    for id in ids { thread_wait(id); }
    flush_stdout();
    var line: u8[>..] = [];
    format(line, "lines=", total.lines, " kept=", total.kept, " dropped=", total.dropped,
           " malformed=", total.malformed, "\n");
    write_stderr(line);
    var pl: u8[>..] = [];
    pl.append("profile read+scan=");
    format_flt(pl, t_read, 3);
    pl.append(" build=");
    format_flt(pl, t_build, 3);
    pl.append(" render=");
    format_flt(pl, t_render, 3);
    pl.append(" write=");
    format_flt(pl, t_write, 3);
    pl.append(" carry=");
    format_flt(pl, t_drop, 3);
    pl.push('\n');
    write_stderr(pl);
}
