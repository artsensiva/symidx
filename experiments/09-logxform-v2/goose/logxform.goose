// logxform, a small log pipeline server: see ../SPEC.md.
//   goose build logxform.goose --cc clang --stack-reserve 1G -o logxform
// One worker per connection or tailed file: read a block, transform its whole lines, write them. Workers
// share nothing but the config they're given, so order holds per connection and a slow sink slows the sender.

import std;
import os;
import regex;

extern fn lx_signals();
extern fn lx_term() -> bool;
extern fn lx_hup_take() -> bool;
extern fn lx_listen(port: i64) -> i64;
extern fn lx_accept(fd: i64, ms: i64) -> i64;
extern fn lx_poll(fd: i64, ms: i64) -> i64;
extern fn lx_peer(fd: i64, host: u8[>..]&) -> i64;
extern fn lx_connect(host: const u8[:], port: i64) -> i64;
extern fn lx_read(fd: i64, out: u8[>..]&, n: i64) -> i64;
extern fn lx_pread(fd: i64, out: u8[>..]&, n: i64, off: i64) -> i64;
extern fn lx_write(fd: i64, data: const u8[:]) -> bool;
extern fn lx_close(fd: i64);
extern fn lx_open_log(path: const u8[:]) -> i64;
extern fn lx_open_rw(path: const u8[:]) -> i64;
extern fn lx_open_ro(path: const u8[:]) -> i64;
extern fn lx_size(fd: i64) -> i64;
extern fn lx_links(fd: i64) -> i64;
extern fn lx_inode(path: const u8[:]) -> i64;
extern fn lx_sync(fd: i64) -> bool;
extern fn lx_truncate(fd: i64) -> bool;
extern fn lx_get8(fd: i64) -> i64;
extern fn lx_put8(fd: i64, v: i64) -> bool;

let BLOCK = 262144;
let MAX_LINE = 67108864;
let MAX_BACKLOG = 4294967296;
let SYNC_NS = 500000000;

let SRC_TCP = 0;
let SRC_FILE = 1;
let XF_NONE = 0;
let XF_REGEX = 1;
let XF_SET = 2;
let XF_SYSLOG = 3;
let XF_SYSLOG_TAG = 4;
let XF_JSON = 5;
let SINK_TCP = 0;
let SINK_HTTP = 1;
let SINK_NULL = 2;

// Flat, so it can be handed to a worker.
struct Cfg {
    src: i64, port: i64, dir: u8[], prefix: u8[], exact: bool, data_dir: u8[],
    xf: i64, pat: u8[], rep: u8[], key: u8[], val: u8[],
    sink: i64, host: u8[], sport: i64, path: u8[],
    disk: bool, buf_dir: u8[]
}

fn fail(msg: u8[:]) {
    write_stderr(str("logxform: ", msg, "\n"));
    exit(2);
}

fn int_of(s: u8[:]) -> i64 {
    let v, ok = parse_int(s);
    guard ok else { fail(str("not a number: ", s)); }
    return v;
}

