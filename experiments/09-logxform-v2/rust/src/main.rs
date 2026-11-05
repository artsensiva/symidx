//! logxform, a small log pipeline server: see ../../SPEC.md. The same design as ../../goose/logxform.goose.
//! One worker per connection or tailed file: read a block, transform its whole lines, write them. Workers
//! share nothing but the config they're given, so order holds per connection and a slow sink slows the sender.

use memchr::{memchr, memmem, memrchr};
use regex::bytes::Regex;
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::os::unix::io::AsRawFd;
use std::path::Path;
use std::process::exit;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const BLOCK: usize = 262144;
const MAX_LINE: usize = 67108864;
const SYNC_EVERY: Duration = Duration::from_millis(500);

static TERM: AtomicBool = AtomicBool::new(false);
static HUP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_term(_: libc::c_int) {
    TERM.store(true, Ordering::Relaxed);
}
extern "C" fn on_hup(_: libc::c_int) {
    HUP.store(true, Ordering::Relaxed);
}

fn term() -> bool {
    TERM.load(Ordering::Relaxed)
}

#[derive(Clone, Copy, PartialEq)]
enum Xf {
    None,
    Regex,
    Set,
    Syslog,
    SyslogTag,
    Json,
}

#[derive(Clone, Copy, PartialEq)]
enum SinkKind {
    Tcp,
    Http,
    Null,
}

#[derive(Clone)]
struct Cfg {
    file: bool,
    port: u16,
    dir: String,
    prefix: String,
    exact: bool,
    data_dir: String,
    xf: Xf,
    re: Option<Regex>,
    rep: Vec<u8>,
    key: Vec<u8>,
    val: Vec<u8>,
    sink: SinkKind,
    host: String,
    sport: u16,
    path: String,
    disk: bool,
    buf_dir: String,
}

fn fail(msg: &str) -> ! {
    eprintln!("logxform: {msg}");
    exit(2)
}

fn int_of(s: &str) -> u16 {
    s.parse().unwrap_or_else(|_| fail(&format!("not a number: {s}")))
}

fn load(path: &str) -> Cfg {
    let text = fs::read_to_string(path).unwrap_or_else(|_| fail(&format!("cannot read {path}")));
    let mut c = Cfg {
        file: false,
        port: 9000,
        dir: String::new(),
        prefix: String::new(),
        exact: true,
        data_dir: "/tmp".into(),
        xf: Xf::None,
        re: None,
        rep: vec![],
        key: vec![],
        val: vec![],
        sink: SinkKind::Tcp,
        host: String::new(),
        sport: 0,
        path: String::new(),
        disk: false,
        buf_dir: String::new(),
    };
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let t: Vec<&str> = line.split(' ').collect();
        match (t[0], t.len()) {
            ("source", 3) if t[1] == "tcp" => {
                c.file = false;
                c.port = int_of(t[2]);
            }
            ("source", 3) if t[1] == "file" => {
                // /data/input.log follows that name, and /data/input.log* every name starting with it.
                c.file = true;
                let slash = t[2].rfind('/').unwrap_or_else(|| fail("file source needs an absolute path"));
                c.dir = t[2][..slash].into();
                c.exact = !t[2].ends_with('*');
                c.prefix = t[2][slash + 1..].trim_end_matches('*').into();
            }
            ("data_dir", 2) => c.data_dir = t[1].into(),
            ("transform", _) if t.len() >= 2 => match (t[1], t.len()) {
                ("none", _) => c.xf = Xf::None,
                ("regex", 4) => {
                    c.xf = Xf::Regex;
                    c.re = Some(Regex::new(t[2]).unwrap_or_else(|e| fail(&format!("bad regex: {e}"))));
                    c.rep = t[3].into();
                }
                ("set_field", 4) => {
                    c.xf = Xf::Set;
                    c.key = t[2].into();
                    c.val = t[3].into();
                }
                ("syslog", _) => c.xf = Xf::Syslog,
                ("syslog_tag_debug", _) => c.xf = Xf::SyslogTag,
                ("json", _) => c.xf = Xf::Json,
                _ => fail(&format!("bad transform: {line}")),
            },
            ("sink", _) if t.len() >= 2 => match (t[1], t.len()) {
                ("blackhole", _) => c.sink = SinkKind::Null,
                ("tcp", 4) => {
                    c.sink = SinkKind::Tcp;
                    c.host = t[2].into();
                    c.sport = int_of(t[3]);
                }
                ("http", 5) => {
                    c.sink = SinkKind::Http;
                    c.host = t[2].into();
                    c.sport = int_of(t[3]);
                    c.path = t[4].into();
                }
                _ => fail(&format!("bad sink: {line}")),
            },
            ("buffer", 3) if t[1] == "disk" => {
                c.disk = true;
                c.buf_dir = t[2].into();
            }
            _ => fail(&format!("bad config line: {line}")),
        }
    }
    c
}

// --- JSON ---------------------------------------------------------------------------

const fn specials() -> [bool; 256] {
    let mut m = [false; 256];
    let mut i = 0;
    while i < 256 {
        m[i] = i < 32 || i >= 128 || i == b'"' as usize || i == b'\\' as usize;
        i += 1;
    }
    m
}
static SPECIAL: [bool; 256] = specials();
const HEXD: &[u8] = b"0123456789abcdef";

