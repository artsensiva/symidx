// Goose logxform as a tool: sanitize rotated logs for an analytics store. The pilot's spec is experiments/07-pilot/SPEC.md.
// Parsing, filtering, redaction and rendering follow experiments/02-logxform/SPEC.md, from experiment 2's Goose program.
// Built with the unpatched Goose v2026.3 release:
//   goose build sanitize.goose --cc clang -o sanitize

import std;
import os;
import json;

// io.c: see its header.
extern fn lx_open(path: const u8[:]) -> i64;
extern fn lx_create(path: const u8[:]) -> i64;
extern fn lx_read(fd: i64, out: u8[>..]&, n: i64) -> i64;    // appends up to n bytes; 0 at the end, -1 on error
extern fn lx_write(fd: i64, data: const u8[:]) -> bool;
extern fn lx_close(fd: i64) -> bool;
extern fn lx_ignore_sigpipe();

let BATCH = 65536;
let BLOCK = 1048576;

let HDFS = 0;
let SSH = 1;
let APACHE = 2;
let BGL = 3;

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
let K_NODE = 3;
let K_ALERT = 4;

fn key_name(k: i64) -> u8[:] {
    if k == K_PID { return "pid"; }
    if k == K_BLK { return "blk"; }
    if k == K_NODE { return "node"; }
    if k == K_ALERT { return "alert"; }
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

// Exit codes, SPEC A2: 1 reject rate exceeded, 2 bad command line, 3 I/O failure.
var tmp_path: u8[>..] = [];                     // --out's temporary file, removed on failure

fn abandon() {
    if tmp_path.len > 0 { delete_file(tmp_path); }
}

fn io_fail(what: u8[:], path: u8[:]) {
    abandon();
    write_stderr(str("sanitize: ", what, " ", path, "\n"));
    exit(3);
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

fn bgl_level(t: u8[:]) -> i64 {
    if t == "INFO" { return INFO; }
    if t == "FATAL" || t == "FAILURE" { return FATAL; }
    if t == "ERROR" || t == "SEVERE" { return ERROR; }
    if t == "WARNING" { return WARN; }
    return -1;
}

fn token_end(s: u8[:], i: i64) -> i64 {
    var e = i;
    while e < s.len && s[e] != ' ' { e++; }
    return e;
}

// LABEL EPOCH YYYY.MM.DD NODE YYYY-MM-DD-HH.MM.SS.ffffff [NODE2] TYPE COMPONENT LEVEL[ MSG]
fn parse_bgl(s: u8[:], h: Head&) -> bool {
    let label = token_end(s, 0);
    guard label > 0 && label < s.len else { return false; }
    let ep = label + 1;
    let ep_hi = token_end(s, ep);
    guard ep_hi > ep && ep_hi < s.len && digits(s, ep, ep_hi) else { return false; }
    let d = ep_hi + 1;
    guard d + 11 <= s.len && s[d + 4] == '.' && s[d + 7] == '.' && s[d + 10] == ' ' && digits(s, d, d + 4)
          && digits(s, d + 5, d + 7) && digits(s, d + 8, d + 10) else { return false; }
    let node = d + 11;
    let node_hi = token_end(s, node);
    guard node_hi > node && node_hi < s.len else { return false; }
    let t = node_hi + 1;
    guard t + 27 <= s.len && s[t + 4] == '-' && s[t + 7] == '-' && s[t + 10] == '-' && s[t + 13] == '.' && s[t + 16] == '.'
          && s[t + 19] == '.' && s[t + 26] == ' ' && digits(s, t, t + 4) && digits(s, t + 5, t + 7) && digits(s, t + 8, t + 10)
          && digits(s, t + 11, t + 13) && digits(s, t + 14, t + 16) && digits(s, t + 17, t + 19) && digits(s, t + 20, t + 26)
          else { return false; }
    h.y = d2(s, t) * 100 + d2(s, t + 2);
    h.mo = d2(s, t + 5);
    h.d = d2(s, t + 8);
    h.h = d2(s, t + 11);
    h.mi = d2(s, t + 14);
    h.s = d2(s, t + 17);
    var i = t + 27;
    let no_node2 = s[node..node_hi] == "-" && (starts_with(s[i..], "RAS ") || starts_with(s[i..], "NULL "));
    if !no_node2 {
        let e = token_end(s, i);
        guard e > i && e < s.len else { return false; }
        i = e + 1;
    }
    let ty = token_end(s, i);
    guard ty < s.len && (s[i..ty] == "RAS" || s[i..ty] == "NULL") else { return false; }
    i = ty + 1;
    h.clo = i;
    h.chi = token_end(s, i);
    guard h.chi > i && h.chi < s.len else { return false; }
    i = h.chi + 1;
    let lv = token_end(s, i);
    h.level = bgl_level(s[i..lv]);
    guard h.level >= 0 else { return false; }
    h.mlo = if lv < s.len { lv + 1 } else { s.len };
    h.nf = 1;
    h.k1 = K_NODE;
    h.v1lo = node;
    h.v1hi = node_hi;
    if s[..label] != "-" {
        h.nf = 2;
        h.k2 = K_ALERT;
        h.v2lo = 0;
        h.v2hi = label;
    }
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

fn is_alnum(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) }

fn is_hex(c: u8) -> bool { is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

// 0x and exactly 8 hex digits, not touching a letter or digit, at s[i..i + 10].
fn hex_at(s: u8[:], i: i64) -> bool {
    guard s[i] == '0' && s[i + 1] == 'x' && (i == 0 || !is_alnum(s[i - 1])) && (i + 10 == s.len || !is_alnum(s[i + 10])) else { return false; }
    for c in s[i + 2..i + 10] { if !is_hex(c) { return false; } }
    return true;
}

let DASH = byte_set("-");
let SET_0 = byte_set("0");
let SET_X = byte_set("x");

// The next 0x at or after from, or -1.
fn next_0x(s: u8[:], from: i64) -> i64 {
    let k = find_pair(s[from..], SET_0, 1, SET_X);
    return if k < 0 { -1 } else { from + k };
}

// Rewrites s in place, since <hex> is shorter than what it replaces. Returns the new length.
fn redact_hex(s: u8[>..]&) -> i64 {
    var w = 0;
    var r = 0;
    var p = next_0x(s[..], 0);
    while p >= 0 {
        if p + 10 <= s.len && hex_at(s[..], p) {
            while r < p { s[w] = s[r]; w++; r++; }
            for c in "<hex>" { s[w] = c; w++; }
            r = p + 10;
            p = next_0x(s[..], r);
        } else {
            p = next_0x(s[..], p + 1);
        }
    }
    if w == r { return s.len; }
    while r < s.len { s[w] = s[r]; w++; r++; }
    return w;
}

// A number from 0 to 255 at s[i], its end, or -1.
fn octet(s: u8[:], i: i64) -> i64 {
    var j = i;
    var v = 0;
    while j < s.len && j - i < 3 && is_digit(s[j]) { v = v * 10 + (s[j] - '0'); j++; }
    return if j == i || v > 255 { -1 } else { j };
}

// A dashed IP at s[i] (experiment 9's SPEC), its end, or -1.
fn dashed_at(s: u8[:], i: i64) -> i64 {
    if i > 0 {
        let p = s[i - 1];
        if is_digit(p) { return -1; }
        var at = i;
        while at > 0 && s[at - 1] == '-' {
            var g = at - 1;
            var letter = false;
            while g > 0 && is_alnum(s[g - 1]) {
                g--;
                if !is_digit(s[g]) { letter = true; }
            }
            if g == at - 1 || letter { break; }             // an empty group, or a host name
            if g == 0 || s[g - 1] != '-' { return -1; }     // only numbers from the start of the run, as in a date
            at = g;
        }
    }
    var e = i;
    for n in 4 {
        e = octet(s, e);
        if e < 0 { return -1; }
        if n < 3 {
            if e >= s.len || s[e] != '-' { return -1; }
            e++;
        }
    }
    if e < s.len && is_alnum(s[e]) { return -1; }
    if e + 1 < s.len && s[e] == '-' && is_digit(s[e + 1]) { return -1; }
    return e;
}

// Rewrites s in place, since <ip> is shorter than any dashed IP. Returns the new length.
fn redact_dashed(s: u8[>..]&) -> i64 {
    var w = 0;
    var r = 0;
    var p = 0;
    while p < s.len {
        let k = find_any(s[p..], DASH);
        if k < 0 { break; }
        let d = p + k;
        p = d + 1;
        var j = d;
        while j > r && d - j < 4 && is_digit(s[j - 1]) { j--; }
        if j == d || d - j > 3 { continue; }
        let e = dashed_at(s[..], j);
        if e < 0 { continue; }
        while r < j { s[w] = s[r]; w++; r++; }
        for c in "<ip>" { s[w] = c; w++; }
        r = e;
        p = e;
    }
    if w == r { return s.len; }
    while r < s.len { s[w] = s[r]; w++; r++; }
    return w;
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

// Whether s needs no JSON escapes. No early exit and no comparisons, so the C compiler vectorizes it: almost every string is
// plain. For x below 256, (x + 255) >> 8 is 0 only for x == 0, and (x + 224) >> 8 is 0 only for x below 0x20.
fn plain(s: u8[:]) -> bool {
    var ok: u32 = 1;
    for c in s {
        let x = c as u32;
        ok = ok & (((x ^ 34) + 255) >> 8) & (((x ^ 92) + 255) >> 8) & ((x + 224) >> 8);
    }
    return ok == 1;
}

fn put_str(out: u8[>..]&, s: u8[:]) {
    out.push('"');
    if plain(s) { out.append(s); } else { json::format_escaped(out, s); }
    out.push('"');
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
    put_str(out, r.comp);
    out.append(",\"msg\":");
    put_str(out, r.msg);
    out.append(",\"kv\":{");
    var first = true;
    for p in r.kv {
        if !first { out.push(','); }
        first = false;
        put_str(out, p.key);
        out.push(':');
        put_str(out, p.val);
    }
    out.append("}}\n");
}

let NL = byte_set("\n");

fn process(fmt: i64, data: u8[:], out: u8[>..]&, rejects: u8[>..]&, keep_rejects: bool, c: Counts&, max_line: i64) {
    var recs: Rec[>..] = [];
    var start = 0;
    while start < data.len {
        var e = find_any(data[start..], NL);
        e = if e < 0 { data.len } else { start + e };
        let raw = data[start..e];
        var s = raw;
        start = e + 1;
        if raw.len > max_line {
            c.lines++;
            c.malformed++;
            if keep_rejects { rejects.append(raw[..min(raw.len, 4096)]); rejects.push('\n'); }
            continue;
        }
        if s.len > 0 && s[s.len - 1] == '\r' { s = s[..s.len - 1]; }
        c.lines++;
        var h = Head { y: 0, mo: 0, d: 0, h: 0, mi: 0, s: 0, level: 0, clo: 0, chi: 0, mlo: 0,
                       nf: 0, k1: 0, v1lo: 0, v1hi: 0, k2: 0, v2lo: 0, v2hi: 0 };
        var ok = false;
        if fmt == HDFS { ok = parse_hdfs(s, h); }
        else if fmt == SSH { ok = parse_ssh(s, h); }
        else if fmt == APACHE { ok = parse_apache(s, h); }
        else { ok = parse_bgl(s, h); }
        if !ok {
            c.malformed++;
            if keep_rejects { rejects.append(raw); rejects.push('\n'); }
            continue;
        }
        let comp = if fmt == APACHE { "httpd"[..] } else { s[h.clo..h.chi] };
        if h.level < min_level(comp) || (fmt == BGL && h.level < ERROR && comp == "APP") { c.dropped++; continue; }
        c.kept++;
        // Per-line scratch, released at the end of each iteration.
        var red_all: u8[>..] = [];
        redact(s[h.mlo..], red_all);
        let n1 = redact_dashed(red_all);
        if n1 < red_all.len { red_all.pop_n(red_all.len - n1); }
        let red = red_all[..redact_hex(red_all)];
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
            sec: h.s as! u8, level: h.level as! u8, comp: comp, msg: red, kv: pairs_of(sp, text),
        });
    }
    for r in recs { render(out, r); }
}

// --- reading batches ------------------------------------------------------------

// The end of the next batch in buf (after its 65,536th newline), reading more
// blocks as needed; buf.len at the end of the file. Returns the end and
// whether the file has ended.
fn next_batch(fd: i64, name: u8[:], buf: u8[>..]&, eof_in: bool, max_line: i64) -> i64, bool {
    var eof = eof_in;
    var lines = 0;
    var scan = 0;
    var line_start = 0;
    loop {
        while true {
            let k = find_any(buf[scan..], NL);
            if k < 0 { scan = buf.len; break; }
            scan += k + 1;
            line_start = scan;
            lines++;
            if lines == BATCH { return scan, eof; }
        }
        // A line past the limit with no end in sight: -1 once it's at the front, for main to skip.
        if buf.len - line_start > max_line {
            return (if line_start > 0 { line_start } else { -1 }), eof;
        }
        if eof { return buf.len, eof; }
        let n = lx_read(fd, buf, BLOCK);
        guard n >= 0 else { io_fail("cannot read", name); }
        if n == 0 { eof = true; }
    }
    return buf.len, eof;
}

fn drop_front(buf: u8[>..]&, n: i64) {
    let k = buf.len - n;
    for i in k { buf[i] = buf[n + i]; }
    buf.pop_n(n);
}

// --- main -----------------------------------------------------------------------

fn format_id(name: u8[:]) -> i64 {
    if name == "hdfs" { return HDFS; }
    if name == "ssh" { return SSH; }
    if name == "apache" { return APACHE; }
    if name == "bgl" { return BGL; }
    return -1;
}

fn usage() {
    write_stderr("usage: sanitize [--out FILE] [--rejects FILE] [--max-reject-rate R] [--max-line BYTES] FORMAT PATH [FORMAT PATH ...]\n");
    exit(2);
}

fn main() {
    lx_ignore_sigpipe();
    let argv = args();
    var a = 1;
    var out_path: u8[>..] = [];
    var rejects_path: u8[>..] = [];
    var has_rate = false;
    var max_rate = 0.0;
    var max_line = 67108864;
    while a < argv.len && starts_with(argv[a], "--") {
        guard a + 1 < argv.len else { usage(); }
        if argv[a] == "--out" { out_path.append(argv[a + 1]); }
        else if argv[a] == "--rejects" { rejects_path.append(argv[a + 1]); }
        else if argv[a] == "--max-line" {
            let r, ok = parse_int(argv[a + 1]);
            guard ok else { usage(); }
            max_line = r;
        } else if argv[a] == "--max-reject-rate" {
            let r, ok = parse_flt(argv[a + 1]);
            guard ok else { usage(); }
            has_rate = true;
            max_rate = r;
        } else { usage(); }
        a += 2;
    }
    guard argv.len > a && (argv.len - a) % 2 == 0 else { usage(); }
    var i = a;
    while i < argv.len {
        guard format_id(argv[i]) >= 0 else { usage(); }
        i += 2;
    }

    var out_fd = 1;
    if out_path.len > 0 {
        tmp_path.append(out_path);
        tmp_path.append(".tmp");
        out_fd = lx_create(tmp_path);
        if out_fd < 0 {
            tmp_path.clear();
            io_fail("cannot create", out_path);
        }
    }
    let keep_rejects = rejects_path.len > 0;
    var rejects_fd = -1;
    if keep_rejects {
        rejects_fd = lx_create(rejects_path);
        guard rejects_fd >= 0 else { io_fail("cannot create", rejects_path); }
    }

    var total = Counts { lines: 0, kept: 0, dropped: 0, malformed: 0 };
    var out: u8[>..] = [];
    var rejects: u8[>..] = [];
    var buf: u8[>..] = [];
    while a < argv.len {
        let fmt = format_id(argv[a]);
        let name = argv[a + 1];
        let fd = if name == "-" { 0 } else { lx_open(name) };
        guard fd >= 0 else { io_fail("cannot open", name); }
        a += 2;
        buf.clear();
        var eof = false;
        loop {
            let end, e = next_batch(fd, name, buf, eof, max_line);
            eof = e;
            if end == 0 { break; }
            if end < 0 {
                total.lines++;
                total.malformed++;
                if keep_rejects {
                    rejects.clear();
                    rejects.append(buf[..4096]);
                    rejects.push('\n');
                    guard lx_write(rejects_fd, rejects) else { io_fail("cannot write", rejects_path); }
                }
                // Skip the rest of it.
                buf.clear();
                loop {
                    if eof { break; }
                    let n = lx_read(fd, buf, BLOCK);
                    guard n >= 0 else { io_fail("cannot read", name); }
                    if n == 0 { eof = true; break; }
                    let k = find_any(buf[..], NL);
                    if k >= 0 { drop_front(buf, k + 1); break; }
                    buf.clear();
                }
                continue;
            }
            out.clear();
            rejects.clear();
            process(fmt, buf[..end], out, rejects, keep_rejects, total, max_line);
            guard lx_write(out_fd, out) else { io_fail("cannot write", if out_path.len > 0 { out_path[..] } else { "stdout"[..] }); }
            if keep_rejects && rejects.len > 0 {
                guard lx_write(rejects_fd, rejects) else { io_fail("cannot write", rejects_path); }
            }
            drop_front(buf, end);
        }
        if fd != 0 { lx_close(fd); }
    }
    if keep_rejects { guard lx_close(rejects_fd) else { io_fail("cannot write", rejects_path); } }

    var line: u8[>..] = [];
    format(line, "lines=", total.lines, " kept=", total.kept, " dropped=", total.dropped, " malformed=", total.malformed, "\n");
    write_stderr(line);
    if has_rate && total.lines > 0 && (total.malformed as f64) / (total.lines as f64) > max_rate {
        if out_path.len > 0 { lx_close(out_fd); }
        abandon();
        write_stderr("sanitize: reject rate exceeded\n");
        exit(1);
    }
    if out_path.len > 0 {
        guard lx_close(out_fd) else { io_fail("cannot write", out_path); }
        guard rename_file(tmp_path, out_path) else { io_fail("cannot rename to", out_path); }
    }
}