fn load(path: u8[:]) -> Cfg {
    var text: u8[>..] = [];
    guard read_file(path, text) else { fail(str("cannot read ", path)); }
    var src = SRC_TCP; var port = 9000; var dir: u8[>..] = []; var prefix: u8[>..] = []; var exact = true; var data_dir: u8[>..] = [];
    var xf = XF_NONE; var pat: u8[>..] = []; var rep: u8[>..] = []; var key: u8[>..] = []; var val: u8[>..] = [];
    var sink = SINK_TCP; var host: u8[>..] = []; var sport = 0; var hpath: u8[>..] = [];
    var disk = false; var buf_dir: u8[>..] = [];
    data_dir.append("/tmp");
    for raw in split(text[..], '\n') {
        let line = trim(raw);
        if line.len == 0 || line[0] == '#' { continue; }
        let t = split(line, ' ');
        if t[0] == "source" && t.len == 3 && t[1] == "tcp" {
            src = SRC_TCP;
            port = int_of(t[2]);
        } else if t[0] == "source" && t.len == 3 && t[1] == "file" {
            // /data/input.log follows that name, and /data/input.log* every name starting with it.
            src = SRC_FILE;
            var slash = t[2].len - 1;
            while slash >= 0 && t[2][slash] != '/' { slash--; }
            guard slash >= 0 else { fail("file source needs an absolute path"); }
            dir.clear(); dir.append(t[2][..slash]);
            prefix.clear();
            var e = t[2].len;
            exact = t[2][e - 1] != '*';
            if !exact { e--; }
            prefix.append(t[2][slash + 1..e]);
        } else if t[0] == "data_dir" && t.len == 2 {
            data_dir.clear(); data_dir.append(t[1]);
        } else if t[0] == "transform" && t.len >= 2 {
            if t[1] == "none" { xf = XF_NONE; }
            else if t[1] == "regex" && t.len == 4 { xf = XF_REGEX; pat.clear(); pat.append(t[2]); rep.clear(); rep.append(t[3]); }
            else if t[1] == "set_field" && t.len == 4 { xf = XF_SET; key.clear(); key.append(t[2]); val.clear(); val.append(t[3]); }
            else if t[1] == "syslog" { xf = XF_SYSLOG; }
            else if t[1] == "syslog_tag_debug" { xf = XF_SYSLOG_TAG; }
            else if t[1] == "json" { xf = XF_JSON; }
            else { fail(str("bad transform: ", line)); }
        } else if t[0] == "sink" && t.len >= 2 {
            if t[1] == "blackhole" { sink = SINK_NULL; }
            else if t[1] == "tcp" && t.len == 4 { sink = SINK_TCP; host.clear(); host.append(t[2]); sport = int_of(t[3]); }
            else if t[1] == "http" && t.len == 5 { sink = SINK_HTTP; host.clear(); host.append(t[2]); sport = int_of(t[3]); hpath.clear(); hpath.append(t[4]); }
            else { fail(str("bad sink: ", line)); }
        } else if t[0] == "buffer" && t.len == 3 && t[1] == "disk" {
            disk = true;
            buf_dir.clear(); buf_dir.append(t[2]);
        } else {
            fail(str("bad config line: ", line));
        }
    }
    return Cfg { src: src, port: port, dir: dir[..], prefix: prefix[..], exact: exact, data_dir: data_dir[..],
                 xf: xf, pat: pat[..], rep: rep[..], key: key[..], val: val[..],
                 sink: sink, host: host[..], sport: sport, path: hpath[..],
                 disk: disk, buf_dir: buf_dir[..] };
}

// --- JSON ---------------------------------------------------------------------------

fn json_special() -> ByteSet {
    var m: bool[256] = [false; 256];
    for i in 32 { m[i] = true; }
    for i in 128 { m[128 + i] = true; }
    m['"'] = true;
    m['\\'] = true;
    return byte_set(m);
}
let SPECIAL = json_special();
let HEXD = "0123456789abcdef";

// The length of a valid UTF-8 sequence at s[i], or 0.
fn utf8_len(s: u8[:], i: i64) -> i64 {
    let c = s[i];
    var n = 0;
    if c >= 0xC2 && c <= 0xDF { n = 2; }
    else if c >= 0xE0 && c <= 0xEF { n = 3; }
    else if c >= 0xF0 && c <= 0xF4 { n = 4; }
    else { return 0; }
    if i + n > s.len { return 0; }
    for k in n - 1 {
        if (s[i + 1 + k] & 0xC0) != 0x80 { return 0; }
    }
    if c == 0xE0 && s[i + 1] < 0xA0 { return 0; }
    if c == 0xED && s[i + 1] > 0x9F { return 0; }
    if c == 0xF0 && s[i + 1] < 0x90 { return 0; }
    if c == 0xF4 && s[i + 1] > 0x8F { return 0; }
    return n;
}

// s, escaped for a JSON string. Invalid UTF-8 becomes U+FFFD, as Vector's bytes decoder does.
fn put_esc(out: u8[>..]&, s: u8[:]) {
    var i = 0;
    while i < s.len {
        let k = find_any(s[i..], SPECIAL);
        if k < 0 { out.append(s[i..]); return; }
        out.append(s[i..i + k]);
        i += k;
        let c = s[i];
        if c >= 128 {
            let n = utf8_len(s, i);
            if n == 0 { out.append("\xEF\xBF\xBD"); i++; }
            else { out.append(s[i..i + n]); i += n; }
            continue;
        }
        i++;
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\r' { out.append("\\r"); }
        else if c == '\t' { out.append("\\t"); }
        else {
            out.append("\\u00");
            out.push(HEXD[c >> 4]);
            out.push(HEXD[c & 15]);
        }
    }
}

fn put_kv(out: u8[>..]&, key: u8[:], val: u8[:]) {
    out.push('"'); out.append(key); out.append("\":\""); put_esc(out, val); out.push('"');
}