/// The length of a valid UTF-8 sequence at s[i], or 0.
fn utf8_len(s: &[u8], i: usize) -> usize {
    let c = s[i];
    let n = match c {
        0xC2..=0xDF => 2,
        0xE0..=0xEF => 3,
        0xF0..=0xF4 => 4,
        _ => return 0,
    };
    if i + n > s.len() || s[i + 1..i + n].iter().any(|b| b & 0xC0 != 0x80) {
        return 0;
    }
    let b = s[i + 1];
    if (c == 0xE0 && b < 0xA0) || (c == 0xED && b > 0x9F) || (c == 0xF0 && b < 0x90) || (c == 0xF4 && b > 0x8F) {
        return 0;
    }
    n
}

/// The first byte that needs escaping. Goose's find_any is SIMD, so this is too, for a fair comparison.
#[cfg(target_arch = "x86_64")]
fn find_special(s: &[u8]) -> Option<usize> {
    use std::arch::x86_64::*;
    let mut i = 0;
    // SAFETY: SSE2 is part of x86_64, and each load reads 16 bytes that the loop condition shows are in s.
    unsafe {
        let (quote, slash, space) = (_mm_set1_epi8(b'"' as i8), _mm_set1_epi8(b'\\' as i8), _mm_set1_epi8(32));
        while i + 16 <= s.len() {
            let v = _mm_loadu_si128(s.as_ptr().add(i) as *const __m128i);
            // A signed compare, so bytes from 128 up count as below space too.
            let hit = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, quote), _mm_cmpeq_epi8(v, slash)), _mm_cmplt_epi8(v, space));
            let m = _mm_movemask_epi8(hit);
            if m != 0 {
                return Some(i + m.trailing_zeros() as usize);
            }
            i += 16;
        }
    }
    s[i..].iter().position(|&b| SPECIAL[b as usize]).map(|k| i + k)
}

#[cfg(not(target_arch = "x86_64"))]
fn find_special(s: &[u8]) -> Option<usize> {
    s.iter().position(|&b| SPECIAL[b as usize])
}

/// s, escaped for a JSON string. Invalid UTF-8 becomes U+FFFD, as Vector's bytes decoder does.
fn put_esc(out: &mut Vec<u8>, s: &[u8]) {
    let mut i = 0;
    while i < s.len() {
        let Some(k) = find_special(&s[i..]) else {
            out.extend_from_slice(&s[i..]);
            return;
        };
        out.extend_from_slice(&s[i..i + k]);
        i += k;
        let c = s[i];
        if c >= 128 {
            let n = utf8_len(s, i);
            if n == 0 {
                out.extend_from_slice(b"\xEF\xBF\xBD");
                i += 1;
            } else {
                out.extend_from_slice(&s[i..i + n]);
                i += n;
            }
            continue;
        }
        i += 1;
        match c {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            _ => {
                out.extend_from_slice(b"\\u00");
                out.push(HEXD[(c >> 4) as usize]);
                out.push(HEXD[(c & 15) as usize]);
            }
        }
    }
}

fn put_kv(out: &mut Vec<u8>, key: &[u8], val: &[u8]) {
    out.push(b'"');
    out.extend_from_slice(key);
    out.extend_from_slice(b"\":\"");
    put_esc(out, val);
    out.push(b'"');
}

// --- time ---------------------------------------------------------------------------

fn days_from_civil(y0: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y0 - 1 } else { y0 };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + (if m > 2 { -3 } else { 9 })) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn put2(out: &mut Vec<u8>, v: i64) {
    out.push(48 + (v / 10) as u8);
    out.push(48 + (v % 10) as u8);
}

/// secs since the epoch, as YYYY-MM-DDTHH:MM:SS, then frac and Z.
fn put_utc(out: &mut Vec<u8>, secs: i64, frac: &[u8]) {
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
    put2(out, y / 100);
    put2(out, y % 100);
    out.push(b'-');
    put2(out, m);
    out.push(b'-');
    put2(out, d);
    out.push(b'T');
    put2(out, rem / 3600);
    out.push(b':');
    put2(out, rem / 60 % 60);
    out.push(b':');
    put2(out, rem % 60);
    out.extend_from_slice(frac);
    out.push(b'Z');
}

fn dig(s: &[u8], i: usize, n: usize) -> i64 {
    let mut v = 0;
    for &c in &s[i..i + n] {
        if !c.is_ascii_digit() {
            return -1;
        }
        v = v * 10 + (c - b'0') as i64;
    }
    v
}

fn valid_time(mo: i64, d: i64, h: i64, mi: i64, s: i64) -> bool {
    (1..=12).contains(&mo) && (1..=31).contains(&d) && (0..=23).contains(&h) && (0..=59).contains(&mi) && (0..=60).contains(&s)
}