// --- time ---------------------------------------------------------------------------

fn days_from_civil(y0: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y0 - 1 } else { y0 };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + (if m > 2 { -3 } else { 9 })) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

fn put2(out: u8[>..]&, v: i64) { out.push((48 + v / 10) as u8); out.push((48 + v % 10) as u8); }

// secs since the epoch, as YYYY-MM-DDTHH:MM:SS, then frac and Z.
fn put_utc(out: u8[>..]&, secs: i64, frac: u8[:]) {
    let days = (if secs >= 0 { secs } else { secs - 86399 }) / 86400;
    let rem = secs - days * 86400;
    let z = days + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (if m <= 2 { 1 } else { 0 });
    put2(out, y / 100); put2(out, y % 100); out.push('-'); put2(out, m); out.push('-'); put2(out, d); out.push('T');
    put2(out, rem / 3600); out.push(':'); put2(out, rem / 60 % 60); out.push(':'); put2(out, rem % 60);
    out.append(frac);
    out.push('Z');
}

fn dig(s: u8[:], i: i64, n: i64) -> i64 {
    var v = 0;
    for k in n {
        let c = s[i + k];
        if c < '0' || c > '9' { return -1; }
        v = v * 10 + (c - '0');
    }
    return v;
}

fn valid_time(mo: i64, d: i64, h: i64, mi: i64, s: i64) -> bool {
    return mo >= 1 && mo <= 12 && d >= 1 && d <= 31 && h >= 0 && h <= 23 && mi >= 0 && mi <= 59 && s >= 0 && s <= 60;
}

// An RFC 3339 time at t, written as UTC. False if it isn't one.
fn put_rfc3339(out: u8[>..]&, t: u8[:]) -> bool {
    if t.len < 20 || t[4] != '-' || t[7] != '-' || t[10] != 'T' || t[13] != ':' || t[16] != ':' { return false; }
    let y = dig(t, 0, 4); let mo = dig(t, 5, 2); let d = dig(t, 8, 2);
    let h = dig(t, 11, 2); let mi = dig(t, 14, 2); let s = dig(t, 17, 2);
    if y < 0 || !valid_time(mo, d, h, mi, s) { return false; }
    var i = 19;
    if t[i] == '.' {
        i++;
        let f0 = i;
        while i < t.len && t[i] >= '0' && t[i] <= '9' { i++; }
        if i == f0 { return false; }
    }
    let frac = t[19..i];
    if i >= t.len { return false; }
    var off = 0;
    if t[i] == 'Z' {
        if i + 1 != t.len { return false; }
    } else if t[i] == '+' || t[i] == '-' {
        if i + 6 != t.len || t[i + 3] != ':' { return false; }
        let oh = dig(t, i + 1, 2); let om = dig(t, i + 4, 2);
        if oh < 0 || om < 0 { return false; }
        off = (oh * 3600 + om * 60) * (if t[i] == '-' { -1 } else { 1 });
    } else {
        return false;
    }
    put_utc(out, days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - off, frac);
    return true;
}

let MONTHS = "JanFebMarAprMayJunJulAugSepOctNovDec";

// Mmm dd HH:MM:SS at t, in the current year, as UTC.
fn put_bsd(out: u8[>..]&, t: u8[:], year: i64) -> bool {
    if t.len != 15 || t[3] != ' ' || t[6] != ' ' || t[9] != ':' || t[12] != ':' { return false; }
    var mo = 0;
    for m in 12 {
        if MONTHS[m * 3] == t[0] && MONTHS[m * 3 + 1] == t[1] && MONTHS[m * 3 + 2] == t[2] { mo = m + 1; }
    }
    let d = if t[4] == ' ' { dig(t, 5, 1) } else { dig(t, 4, 2) };
    let h = dig(t, 7, 2); let mi = dig(t, 10, 2); let s = dig(t, 13, 2);
    if !valid_time(mo, d, h, mi, s) { return false; }
    put_utc(out, days_from_civil(year, mo, d) * 86400 + h * 3600 + mi * 60 + s, "");
    return true;
}

// --- syslog -------------------------------------------------------------------------

let FACS = ["kern"[..], "user", "mail", "daemon", "auth", "syslog", "lpr", "news", "uucp", "cron", "authpriv", "ftp",
             "ntp", "security", "console", "solaris-cron", "local0", "local1", "local2", "local3", "local4", "local5", "local6", "local7"];
let SEVS = ["emerg"[..], "alert", "crit", "err", "warning", "notice", "info", "debug"];

fn next_sp(s: u8[:], i: i64) -> i64 {
    var j = i;
    while j < s.len && s[j] != ' ' { j++; }
    return j;
}

fn all_digits(s: u8[:]) -> bool {
    if s.len == 0 || s.len > 18 { return false; }
    for c in s { if c < '0' || c > '9' { return false; } }
    return true;
}

fn put_proc(out: u8[>..]&, p: u8[:]) {
    out.append(",\"procid\":");
    if all_digits(p) { out.append(p); }
    else { out.push('"'); put_esc(out, p); out.push('"'); }
}

// One syslog line as JSON with the fields Vector's parse_syslog gives. False, with nothing written, if it isn't one.
fn put_syslog(out: u8[>..]&, s: u8[:], tag_debug: bool, year: i64) -> bool {
    if s.len < 5 || s[0] != '<' { return false; }
    var i = 1;
    var pri = 0;
    while i < s.len && i < 5 && s[i] >= '0' && s[i] <= '9' { pri = pri * 10 + (s[i] - '0'); i++; }
    if i == 1 || i >= s.len || s[i] != '>' || pri > 191 { return false; }
    i++;
    let sev = pri & 7;
    var ver = -1;
    var ts = s[0..0];
    var host = s[0..0]; var app = s[0..0]; var pid = s[0..0]; var mid = s[0..0];
    var body_at = 0;
    var sd = s[0..0];
    // RFC 5424: a version, then a space.
    if s[i] >= '1' && s[i] <= '9' && i + 1 < s.len && s[i + 1] == ' ' {
        ver = (s[i] - '0');
        var a = i + 2; var b = next_sp(s, a); ts = s[a..b];
        a = b + 1; if a > s.len { return false; } b = next_sp(s, a); host = s[a..b];
        a = b + 1; if a > s.len { return false; } b = next_sp(s, a); app = s[a..b];
        a = b + 1; if a > s.len { return false; } b = next_sp(s, a); pid = s[a..b];
        a = b + 1; if a > s.len { return false; } b = next_sp(s, a); mid = s[a..b];
        a = b + 1; if a >= s.len { return false; }
        if s[a] == '-' { b = a + 1; }
        else if s[a] == '[' {
            b = a;
            while b < s.len && !(s[b] == ']' && (b + 1 == s.len || s[b + 1] == ' ')) {
                if s[b] == '\\' { b++; }
                b++;
            }
            if b >= s.len { return false; }
            b++;
            sd = s[a..b];
        } else { return false; }
        body_at = if b < s.len { b + 1 } else { s.len };
    } else {
        var e = 0;
        if s[i] >= '0' && s[i] <= '9' { e = next_sp(s, i); }
        else { e = i + 15; if e > s.len { return false; } }
        ts = s[i..e];
        if e >= s.len { return false; }
        let a = e + 1;
        let b = next_sp(s, a);
        host = s[a..b];
        if b >= s.len { return false; }
        // tag[pid]: message, where the tag's optional.
        var c = b + 1;
        let tag0 = c;
        while c < s.len && s[c] != ' ' && s[c] != ':' && s[c] != '[' { c++; }
        app = s[tag0..c];
        if c < s.len && s[c] == '[' {
            let p0 = c + 1;
            var q = p0;
            while q < s.len && s[q] != ']' { q++; }
            if q >= s.len { return false; }
            pid = s[p0..q];
            c = q + 1;
        }
        if c < s.len && s[c] == ':' {
            c++;
            if c < s.len && s[c] == ' ' { c++; }
            body_at = c;
        } else {
            // No colon: nothing here is a tag, so all of it is the message.
            app = s[0..0]; pid = s[0..0];
            body_at = tag0;
        }
    }
    var when: u8[>..] = [];
    let ok = if ts.len == 15 && !(ts[0] >= '0' && ts[0] <= '9') { put_bsd(when, ts, year) } else { put_rfc3339(when, ts) };
    if !ok { return false; }
    out.push('{');
    if app.len > 0 && app != "-" { put_kv(out, "appname", app); out.push(','); }
    put_kv(out, "facility", FACS[pri >> 3]); out.push(',');
    if host.len > 0 && host != "-" { put_kv(out, "hostname", host); out.push(','); }
    put_kv(out, "message", s[body_at..]);
    if mid.len > 0 && mid != "-" { out.push(','); put_kv(out, "msgid", mid); }
    if pid.len > 0 && pid != "-" { put_proc(out, pid); }
    out.push(','); put_kv(out, "severity", SEVS[sev]);
    if sd.len > 0 { out.push(','); put_kv(out, "structured_data", sd); }
    out.append(",\"timestamp\":\"");
    out.append(when);
    out.push('"');
    if ver >= 0 { out.append(",\"version\":"); out.push((48 + ver) as u8); }
    if tag_debug && sev == 7 { out.append(",\"dropped\":true"); }
    out.append("}\n");
    return true;
}