/// An RFC 3339 time at t, written as UTC. False if it isn't one.
fn put_rfc3339(out: &mut Vec<u8>, t: &[u8]) -> bool {
    if t.len() < 20 || t[4] != b'-' || t[7] != b'-' || t[10] != b'T' || t[13] != b':' || t[16] != b':' {
        return false;
    }
    let (y, mo, d) = (dig(t, 0, 4), dig(t, 5, 2), dig(t, 8, 2));
    let (h, mi, s) = (dig(t, 11, 2), dig(t, 14, 2), dig(t, 17, 2));
    if y < 0 || !valid_time(mo, d, h, mi, s) {
        return false;
    }
    let mut i = 19;
    if t[i] == b'.' {
        i += 1;
        let f0 = i;
        while i < t.len() && t[i].is_ascii_digit() {
            i += 1;
        }
        if i == f0 {
            return false;
        }
    }
    let frac = &t[19..i];
    if i >= t.len() {
        return false;
    }
    let mut off = 0;
    if t[i] == b'Z' {
        if i + 1 != t.len() {
            return false;
        }
    } else if t[i] == b'+' || t[i] == b'-' {
        if i + 6 != t.len() || t[i + 3] != b':' {
            return false;
        }
        let (oh, om) = (dig(t, i + 1, 2), dig(t, i + 4, 2));
        if oh < 0 || om < 0 {
            return false;
        }
        off = (oh * 3600 + om * 60) * (if t[i] == b'-' { -1 } else { 1 });
    } else {
        return false;
    }
    put_utc(out, days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - off, frac);
    true
}

const MONTHS: &[u8] = b"JanFebMarAprMayJunJulAugSepOctNovDec";

/// Mmm dd HH:MM:SS at t, in the current year, as UTC.
fn put_bsd(out: &mut Vec<u8>, t: &[u8], year: i64) -> bool {
    if t.len() != 15 || t[3] != b' ' || t[6] != b' ' || t[9] != b':' || t[12] != b':' {
        return false;
    }
    let mo = (0..12).find(|m| MONTHS[m * 3..m * 3 + 3] == t[..3]).map_or(0, |m| m as i64 + 1);
    let d = if t[4] == b' ' { dig(t, 5, 1) } else { dig(t, 4, 2) };
    let (h, mi, s) = (dig(t, 7, 2), dig(t, 10, 2), dig(t, 13, 2));
    if !valid_time(mo, d, h, mi, s) {
        return false;
    }
    put_utc(out, days_from_civil(year, mo, d) * 86400 + h * 3600 + mi * 60 + s, b"");
    true
}

// --- syslog -------------------------------------------------------------------------

const FACS: [&[u8]; 24] = [
    b"kern", b"user", b"mail", b"daemon", b"auth", b"syslog", b"lpr", b"news", b"uucp", b"cron", b"authpriv", b"ftp", b"ntp", b"audit", b"alert",
    b"clockd", b"local0", b"local1", b"local2", b"local3", b"local4", b"local5", b"local6", b"local7",
];
const SEVS: [&[u8]; 8] = [b"emerg", b"alert", b"crit", b"err", b"warning", b"notice", b"info", b"debug"];

fn next_sp(s: &[u8], i: usize) -> usize {
    let mut j = i;
    while j < s.len() && s[j] != b' ' {
        j += 1;
    }
    j
}

fn all_digits(s: &[u8]) -> bool {
    !s.is_empty() && s.len() <= 18 && s.iter().all(|c| c.is_ascii_digit())
}

fn put_proc(out: &mut Vec<u8>, p: &[u8]) {
    out.extend_from_slice(b",\"procid\":");
    if all_digits(p) {
        out.extend_from_slice(p);
    } else {
        out.push(b'"');
        put_esc(out, p);
        out.push(b'"');
    }
}