// --- JSON input ---------------------------------------------------------------------

fn skip_ws(s: u8[:], i0: i64) -> i64 {
    var i = i0;
    while i < s.len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n') { i++; }
    return i;
}

fn skip_str(s: u8[:], i0: i64) -> i64 {
    var i = i0 + 1;
    while i < s.len {
        let c = s[i];
        if c == '"' { return i + 1; }
        if c < 32 { return -1; }
        i += if c == '\\' { 2 } else { 1 };
    }
    return -1;
}

recursive fn skip_value(s: u8[:], i0: i64, depth: i64) -> i64 {
    if depth > 128 { return -1; }
    var i = skip_ws(s, i0);
    if i >= s.len { return -1; }
    let c = s[i];
    if c == '"' { return skip_str(s, i); }
    if c == '{' || c == '[' {
        let close = if c == '{' { '}' } else { ']' };
        i = skip_ws(s, i + 1);
        if i < s.len && s[i] == close { return i + 1; }
        loop {
            if c == '{' {
                i = skip_ws(s, i);
                if i >= s.len || s[i] != '"' { return -1; }
                i = skip_str(s, i);
                if i < 0 { return -1; }
                i = skip_ws(s, i);
                if i >= s.len || s[i] != ':' { return -1; }
                i++;
            }
            i = skip_value(s, i, depth + 1);
            if i < 0 { return -1; }
            i = skip_ws(s, i);
            if i >= s.len { return -1; }
            if s[i] == close { return i + 1; }
            if s[i] != ',' { return -1; }
            i++;
        }
    }
    if starts_with(s[i..], "true") { return i + 4; }
    if starts_with(s[i..], "false") { return i + 5; }
    if starts_with(s[i..], "null") { return i + 4; }
    let n0 = i;
    while i < s.len && ((s[i] >= '0' && s[i] <= '9') || s[i] == '-' || s[i] == '+' || s[i] == '.' || s[i] == 'e' || s[i] == 'E') { i++; }
    return if i > n0 { i } else { -1 };
}

// --- transform ----------------------------------------------------------------------

// What a worker knows about its input, for the fields Vector adds.
struct Ctx { host: u8[], port: i64 }

let NL = byte_set("\n");

// The whole lines in data, transformed, onto out.
fn transform(cfg: Cfg&, re: regex::Regex&, ctx: Ctx&, data: u8[:], out: u8[>..]&) {
    var stamp: u8[>..] = [];
    var year = 2026;
    if cfg.xf == XF_SET || cfg.xf == XF_SYSLOG || cfg.xf == XF_SYSLOG_TAG {
        let ns = time_ns();
        put_utc(stamp, ns / 1000000000, "");
        year = dig(stamp[..], 0, 4);
    }
    var at = 0;
    while at < data.len {
        var e = find_any(data[at..], NL);
        e = if e < 0 { data.len } else { at + e };
        var s = data[at..e];
        at = e + 1;
        if s.len > 0 && s[s.len - 1] == '\r' { s = s[..s.len - 1]; }
        if cfg.xf == XF_REGEX {
            out.append("{\"message\":\"");
            var last = 0;
            regex::each_match(re, s) { a, b =>
                put_esc(out, s[last..a]);
                put_esc(out, cfg.rep);
                last = b;
            };
            put_esc(out, s[last..]);
            out.append("\"}\n");
        } else if cfg.xf == XF_SET {
            out.push('{');
            put_kv(out, "host", ctx.host); out.push(',');
            put_kv(out, "message", s);
            format(out, ",\"port\":", ctx.port, ",");
            put_kv(out, cfg.key, cfg.val);
            out.append(",\"source_type\":\"socket\",\"timestamp\":\"");
            out.append(stamp);
            out.append("\"}\n");
        } else if cfg.xf == XF_SYSLOG || cfg.xf == XF_SYSLOG_TAG {
            if !put_syslog(out, s, cfg.xf == XF_SYSLOG_TAG, year) {
                // As Vector does with an event its parser aborts on: pass the original through.
                out.push('{'); put_kv(out, "message", s); out.append("}\n");
            }
        } else {
            // XF_JSON: a line that's one JSON value goes through as it is; anything else is wrapped.
            let z = skip_value(s, 0, 0);
            if z >= 0 && skip_ws(s, z) == s.len { out.append(s); out.push('\n'); }
            else { out.push('{'); put_kv(out, "message", s); out.append("}\n"); }
        }
    }
}

// --- sinks --------------------------------------------------------------------------

struct Sink { fd: i64 }

fn http_post(cfg: Cfg&, fd: i64, body: u8[:]) -> bool {
    var head: u8[>..] = [];
    format(head, "POST ", cfg.path, " HTTP/1.1\r\nHost: ", cfg.host, "\r\nContent-Type: text/plain\r\nContent-Length: ", body.len, "\r\n\r\n");
    if !lx_write(fd, head) || !lx_write(fd, body) { return false; }
    var r: u8[>..] = [];
    var hdr_end = -1;
    while hdr_end < 0 {
        let n = lx_read(fd, r, 65536);
        if n <= 0 { return false; }
        hdr_end = find(r[..], "\r\n\r\n"[..]);
    }
    if r.len < 12 || r[9] != '2' { return false; }
    // The body, so the next response starts clean.
    var clen = 0;
    let lower = r[..hdr_end];
    for raw in split(lower, "\r\n"[..]) {
        if raw.len > 15 && (raw[0] == 'C' || raw[0] == 'c') && (raw[8] == 'L' || raw[8] == 'l') && raw[14] == ':' {
            clen = int_of(trim(raw[15..]));
        }
    }
    let want = hdr_end + 4 + clen;
    while r.len < want {
        let n = lx_read(fd, r, 65536);
        if n <= 0 { return false; }
    }
    return true;
}

// One attempt: connected and delivered, or not.
fn send_once(cfg: Cfg&, sink: Sink&, data: u8[:]) -> bool {
    if cfg.sink == SINK_NULL { return true; }
    if sink.fd < 0 {
        sink.fd = lx_connect(cfg.host, cfg.sport);
        if sink.fd < 0 { return false; }
    }
    let ok = if cfg.sink == SINK_HTTP { http_post(cfg, sink.fd, data) } else { lx_write(sink.fd, data) };
    if !ok { lx_close(sink.fd); sink.fd = -1; }
    return ok;
}

// Keeps trying until delivered, or until asked to stop. A slow or absent sink holds up the reader, which is the backpressure.
fn send(cfg: Cfg&, sink: Sink&, data: u8[:]) -> bool {
    while !send_once(cfg, sink, data) {
        if lx_term() { return false; }
        sleep_ms(100);
    }
    return true;
}

fn last_nl(b: u8[:]) -> i64 {
    var i = b.len - 1;
    while i >= 0 {
        if b[i] == '\n' { return i; }
        i--;
    }
    return -1;
}

fn drop_front(buf: u8[>..]&, n: i64) {
    let k = buf.len - n;
    for i in k { buf[i] = buf[n + i]; }
    buf.pop_n(n);
}

fn make_re(cfg: Cfg&) -> regex::Regex {
    return regex::compile(if cfg.xf == XF_REGEX { cfg.pat[..] } else { "x"[..] });
}

// --- workers ------------------------------------------------------------------------

thread_fn conn_worker(fd: i64, cfg: Cfg) {
    var re = make_re(cfg);
    var peer: u8[>..] = [];
    let pport = lx_peer(fd, peer);
    let ctx = Ctx { host: peer[..], port: pport };
    var buf: u8[>..] = [];
    var out: u8[>..] = [];
    var sink = Sink { fd: -1 };
    var skipping = false;
    var alive = true;
    while alive {
        let n = lx_read(fd, buf, BLOCK);
        if n <= 0 {
            alive = false;
            if buf.len > 0 && !skipping { buf.push('\n'); }
        }
        let nl = last_nl(buf[buf.len - n * (if alive { 1 } else { 0 }) ..]);
        let e = if alive { (if nl < 0 { 0 } else { buf.len - n + nl + 1 }) } else { buf.len };
        if e == 0 {
            if buf.len > MAX_LINE { write_stderr("logxform: line over the limit dropped\n"); buf.clear(); skipping = true; }
            continue;
        }
        var from = 0;
        if skipping {
            from = find_any(buf[..e], NL) + 1;
            skipping = false;
        }
        if from < e {
            if cfg.xf == XF_NONE {
                if !send(cfg, sink, buf[from..e]) { break; }
            } else {
                out.clear();
                transform(cfg, re, ctx, buf[from..e], out);
                if !send(cfg, sink, out) { break; }
            }
        }
        drop_front(buf, e);
    }
    lx_close(fd);
    if sink.fd >= 0 { lx_close(sink.fd); }
}