/// RFC 5424 structured data as JSON members, each element an object: [id a="1" b="2"] gives "id":{"a":"1","b":"2"}. False if malformed.
fn put_sd(out: &mut Vec<u8>, s: &[u8]) -> bool {
    let mut i = 0;
    while i < s.len() {
        if s[i] != b'[' {
            return false;
        }
        i += 1;
        let id0 = i;
        while i < s.len() && s[i] != b' ' && s[i] != b']' {
            i += 1;
        }
        if i >= s.len() || i == id0 {
            return false;
        }
        out.extend_from_slice(b",\"");
        put_esc(out, &s[id0..i]);
        out.extend_from_slice(b"\":{");
        let mut first = true;
        while i < s.len() && s[i] == b' ' {
            i += 1;
            let k0 = i;
            while i < s.len() && s[i] != b'=' {
                i += 1;
            }
            if i + 1 >= s.len() || s[i + 1] != b'"' {
                return false;
            }
            if !first {
                out.push(b',');
            }
            first = false;
            out.push(b'"');
            put_esc(out, &s[k0..i]);
            out.extend_from_slice(b"\":\"");
            i += 2;
            let mut v0 = i;
            while i < s.len() && s[i] != b'"' {
                // A backslash protects the next byte, and isn't part of the value.
                if s[i] == b'\\' && i + 1 < s.len() && matches!(s[i + 1], b'"' | b'\\' | b']') {
                    put_esc(out, &s[v0..i]);
                    v0 = i + 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if i >= s.len() {
                return false;
            }
            put_esc(out, &s[v0..i]);
            out.push(b'"');
            i += 1;
        }
        if i >= s.len() || s[i] != b']' {
            return false;
        }
        i += 1;
        out.push(b'}');
    }
    true
}

/// One syslog line as JSON with the fields Vector's parse_syslog gives. False, with nothing written, if it isn't one.
fn put_syslog(out: &mut Vec<u8>, s: &[u8], tag_debug: bool, year: i64) -> bool {
    if s.len() < 5 || s[0] != b'<' {
        return false;
    }
    let mut i = 1;
    let mut pri = 0usize;
    while i < s.len() && i < 5 && s[i].is_ascii_digit() {
        pri = pri * 10 + (s[i] - b'0') as usize;
        i += 1;
    }
    if i == 1 || i >= s.len() || s[i] != b'>' || pri > 191 {
        return false;
    }
    i += 1;
    if i >= s.len() {
        return false;
    }
    let sev = pri & 7;
    let mut ver: i64 = -1;
    let ts: &[u8];
    let host: &[u8];
    let mut app: &[u8] = b"";
    let mut pid: &[u8] = b"";
    let mut mid: &[u8] = b"";
    let mut sd: &[u8] = b"";
    let body_at;
    // RFC 5424: a version, then a space.
    if (b'1'..=b'9').contains(&s[i]) && i + 1 < s.len() && s[i + 1] == b' ' {
        ver = (s[i] - b'0') as i64;
        let mut a = i + 2;
        let mut b = next_sp(s, a);
        ts = &s[a..b];
        a = b + 1;
        if a > s.len() {
            return false;
        }
        b = next_sp(s, a);
        host = &s[a..b];
        a = b + 1;
        if a > s.len() {
            return false;
        }
        b = next_sp(s, a);
        app = &s[a..b];
        a = b + 1;
        if a > s.len() {
            return false;
        }
        b = next_sp(s, a);
        pid = &s[a..b];
        a = b + 1;
        if a > s.len() {
            return false;
        }
        b = next_sp(s, a);
        mid = &s[a..b];
        a = b + 1;
        if a >= s.len() {
            return false;
        }
        if s[a] == b'-' {
            b = a + 1;
        } else if s[a] == b'[' {
            b = a;
            while b < s.len() && !(s[b] == b']' && (b + 1 == s.len() || s[b + 1] == b' ')) {
                if s[b] == b'\\' {
                    b += 1;
                }
                b += 1;
            }
            if b >= s.len() {
                return false;
            }
            b += 1;
            sd = &s[a..b];
        } else {
            return false;
        }
        body_at = if b < s.len() { b + 1 } else { s.len() };
    } else {
        let e = if s[i].is_ascii_digit() {
            next_sp(s, i)
        } else {
            if i + 15 > s.len() {
                return false;
            }
            i + 15
        };
        ts = &s[i..e];
        if e >= s.len() {
            return false;
        }
        let a = e + 1;
        let b = next_sp(s, a);
        host = &s[a..b];
        // tag[pid]: message, where the colon's optional. Nothing after the host is an empty message.
        let tag0 = (b + 1).min(s.len());
        let mut c = tag0;
        while c < s.len() && s[c] != b' ' && s[c] != b':' && s[c] != b'[' {
            c += 1;
        }
        app = &s[tag0..c];
        if c < s.len() && s[c] == b'[' {
            let p0 = c + 1;
            let mut q = p0;
            while q < s.len() && s[q] != b']' {
                q += 1;
            }
            if q >= s.len() {
                return false;
            }
            pid = &s[p0..q];
            c = q + 1;
        }
        if c < s.len() && s[c] == b':' {
            c += 1;
            while c < s.len() && s[c] == b' ' {
                c += 1;
            }
            body_at = c;
        } else {
            while c < s.len() && s[c] == b' ' {
                c += 1;
            }
            body_at = c;
        }
    }
    let mut when = Vec::with_capacity(40);
    let ok = if ts.len() == 15 && !ts[0].is_ascii_digit() { put_bsd(&mut when, ts, year) } else { put_rfc3339(&mut when, ts) };
    if !ok {
        return false;
    }
    let mut sdj = Vec::new();
    if !put_sd(&mut sdj, sd) {
        return false;
    }
    out.push(b'{');
    if !app.is_empty() && app != b"-" {
        put_kv(out, b"appname", app);
        out.push(b',');
    }
    put_kv(out, b"facility", FACS[pri >> 3]);
    out.push(b',');
    if !host.is_empty() && host != b"-" {
        put_kv(out, b"hostname", host);
        out.push(b',');
    }
    put_kv(out, b"message", &s[body_at..]);
    if !mid.is_empty() && mid != b"-" {
        out.push(b',');
        put_kv(out, b"msgid", mid);
    }
    if !pid.is_empty() && pid != b"-" {
        put_proc(out, pid);
    }
    out.push(b',');
    put_kv(out, b"severity", SEVS[sev]);
    out.extend_from_slice(&sdj);
    out.extend_from_slice(b",\"timestamp\":\"");
    out.extend_from_slice(&when);
    out.push(b'"');
    if ver >= 0 {
        out.extend_from_slice(b",\"version\":");
        out.push(48 + ver as u8);
    }
    if tag_debug && sev == 7 {
        out.extend_from_slice(b",\"dropped\":true");
    }
    out.extend_from_slice(b"}\n");
    true
}

// --- JSON input ---------------------------------------------------------------------

fn skip_ws(s: &[u8], mut i: usize) -> usize {
    while i < s.len() && matches!(s[i], b' ' | b'\t' | b'\r' | b'\n') {
        i += 1;
    }
    i
}

fn skip_str(s: &[u8], i0: usize) -> Option<usize> {
    let mut i = i0 + 1;
    while i < s.len() {
        let c = s[i];
        if c == b'"' {
            return Some(i + 1);
        }
        if c < 32 {
            return None;
        }
        i += if c == b'\\' { 2 } else { 1 };
    }
    None
}

fn skip_value(s: &[u8], i0: usize, depth: u32) -> Option<usize> {
    if depth > 128 {
        return None;
    }
    let mut i = skip_ws(s, i0);
    let c = *s.get(i)?;
    if c == b'"' {
        return skip_str(s, i);
    }
    if c == b'{' || c == b'[' {
        let close = if c == b'{' { b'}' } else { b']' };
        i = skip_ws(s, i + 1);
        if s.get(i) == Some(&close) {
            return Some(i + 1);
        }
        loop {
            if c == b'{' {
                i = skip_ws(s, i);
                if s.get(i) != Some(&b'"') {
                    return None;
                }
                i = skip_str(s, i)?;
                i = skip_ws(s, i);
                if s.get(i) != Some(&b':') {
                    return None;
                }
                i += 1;
            }
            i = skip_value(s, i, depth + 1)?;
            i = skip_ws(s, i);
            let d = *s.get(i)?;
            if d == close {
                return Some(i + 1);
            }
            if d != b',' {
                return None;
            }
            i += 1;
        }
    }
    let t = &s[i..];
    if t.starts_with(b"true") || t.starts_with(b"null") {
        return Some(i + 4);
    }
    if t.starts_with(b"false") {
        return Some(i + 5);
    }
    let n0 = i;
    while i < s.len() && matches!(s[i], b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E') {
        i += 1;
    }
    if i > n0 {
        Some(i)
    } else {
        None
    }
}

// --- transform ----------------------------------------------------------------------

/// What a worker knows about its input, for the fields Vector adds.
struct Ctx {
    host: Vec<u8>,
    port: u16,
}

/// A line as an event straight from the source, with the fields Vector adds.
fn put_received(out: &mut Vec<u8>, ctx: &Ctx, s: &[u8], stamp: &[u8]) {
    out.push(b'{');
    put_kv(out, b"host", &ctx.host);
    out.push(b',');
    put_kv(out, b"message", s);
    let _ = write!(out, ",\"port\":{}", ctx.port);
    out.extend_from_slice(b",\"source_type\":\"socket\",\"timestamp\":\"");
    out.extend_from_slice(stamp);
    out.extend_from_slice(b"\"}\n");
}

/// The whole lines in data, transformed, onto out.
fn transform(cfg: &Cfg, ctx: &Ctx, data: &[u8], out: &mut Vec<u8>) {
    let mut stamp = Vec::with_capacity(32);
    let mut year = 2026;
    if matches!(cfg.xf, Xf::Set | Xf::Syslog | Xf::SyslogTag) {
        // One time per block, in nanoseconds, the precision Vector writes. Its socket source stamps per read too.
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let frac = format!(".{:09}", now.subsec_nanos());
        put_utc(&mut stamp, now.as_secs() as i64, frac.as_bytes());
        year = dig(&stamp, 0, 4);
    }
    let mut at = 0;
    while at < data.len() {
        let e = memchr(b'\n', &data[at..]).map_or(data.len(), |k| at + k);
        let s = &data[at..e];
        at = e + 1;
        match cfg.xf {
            Xf::Regex => {
                out.extend_from_slice(b"{\"message\":\"");
                let mut last = 0;
                for m in cfg.re.as_ref().unwrap().find_iter(s) {
                    put_esc(out, &s[last..m.start()]);
                    put_esc(out, &cfg.rep);
                    last = m.end();
                }
                put_esc(out, &s[last..]);
                out.extend_from_slice(b"\"}\n");
            }
            Xf::Set => {
                out.push(b'{');
                put_kv(out, b"host", &ctx.host);
                out.push(b',');
                put_kv(out, b"message", s);
                let _ = write!(out, ",\"port\":{},", ctx.port);
                put_kv(out, &cfg.key, &cfg.val);
                out.extend_from_slice(b",\"source_type\":\"socket\",\"timestamp\":\"");
                out.extend_from_slice(&stamp);
                out.extend_from_slice(b"\"}\n");
            }
            Xf::Syslog | Xf::SyslogTag => {
                if !put_syslog(out, s, cfg.xf == Xf::SyslogTag, year) {
                    // As Vector does with an event its parser aborts on: pass the original through, as received.
                    put_received(out, ctx, s, &stamp);
                }
            }
            _ => {
                // Xf::Json: a line that's one JSON value goes through as it is; anything else is wrapped.
                match skip_value(s, 0, 0) {
                    Some(z) if skip_ws(s, z) == s.len() => {
                        out.extend_from_slice(s);
                        out.push(b'\n');
                    }
                    _ => {
                        out.push(b'{');
                        put_kv(out, b"message", s);
                        out.extend_from_slice(b"}\n");
                    }
                }
            }
        }
    }
}

// --- sinks --------------------------------------------------------------------------

fn connect(cfg: &Cfg) -> Option<TcpStream> {
    let addr = (cfg.host.as_str(), cfg.sport).to_socket_addrs().ok()?.find(|a| a.is_ipv4())?;
    let s = TcpStream::connect(addr).ok()?;
    let _ = s.set_nodelay(true);
    Some(s)
}

fn http_post(cfg: &Cfg, s: &mut TcpStream, body: &[u8]) -> io::Result<()> {
    write!(s, "POST {} HTTP/1.1\r\nHost: {}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n", cfg.path, cfg.host, body.len())?;
    s.write_all(body)?;
    let mut r = Vec::with_capacity(1024);
    let mut chunk = [0u8; 4096];
    let bad = || io::Error::new(io::ErrorKind::Other, "bad response");
    let hdr_end = loop {
        let n = s.read(&mut chunk)?;
        if n == 0 {
            return Err(bad());
        }
        r.extend_from_slice(&chunk[..n]);
        if let Some(k) = memmem::find(&r, b"\r\n\r\n") {
            break k;
        }
    };
    if r.len() < 12 || r[9] != b'2' {
        return Err(bad());
    }
    // The body, so the next response starts clean.
    let mut clen = 0;
    for raw in r[..hdr_end].split(|&b| b == b'\n') {
        if raw.len() > 15 && (raw[0] | 32) == b'c' && (raw[8] | 32) == b'l' && raw[14] == b':' {
            clen = std::str::from_utf8(&raw[15..]).ok().and_then(|t| t.trim().parse().ok()).unwrap_or(0);
        }
    }
    let want = hdr_end + 4 + clen;
    let mut have = r.len();
    while have < want {
        let n = s.read(&mut chunk)?;
        if n == 0 {
            return Err(bad());
        }
        have += n;
    }
    Ok(())
}

/// One attempt: connected and delivered, or not.
fn send_once(cfg: &Cfg, sink: &mut Option<TcpStream>, data: &[u8]) -> bool {
    if cfg.sink == SinkKind::Null {
        return true;
    }
    if sink.is_none() {
        *sink = connect(cfg);
    }
    let Some(s) = sink.as_mut() else { return false };
    let ok = if cfg.sink == SinkKind::Http { http_post(cfg, s, data).is_ok() } else { s.write_all(data).is_ok() };
    if !ok {
        *sink = None;
    }
    ok
}

/// Keeps trying until delivered, or until asked to stop. A slow or absent sink holds up the reader, which is the backpressure.
fn send(cfg: &Cfg, sink: &mut Option<TcpStream>, data: &[u8]) -> bool {
    while !send_once(cfg, sink, data) {
        if term() {
            return false;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    true
}

/// Reads up to BLOCK more bytes onto buf.
fn read_more(fd: &mut TcpStream, buf: &mut Vec<u8>) -> usize {
    let at = buf.len();
    buf.resize(at + BLOCK, 0);
    let n = loop {
        match fd.read(&mut buf[at..]) {
            Ok(n) => break n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break 0,
        }
    };
    buf.truncate(at + n);
    n
}

// --- workers ------------------------------------------------------------------------

fn peer(s: &TcpStream) -> Ctx {
    match s.peer_addr() {
        Ok(a) => Ctx { host: a.ip().to_string().into_bytes(), port: a.port() },
        Err(_) => Ctx { host: vec![], port: 0 },
    }
}

fn conn_worker(mut fd: TcpStream, cfg: Arc<Cfg>) {
    let ctx = peer(&fd);
    let mut buf: Vec<u8> = Vec::with_capacity(2 * BLOCK);
    let mut out: Vec<u8> = Vec::with_capacity(4 * BLOCK);
    let mut sink = None;
    let mut skipping = false;
    let mut alive = true;
    while alive {
        let n = read_more(&mut fd, &mut buf);
        if n == 0 {
            alive = false;
            if !buf.is_empty() && !skipping {
                buf.push(b'\n');
            }
        }
        let e = if alive { memrchr(b'\n', &buf[buf.len() - n..]).map_or(0, |k| buf.len() - n + k + 1) } else { buf.len() };
        if e == 0 {
            if buf.len() > MAX_LINE {
                eprintln!("logxform: line over the limit dropped");
                buf.clear();
                skipping = true;
            }
            continue;
        }
        let mut from = 0;
        if skipping {
            from = memchr(b'\n', &buf[..e]).map_or(0, |k| k + 1);
            skipping = false;
        }
        if from < e {
            if cfg.xf == Xf::None {
                if !send(&cfg, &mut sink, &buf[from..e]) {
                    break;
                }
            } else {
                out.clear();
                transform(&cfg, &ctx, &buf[from..e], &mut out);
                if !send(&cfg, &mut sink, &out) {
                    break;
                }
            }
        }
        buf.drain(..e);
    }
}

fn poll_in(fd: &TcpStream, ms: i32) -> bool {
    let mut p = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: p is one valid pollfd for the duration of the call.
    unsafe { libc::poll(&mut p, 1, ms) > 0 }
}

fn get8(f: &File) -> u64 {
    let mut b = [0u8; 8];
    if f.read_exact_at(&mut b, 0).is_ok() {
        u64::from_le_bytes(b)
    } else {
        0
    }
}

fn put8(f: &File, v: u64) {
    let _ = f.write_all_at(&v.to_le_bytes(), 0);
}

fn rw(path: &str) -> File {
    OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o644).open(path).unwrap_or_else(|_| fail(&format!("cannot open {path}")))
}

// The disk buffer. Two workers per connection that share only files, so a slow or absent sink, or a name lookup that takes
// seconds, can't stop the reader: anything unread when a process dies is lost with its socket.
//   base.N.seg  lines, transformed, in order. A new segment starts every SEG_BYTES.
//   base.N.ack  how much of that segment has been delivered.
//   base.done   the reader saw the end of its connection.
// Delivery is at least once.
const SEG_BYTES: u64 = 268435456;
const MAX_SEGS: u64 = 16;

fn open_seg(base: &str, n: u64) -> File {
    OpenOptions::new().read(true).append(true).create(true).mode(0o644).open(format!("{base}.{n}.seg")).unwrap_or_else(|_| fail("cannot open a buffer"))
}

fn disk_reader(mut fd: TcpStream, base: String, cfg: Arc<Cfg>) {
    let ctx = peer(&fd);
    let mut n = 0;
    let mut seg = open_seg(&base, n);
    let mut size = 0u64;
    let mut buf: Vec<u8> = Vec::with_capacity(2 * BLOCK);
    let mut out: Vec<u8> = Vec::with_capacity(4 * BLOCK);
    let mut skipping = false;
    let mut eof = false;
    let mut last_sync = Instant::now();
    let mut dirty = false;
    while !eof {
        if !poll_in(&fd, 100) {
            if term() {
                break;
            }
        } else {
            let got = read_more(&mut fd, &mut buf);
            if got == 0 {
                eof = true;
                if !buf.is_empty() && !skipping {
                    buf.push(b'\n');
                }
            }
            let e = memrchr(b'\n', &buf).map_or(0, |k| k + 1);
            if e == 0 {
                if buf.len() > MAX_LINE {
                    eprintln!("logxform: line over the limit dropped");
                    buf.clear();
                    skipping = true;
                }
            } else {
                let mut from = 0;
                if skipping {
                    from = memchr(b'\n', &buf[..e]).map_or(0, |k| k + 1);
                    skipping = false;
                }
                if from < e {
                    let r = if cfg.xf == Xf::None {
                        size += (e - from) as u64;
                        seg.write_all(&buf[from..e])
                    } else {
                        out.clear();
                        transform(&cfg, &ctx, &buf[from..e], &mut out);
                        size += out.len() as u64;
                        seg.write_all(&out)
                    };
                    if r.is_err() {
                        fail("cannot write a buffer");
                    }
                    dirty = true;
                }
                buf.drain(..e);
            }
        }
        if dirty && (eof || last_sync.elapsed() > SYNC_EVERY) {
            let _ = seg.sync_data();
            last_sync = Instant::now();
            dirty = false;
        }
        if size >= SEG_BYTES {
            let _ = seg.sync_data();
            n += 1;
            // Too much undelivered: stop reading, which pushes back on the sender.
            while n >= MAX_SEGS && Path::new(&format!("{base}.{}.seg", n - MAX_SEGS)).exists() && !term() {
                std::thread::sleep(Duration::from_millis(50));
            }
            seg = open_seg(&base, n);
            size = 0;
        }
    }
    let _ = seg.sync_data();
    if eof {
        let _ = rw(&format!("{base}.done"));
    }
}

/// Sends segments in order. live: a reader may still add to them. Otherwise this is a restart, and what's there is all there is.
fn disk_sender(base: String, first: u64, live: bool, cfg: Arc<Cfg>) {
    let mut n = first;
    let mut sink = None;
    let mut pend = vec![0u8; BLOCK * 4];
    let done = format!("{base}.done");
    let exists = |p: &str| Path::new(p).exists();
    loop {
        let seg_path = format!("{base}.{n}.seg");
        let ack_path = format!("{base}.{n}.ack");
        // A live segment may not be there yet.
        while !exists(&seg_path) {
            if !live || term() || exists(&done) {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        if !exists(&seg_path) {
            break;
        }
        let seg = File::open(&seg_path).unwrap_or_else(|_| fail("cannot open a buffer"));
        let ack = rw(&ack_path);
        let mut acked = get8(&ack);
        let next_path = format!("{base}.{}.seg", n + 1);
        loop {
            if term() {
                break;
            }
            let size = seg.metadata().map_or(0, |m| m.len());
            if size > acked {
                let want = ((size - acked) as usize).min(pend.len());
                let got = seg.read_at(&mut pend[..want], acked).unwrap_or(0);
                match memrchr(b'\n', &pend[..got]) {
                    Some(k) if send_once(&cfg, &mut sink, &pend[..k + 1]) => {
                        acked += k as u64 + 1;
                        put8(&ack, acked);
                    }
                    _ => std::thread::sleep(Duration::from_millis(50)),
                }
            } else if exists(&next_path) || !live || exists(&done) {
                // Caught up, and nothing more can come. A second look at the size closes the gap after the reader's last write.
                if seg.metadata().map_or(0, |m| m.len()) == acked {
                    break;
                }
            } else {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        if term() {
            break;
        }
        let _ = fs::remove_file(&seg_path);
        let _ = fs::remove_file(&ack_path);
        n += 1;
    }
    if !term() {
        let _ = fs::remove_file(&done);
    }
}

/// One tailed file, followed by inode: a rename doesn't change what it reads, a shrink starts it over, and the checkpoint
/// holds the offset of what's been delivered.
fn tail_worker(path: String, inode: u64, cfg: Arc<Cfg>) {
    let ctx = Ctx { host: vec![], port: 0 };
    let Ok(fd) = File::open(&path) else { return };
    let ckpt = rw(&format!("{}/ino-{inode}.ckpt", cfg.data_dir));
    let mut off = get8(&ckpt);
    let mut buf = vec![0u8; BLOCK];
    let mut out: Vec<u8> = Vec::with_capacity(4 * BLOCK);
    let mut sink = None;
    let nap = Duration::from_millis(10);
    while !term() {
        let Ok(meta) = fd.metadata() else { break };
        let size = meta.len();
        if size < off {
            off = 0;
            put8(&ckpt, 0);
        }
        if size == off {
            if meta.nlink() == 0 {
                break;
            }
            std::thread::sleep(nap);
            continue;
        }
        let n = match fd.read_at(&mut buf[..BLOCK], off) {
            Ok(n) if n > 0 => n,
            _ => {
                std::thread::sleep(nap);
                continue;
            }
        };
        let nl = memrchr(b'\n', &buf[..n]);
        if nl.is_none() {
            if n >= BLOCK {
                fail("a tailed line is longer than the block size");
            }
            // A line still being written. If the file's been unlinked, it won't get any longer.
            if meta.nlink() != 0 {
                std::thread::sleep(nap);
                continue;
            }
        }
        let e = nl.map_or(n, |k| k + 1);
        let ok = if cfg.xf == Xf::None {
            send(&cfg, &mut sink, &buf[..e])
        } else {
            out.clear();
            transform(&cfg, &ctx, &buf[..e], &mut out);
            send(&cfg, &mut sink, &out)
        };
        if !ok {
            break;
        }
        off += e as u64;
        put8(&ckpt, off);
    }
}

// --- main ---------------------------------------------------------------------------

/// Serves until asked to stop or reload. New connections get a new config; ones in progress keep what they started with.
fn serve_tcp(cfg: Arc<Cfg>, l: &TcpListener, id: &mut u128) {
    while !term() && !HUP.swap(false, Ordering::Relaxed) {
        let mut p = libc::pollfd { fd: l.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: p is one valid pollfd for the duration of the call.
        if unsafe { libc::poll(&mut p, 1, 200) } <= 0 {
            continue;
        }
        let Ok((c, _)) = l.accept() else { continue };
        let _ = c.set_nodelay(true);
        *id += 1;
        let cfg = cfg.clone();
        if cfg.disk {
            let base = format!("{}/c{}", cfg.buf_dir, *id);
            let (b2, c2) = (base.clone(), cfg.clone());
            std::thread::spawn(move || disk_reader(c, base, cfg));
            std::thread::spawn(move || disk_sender(b2, 0, true, c2));
        } else {
            std::thread::spawn(move || conn_worker(c, cfg));
        }
    }
}

fn serve_files(cfg: Arc<Cfg>) {
    let mut seen = HashSet::new();
    while !term() {
        HUP.store(false, Ordering::Relaxed);
        if let Ok(rd) = fs::read_dir(&cfg.dir) {
            for ent in rd.flatten() {
                let name = ent.file_name().to_string_lossy().into_owned();
                if !name.starts_with(&cfg.prefix) || (cfg.exact && name.len() != cfg.prefix.len()) {
                    continue;
                }
                let full = format!("{}/{name}", cfg.dir);
                let Ok(m) = fs::metadata(&full) else { continue };
                if seen.insert(m.ino()) {
                    let cfg = cfg.clone();
                    let ino = m.ino();
                    std::thread::spawn(move || tail_worker(full, ino, cfg));
                }
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    if argv.len() != 3 || argv[1] != "--config" {
        fail("usage: logxform --config FILE");
    }
    // SAFETY: the handlers only store to atomics, which is async-signal-safe.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGTERM, on_term as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, on_term as *const () as libc::sighandler_t);
        libc::signal(libc::SIGHUP, on_hup as *const () as libc::sighandler_t);
    }
    let cfg = Arc::new(load(&argv[2]));
    if cfg.disk {
        let _ = fs::create_dir_all(&cfg.buf_dir);
        if let Ok(rd) = fs::read_dir(&cfg.buf_dir) {
            // The lowest segment of each connection: names are base.N.seg.
            let mut lowest: std::collections::HashMap<String, u64> = Default::default();
            for ent in rd.flatten() {
                let name = ent.file_name().to_string_lossy().into_owned();
                let Some(stem) = name.strip_suffix(".seg") else { continue };
                let Some((b, num)) = stem.rsplit_once('.') else { continue };
                let Ok(num) = num.parse::<u64>() else { continue };
                let e = lowest.entry(b.to_string()).or_insert(num);
                *e = (*e).min(num);
            }
            for (b, low) in lowest {
                let base = format!("{}/{b}", cfg.buf_dir);
                let cfg = cfg.clone();
                std::thread::spawn(move || disk_sender(base, low, false, cfg));
            }
        }
    }
    if cfg.file {
        let _ = fs::create_dir_all(&cfg.data_dir);
        let _ = Path::new(&cfg.dir);
        serve_files(cfg);
    } else {
        let l = TcpListener::bind(("0.0.0.0", cfg.port)).unwrap_or_else(|_| fail("cannot listen"));
        let mut id = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        while !term() {
            let c = Arc::new(load(&argv[2]));
            serve_tcp(c, &l, &mut id);
            if !term() {
                eprintln!("logxform: config reloaded");
            }
        }
    }
    std::thread::sleep(Duration::from_millis(500));
    exit(0);
}