// The disk buffer: a segment file holding transformed lines, and an acknowledged offset beside it. Whatever's read from
// fd goes to the segment before it's sent, so a restart or SIGKILL loses nothing the program had read. fd < 0 replays only.
fn disk_loop(fd: i64, base: u8[:], cfg: Cfg&, re: regex::Regex&, ctx: Ctx&) {
    let seg = lx_open_log(str(base, ".seg"));
    let ack = lx_open_rw(str(base, ".ack"));
    guard seg >= 0 && ack >= 0 else { fail(str("cannot open buffer ", base)); }
    var size = lx_size(seg);
    var acked = lx_get8(ack);
    if acked > size { acked = 0; }
    var buf: u8[>..] = [];
    var out: u8[>..] = [];
    var pend: u8[>..] = [];
    var sink = Sink { fd: -1 };
    var eof = fd < 0;
    var skipping = false;
    var last_sync = clock_ns();
    var dirty = false;
    loop {
        var idle = true;
        if !eof && size - acked < MAX_BACKLOG {
            let ready = lx_poll(fd, if size > acked { 0 } else { 100 });
            if ready > 0 {
                let n = lx_read(fd, buf, BLOCK);
                idle = false;
                if n <= 0 {
                    eof = true;
                    if buf.len > 0 && !skipping { buf.push('\n'); }
                }
                let nl = last_nl(buf[..]);
                let e = if nl < 0 { 0 } else { nl + 1 };
                if e == 0 {
                    if buf.len > MAX_LINE { write_stderr("logxform: line over the limit dropped\n"); buf.clear(); skipping = true; }
                } else {
                    var from = 0;
                    if skipping { from = find_any(buf[..e], NL) + 1; skipping = false; }
                    if from < e {
                        var ok = true;
                        if cfg.xf == XF_NONE {
                            ok = lx_write(seg, buf[from..e]);
                            size += e - from;
                        } else {
                            out.clear();
                            transform(cfg, re, ctx, buf[from..e], out);
                            ok = lx_write(seg, out);
                            size += out.len;
                        }
                        guard ok else { fail(str("cannot write buffer ", base)); }
                        dirty = true;
                    }
                    drop_front(buf, e);
                }
            }
        }
        if dirty && clock_ns() - last_sync > SYNC_NS {
            lx_sync(seg);
            last_sync = clock_ns();
            dirty = false;
        }
        if size > acked {
            pend.clear();
            let want = min(size - acked, BLOCK * 4);
            let got = lx_pread(seg, pend, want, acked);
            let nl = last_nl(pend[..]);
            if got > 0 && nl >= 0 {
                if send_once(cfg, sink, pend[..nl + 1]) {
                    acked += nl + 1;
                    lx_put8(ack, acked);
                    idle = false;
                }
            }
        }
        if acked == size && size > 268435456 {
            lx_sync(seg);
            lx_truncate(seg);
            lx_put8(ack, 0);
            acked = 0;
            size = 0;
        }
        if eof && acked == size { break; }
        if lx_term() && (eof || lx_poll(fd, 0) <= 0) { lx_sync(seg); return; }
        if idle && size > acked { sleep_ms(50); }
    }
    lx_close(seg);
    lx_close(ack);
    delete_file(str(base, ".seg"));
    delete_file(str(base, ".ack"));
    if sink.fd >= 0 { lx_close(sink.fd); }
}

thread_fn disk_worker(fd: i64, id: i64, cfg: Cfg) {
    var re = make_re(cfg);
    var peer: u8[>..] = [];
    let pport = lx_peer(fd, peer);
    let ctx = Ctx { host: peer[..], port: pport };
    var base: u8[>..] = [];
    format(base, cfg.buf_dir, "/c", id);
    disk_loop(fd, base[..], cfg, re, ctx);
    lx_close(fd);
}

thread_fn replay_worker(base: u8[], cfg: Cfg) {
    var re = make_re(cfg);
    let ctx = Ctx { host: "", port: 0 };
    disk_loop(-1, base, cfg, re, ctx);
}

// One tailed file, followed by inode: a rename doesn't change what it reads, a shrink starts it over, and the checkpoint
// holds the offset of what's been delivered.
thread_fn tail_worker(path: u8[], inode: i64, cfg: Cfg) {
    var re = make_re(cfg);
    let ctx = Ctx { host: "", port: 0 };
    let fd = lx_open_ro(path);
    if fd < 0 { return; }
    let ckpt = lx_open_rw(str(cfg.data_dir, "/ino-", inode, ".ckpt"));
    guard ckpt >= 0 else { fail("cannot open a checkpoint"); }
    var off = lx_get8(ckpt);
    var buf: u8[>..] = [];
    var out: u8[>..] = [];
    var sink = Sink { fd: -1 };
    var idle_ms = 0;
    while !lx_term() {
        let size = lx_size(fd);
        if size < off { off = 0; buf.clear(); lx_put8(ckpt, 0); }
        if size == off {
            if lx_links(fd) == 0 { break; }
            sleep_ms(10);
            continue;
        }
        buf.clear();
        let n = lx_pread(fd, buf, BLOCK, off);
        if n <= 0 { sleep_ms(10); continue; }
        let nl = last_nl(buf[..]);
        if nl < 0 {
            if buf.len >= BLOCK { fail("a tailed line is longer than the block size"); }
            // A line still being written. If the file's been unlinked, it won't get any longer.
            if lx_links(fd) == 0 { buf.push('\n'); } else { sleep_ms(10); continue; }
        }
        let e = if nl < 0 { buf.len } else { nl + 1 };
        let ok = if cfg.xf == XF_NONE { send(cfg, sink, buf[..e]) } else {
            out.clear();
            transform(cfg, re, ctx, buf[..e], out);
            send(cfg, sink, out)
        };
        if !ok { break; }
        off += if nl < 0 { n } else { e };
        lx_put8(ckpt, off);
    }
    lx_close(fd);
    lx_close(ckpt);
    if sink.fd >= 0 { lx_close(sink.fd); }
}

// --- main ---------------------------------------------------------------------------

// Serves until asked to stop or reload. New connections get a new config; ones in progress keep what they started with.
fn serve_tcp(cfg: Cfg&, lfd: i64, id0: i64) -> i64 {
    var id = id0;
    while !lx_term() && !lx_hup_take() {
        let c = lx_accept(lfd, 200);
        if c < 0 { continue; }
        id++;
        if cfg.disk { thread_spawn(disk_worker, c, id, copy(cfg)); }
        else { thread_spawn(conn_worker, c, copy(cfg)); }
    }
    return id;
}

fn run_tcp(cfg_path: u8[:], port: i64) {
    let lfd = lx_listen(port);
    guard lfd >= 0 else { fail("cannot listen"); }
    var id = time_ns();
    while !lx_term() {
        let cfg = load(cfg_path);
        id = serve_tcp(cfg, lfd, id);
        if !lx_term() { write_stderr("logxform: config reloaded\n"); }
    }
    lx_close(lfd);
}

fn serve_files(cfg: Cfg&) {
    var seen: i64[>..] = [];
    while !lx_term() {
        lx_hup_take();
        var names: u8[>..] = [];
        if list_dir(cfg.dir, names) {
            for name in split(names[..], '\n') {
                if name.len == 0 || !starts_with(name, cfg.prefix) || (cfg.exact && name.len != cfg.prefix.len) { continue; }
                let full = str(cfg.dir, "/", name);
                let ino = lx_inode(full);
                if ino < 0 || contains(seen[..], ino) { continue; }
                seen.push(ino);
                thread_spawn(tail_worker, full[..], ino, copy(cfg));
            }
        }
        sleep_ms(20);
    }
}

fn main() {
    let argv = args();
    guard argv.len == 3 && argv[1] == "--config" else { fail("usage: logxform --config FILE"); }
    lx_signals();
    let cfg = load(argv[2]);
    if cfg.disk {
        make_dir(cfg.buf_dir);
        var names: u8[>..] = [];
        if list_dir(cfg.buf_dir, names) {
            for name in split(names[..], '\n') {
                if !ends_with(name, ".seg") { continue; }
                let base = str(cfg.buf_dir, "/", name[..name.len - 4]);
                thread_spawn(replay_worker, base[..], copy(cfg));
            }
        }
    }
    if cfg.src == SRC_FILE { make_dir(cfg.data_dir); serve_files(cfg); }
    else { run_tcp(argv[2], cfg.port); }
    sleep_ms(500);
    exit(0);
}
