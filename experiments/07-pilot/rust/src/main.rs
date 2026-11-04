//! Sanitize rotated logs for an analytics store: the pilot's Rust version. Spec: experiments/07-pilot/SPEC.md.
//! Parsing, filtering, redaction and rendering follow experiments/02-logxform/SPEC.md, from experiment 2's rust-arena.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::sync::OnceLock;

const BATCH: usize = 65536;
const BLOCK: usize = 1 << 20;

#[derive(Clone, Copy, PartialEq)]
enum Fmt {
    Hdfs,
    Ssh,
    Apache,
    Bgl,
}

// Level ranks, in filter order.
const TRACE: u8 = 0;
const DEBUG: u8 = 1;
const INFO: u8 = 2;
const NOTICE: u8 = 3;
const WARN: u8 = 4;
const ERROR: u8 = 5;
const FATAL: u8 = 6;
const LEVEL_NAME: [&[u8]; 7] = [b"TRACE", b"DEBUG", b"INFO", b"NOTICE", b"WARN", b"ERROR", b"FATAL"];
const SEV: [u8; 7] = [b'7', b'7', b'6', b'5', b'4', b'3', b'2'];
const MONTHS: &[u8; 36] = b"JanFebMarAprMayJunJulAugSepOctNovDec";
const WEEKDAYS: &[u8; 21] = b"MonTueWedThuFriSatSun";

#[derive(Clone, Copy, Default)]
struct Ts {
    y: u16,
    mo: u8,
    d: u8,
    h: u8,
    mi: u8,
    s: u8,
}

type Kv<'a> = (&'a [u8], &'a [u8]);

/// A string of the batch: `off` below the input's length is in the input, else in the byte arena.
#[derive(Clone, Copy)]
struct Sp {
    off: u32,
    len: u32,
}

/// A record: 36 bytes, its pairs at `kvs[kv_lo..kv_lo + kv_n]`.
struct Rec {
    ts: Ts,
    level: u8,
    comp: Sp,
    msg: Sp,
    kv_lo: u32,
    kv_n: u32,
}

/// The per-batch arenas, reused from batch to batch.
#[derive(Default)]
struct Arena {
    recs: Vec<Rec>,
    kvs: Vec<(Sp, Sp)>,
    bytes: Vec<u8>,
    kv: Vec<(Sp, Sp)>,
}

/// The format keys and Apache's component, at the start of every batch's byte arena.
const STATIC: &[u8] = b"pidhostblkhttpdnodealert";

/// The bytes a span names.
#[inline]
fn get<'a>(x: Sp, data: &'a [u8], bytes: &'a [u8]) -> &'a [u8] {
    let (off, len) = (x.off as usize, x.len as usize);
    if off < data.len() {
        &data[off..off + len]
    } else {
        let o = off - data.len();
        &bytes[o..o + len]
    }
}

/// What a format parser finds in a line.
struct Head<'a> {
    ts: Ts,
    level: u8,
    comp: &'a [u8],
    msg: &'a [u8],
    fp: [Kv<'a>; 2],
    nf: usize,
}

#[derive(Clone, Copy, Default)]
struct Counts {
    lines: u64,
    kept: u64,
    dropped: u64,
    malformed: u64,
}

impl Counts {
    fn add(&mut self, o: &Counts) {
        self.lines += o.lines;
        self.kept += o.kept;
        self.dropped += o.dropped;
        self.malformed += o.malformed;
    }
}

// --- parsing --------------------------------------------------------------------------

#[inline]
fn digits(s: &[u8]) -> bool {
    s.iter().all(u8::is_ascii_digit)
}

#[inline]
fn d2(s: &[u8], i: usize) -> u8 {
    (s[i] - b'0') * 10 + (s[i + 1] - b'0')
}

fn month(s: &[u8]) -> u8 {
    (0..12).find(|&m| &MONTHS[m * 3..m * 3 + 3] == s).map_or(0, |m| m as u8 + 1)
}

/// HH:MM:SS at s[i..i + 8].
fn clock_at(s: &[u8], i: usize, ts: &mut Ts) -> bool {
    let c = &s[i..i + 8];
    if !(digits(&c[0..2]) && c[2] == b':' && digits(&c[3..5]) && c[5] == b':' && digits(&c[6..8])) {
        return false;
    }
    ts.h = d2(c, 0);
    ts.mi = d2(c, 3);
    ts.s = d2(c, 6);
    true
}

fn ts_ok(t: &Ts) -> bool {
    (1..=12).contains(&t.mo) && (1..=31).contains(&t.d) && t.h <= 23 && t.mi <= 59 && t.s <= 59
}

fn hdfs_level(t: &[u8]) -> Option<u8> {
    Some(match t {
        b"INFO" => INFO,
        b"WARN" => WARN,
        b"ERROR" => ERROR,
        b"FATAL" => FATAL,
        b"DEBUG" => DEBUG,
        b"TRACE" => TRACE,
        _ => return None,
    })
}

/// The index of the first byte at or after `i` that is `b`, or `s.len()`.
#[inline]
fn upto(s: &[u8], i: usize, b: u8) -> usize {
    s[i..].iter().position(|&c| c == b).map_or(s.len(), |k| i + k)
}

/// YYMMDD HHMMSS PID LEVEL COMPONENT: MSG
fn parse_hdfs(s: &[u8]) -> Option<Head<'_>> {
    if s.len() < 14 || !digits(&s[0..6]) || s[6] != b' ' || !digits(&s[7..13]) || s[13] != b' ' {
        return None;
    }
    let ts = Ts { y: 2000 + d2(s, 0) as u16, mo: d2(s, 2), d: d2(s, 4), h: d2(s, 7), mi: d2(s, 9), s: d2(s, 11) };
    let mut i = 14;
    while i < s.len() && s[i].is_ascii_digit() {
        i += 1;
    }
    if i == 14 || i >= s.len() || s[i] != b' ' {
        return None;
    }
    let pid = &s[14..i];
    let l0 = i + 1;
    i = upto(s, l0, b' ');
    if i >= s.len() {
        return None;
    }
    let level = hdfs_level(&s[l0..i])?;
    // The component runs to the first ": " and has no space: so it is the next space-free token,
    // ending in a colon.
    let c0 = i + 1;
    i = upto(s, c0, b' ');
    if i >= s.len() || i - 1 <= c0 || s[i - 1] != b':' {
        return None;
    }
    let comp = &s[c0..i - 1];
    let msg = &s[i + 1..];
    let mut h = Head { ts, level, comp, msg, fp: [(b"pid", pid), (b"", b"")], nf: 1 };
    // blk: the first message token starting with blk_, cut to blk_-?[0-9]+.
    if let Some(tok) = msg.split(|&c| c == b' ').find(|t| t.starts_with(b"blk_")) {
        let mut e = 4;
        if e < tok.len() && tok[e] == b'-' {
            e += 1;
        }
        let dg = e;
        while e < tok.len() && tok[e].is_ascii_digit() {
            e += 1;
        }
        if e > dg {
            h.fp[1] = (b"blk", &tok[..e]);
            h.nf = 2;
        }
    }
    if ts_ok(&h.ts) {
        Some(h)
    } else {
        None
    }
}

/// Mmm DD HH:MM:SS HOST PROG[PID]: MSG
fn parse_ssh(s: &[u8]) -> Option<Head<'_>> {
    if s.len() < 16 || s[3] != b' ' || s[6] != b' ' || s[15] != b' ' {
        return None;
    }
    let mut ts = Ts { mo: month(&s[0..3]), ..Ts::default() };
    if ts.mo == 0 {
        return None;
    }
    ts.d = if s[4] == b' ' && s[5].is_ascii_digit() {
        s[5] - b'0'
    } else if digits(&s[4..6]) {
        d2(s, 4)
    } else {
        return None;
    };
    if !clock_at(s, 7, &mut ts) {
        return None;
    }
    ts.y = if ts.mo >= 7 { 2017 } else { 2018 };
    let host_hi = upto(s, 16, b' ');
    if host_hi == 16 || host_hi >= s.len() {
        return None;
    }
    let p0 = host_hi + 1;
    let mut i = p0;
    while i < s.len() && s[i] != b' ' && s[i] != b'[' {
        i += 1;
    }
    if i == p0 || i >= s.len() || s[i] != b'[' {
        return None;
    }
    let comp = &s[p0..i];
    let pid0 = i + 1;
    i = pid0;
    while i < s.len() && s[i].is_ascii_digit() {
        i += 1;
    }
    if i == pid0 || !s[i..].starts_with(b"]: ") {
        return None;
    }
    let msg = &s[i + 3..];
    let level = if msg.starts_with(b"error: ") {
        ERROR
    } else if msg.starts_with(b"fatal: ") {
        FATAL
    } else if msg.starts_with(b"Failed ") || msg.starts_with(b"Invalid user ") || msg.starts_with(b"reverse mapping ") {
        WARN
    } else {
        INFO
    };
    let h = Head { ts, level, comp, msg, fp: [(b"host", &s[16..host_hi]), (b"pid", &s[pid0..i])], nf: 2 };
    if ts_ok(&h.ts) {
        Some(h)
    } else {
        None
    }
}

fn apache_level(t: &[u8]) -> Option<u8> {
    Some(match t {
        b"error" => ERROR,
        b"notice" => NOTICE,
        b"warn" => WARN,
        b"info" => INFO,
        b"debug" => DEBUG,
        b"emerg" | b"alert" | b"crit" => FATAL,
        _ => return None,
    })
}

/// [Www Mmm DD HH:MM:SS YYYY] [level] MSG
fn parse_apache(s: &[u8]) -> Option<Head<'_>> {
    if s.len() < 29
        || s[0] != b'['
        || s[4] != b' '
        || s[8] != b' '
        || s[11] != b' '
        || s[20] != b' '
        || s[25] != b']'
        || s[26] != b' '
        || s[27] != b'['
    {
        return None;
    }
    if !(0..7).any(|w| &WEEKDAYS[w * 3..w * 3 + 3] == &s[1..4]) {
        return None;
    }
    let mut ts = Ts { mo: month(&s[5..8]), ..Ts::default() };
    if ts.mo == 0 || !digits(&s[9..11]) || !clock_at(s, 12, &mut ts) || !digits(&s[21..25]) {
        return None;
    }
    ts.d = d2(s, 9);
    ts.y = d2(s, 21) as u16 * 100 + d2(s, 23) as u16;
    let i = upto(s, 28, b']');
    if i + 1 >= s.len() || s[i + 1] != b' ' {
        return None;
    }
    let level = apache_level(&s[28..i])?;
    let h = Head { ts, level, comp: b"httpd", msg: &s[i + 2..], fp: [(b"", b""); 2], nf: 0 };
    if ts_ok(&h.ts) {
        Some(h)
    } else {
        None
    }
}

// --- transform ------------------------------------------------------------------------

fn bgl_level(t: &[u8]) -> Option<u8> {
    match t {
        b"INFO" => Some(INFO),
        b"FATAL" | b"FAILURE" => Some(FATAL),
        b"ERROR" | b"SEVERE" => Some(ERROR),
        b"WARNING" => Some(WARN),
        _ => None,
    }
}

/// LABEL EPOCH YYYY.MM.DD NODE YYYY-MM-DD-HH.MM.SS.ffffff [NODE2] TYPE COMPONENT LEVEL[ MSG]
fn parse_bgl(s: &[u8]) -> Option<Head<'_>> {
    let label = upto(s, 0, b' ');
    if label == 0 || label == s.len() {
        return None;
    }
    let ep = label + 1;
    let ep_hi = upto(s, ep, b' ');
    if ep_hi == ep || ep_hi == s.len() || !digits(&s[ep..ep_hi]) {
        return None;
    }
    let d = ep_hi + 1;
    if d + 11 > s.len()
        || s[d + 4] != b'.'
        || s[d + 7] != b'.'
        || s[d + 10] != b' '
        || !digits(&s[d..d + 4])
        || !digits(&s[d + 5..d + 7])
        || !digits(&s[d + 8..d + 10])
    {
        return None;
    }
    let node = d + 11;
    let node_hi = upto(s, node, b' ');
    if node_hi == node || node_hi == s.len() {
        return None;
    }
    let t = node_hi + 1;
    if t + 27 > s.len()
        || s[t + 4] != b'-'
        || s[t + 7] != b'-'
        || s[t + 10] != b'-'
        || s[t + 13] != b'.'
        || s[t + 16] != b'.'
        || s[t + 19] != b'.'
        || s[t + 26] != b' '
        || !digits(&s[t..t + 4])
        || !digits(&s[t + 5..t + 7])
        || !digits(&s[t + 8..t + 10])
        || !digits(&s[t + 11..t + 13])
        || !digits(&s[t + 14..t + 16])
        || !digits(&s[t + 17..t + 19])
        || !digits(&s[t + 20..t + 26])
    {
        return None;
    }
    let ts = Ts {
        y: d2(s, t) as u16 * 100 + d2(s, t + 2) as u16,
        mo: d2(s, t + 5),
        d: d2(s, t + 8),
        h: d2(s, t + 11),
        mi: d2(s, t + 14),
        s: d2(s, t + 17),
    };
    let mut i = t + 27;
    if !(&s[node..node_hi] == b"-" && (s[i..].starts_with(b"RAS ") || s[i..].starts_with(b"NULL "))) {
        let e = upto(s, i, b' ');
        if e == i || e == s.len() {
            return None;
        }
        i = e + 1;
    }
    let ty = upto(s, i, b' ');
    if ty == s.len() || !(&s[i..ty] == b"RAS" || &s[i..ty] == b"NULL") {
        return None;
    }
    i = ty + 1;
    let comp = upto(s, i, b' ');
    if comp == i || comp == s.len() {
        return None;
    }
    let lv = upto(s, comp + 1, b' ');
    let level = bgl_level(&s[comp + 1..lv])?;
    let mut fp: [Kv; 2] = [(b"node", &s[node..node_hi]), (b"", b"")];
    let mut nf = 1;
    if &s[..label] != b"-" {
        fp[1] = (b"alert", &s[..label]);
        nf = 2;
    }
    let msg = if lv < s.len() { &s[lv + 1..] } else { &s[s.len()..] };
    if ts_ok(&ts) {
        Some(Head { ts, level, comp: &s[i..comp], msg, fp, nf })
    } else {
        None
    }
}

fn min_level(comp: &[u8]) -> u8 {
    if comp == b"dfs.DataNode$PacketResponder" || comp == b"dfs.FSDataset" {
        WARN
    } else {
        INFO
    }
}

/// Exactly four groups of 1-3 digits joined by single dots (s holds digits and dots).
fn is_ipv4(s: &[u8]) -> bool {
    let (mut groups, mut n) = (0, 0);
    for &c in s {
        if c == b'.' {
            if n == 0 || n > 3 {
                return false;
            }
            groups += 1;
            n = 0;
        } else {
            n += 1;
        }
    }
    groups == 3 && (1..=3).contains(&n)
}

/// The next IPv4 address in msg at or after `from`: its span, and where scanning resumes.
fn next_ip(msg: &[u8], mut i: usize) -> Option<(usize, usize, usize)> {
    while i < msg.len() {
        let c = msg[i];
        if c.is_ascii_digit() && (i == 0 || !(msg[i - 1].is_ascii_digit() || msg[i - 1] == b'.')) {
            let mut j = i;
            while j < msg.len() && (msg[j].is_ascii_digit() || msg[j] == b'.') {
                j += 1;
            }
            let mut k = j;
            while k > i && msg[k - 1] == b'.' {
                k -= 1;
            }
            if is_ipv4(&msg[i..k]) {
                return Some((i, k, j));
            }
            i = j;
        } else {
            i += 1;
        }
    }
    None
}

/// Appends the redacted message to `out` if it has an address; false (nothing appended) if not.
/// 0x and exactly 8 hex digits, not touching a letter or digit, at s[i..i + 10].
fn hex_at(s: &[u8], i: usize) -> bool {
    i + 10 <= s.len()
        && (i == 0 || !s[i - 1].is_ascii_alphanumeric())
        && (i + 10 == s.len() || !s[i + 10].is_ascii_alphanumeric())
        && s[i + 2..i + 10].iter().all(u8::is_ascii_hexdigit)
}

fn next_hex(s: &[u8], from: usize) -> Option<usize> {
    let mut p = from;
    while let Some(k) = memchr::memmem::find(&s[p..], b"0x") {
        if hex_at(s, p + k) {
            return Some(p + k);
        }
        p += k + 1;
    }
    None
}

/// Rewrites v[at..] in place, since <hex> is shorter than what it replaces.
fn redact_hex(v: &mut Vec<u8>, at: usize) {
    let (mut r, mut w) = (at, at);
    while let Some(k) = next_hex(&v[at..], r - at) {
        let i = at + k;
        v.copy_within(r..i, w);
        w += i - r;
        v[w..w + 5].copy_from_slice(b"<hex>");
        w += 5;
        r = i + 10;
    }
    v.copy_within(r.., w);
    let n = v.len() - r;
    v.truncate(w + n);
}

fn redact(msg: &[u8], out: &mut Vec<u8>) -> bool {
    let Some(mut ip) = next_ip(msg, 0) else { return false };
    let mut start = 0;
    loop {
        let (lo, hi, resume) = ip;
        out.extend_from_slice(&msg[start..lo]);
        out.extend_from_slice(b"<ip>");
        start = hi;
        match next_ip(msg, resume) {
            Some(n) => ip = n,
            None => break,
        }
    }
    out.extend_from_slice(&msg[start..]);
    true
}

#[inline]
fn is_key_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'-'
}

/// Dictionary semantics: an existing key keeps its place and takes the new value.
#[inline]
fn add_pair(kv: &mut Vec<(Sp, Sp)>, data: &[u8], bytes: &[u8], k: Sp, v: Sp) {
    let key = get(k, data, bytes);
    match kv.iter_mut().find(|(kk, _)| get(*kk, data, bytes) == key) {
        Some(p) => p.1 = v,
        None => kv.push((k, v)),
    }
}

// --- one batch: build, transform, render, drop ----------------------------------------

#[inline]
fn put2(out: &mut Vec<u8>, v: u8) {
    out.extend_from_slice(&[b'0' + v / 10, b'0' + v % 10]);
}

/// s as a JSON string, escaped as serde_json does.
#[inline]
/// Whether s needs no JSON escapes. No early exit and no comparisons, so the compiler vectorizes it: almost every string is plain.
/// For x below 256, (x + 255) >> 8 is 0 only for x == 0, and (x + 224) >> 8 is 0 only for x below 0x20.
fn plain(s: &[u8]) -> bool {
    let mut ok: u32 = 1;
    for &c in s {
        let x = c as u32;
        ok = ok & (((x ^ 34) + 255) >> 8) & (((x ^ 92) + 255) >> 8) & ((x + 224) >> 8);
    }
    ok == 1
}

fn put_str(out: &mut Vec<u8>, s: &[u8]) {
    out.push(b'"');
    if plain(s) {
        out.extend_from_slice(s);
        out.push(b'"');
        return;
    }
    let mut start = 0;
    for (i, &c) in s.iter().enumerate() {
        if c >= 0x20 && c != b'"' && c != b'\\' {
            continue;
        }
        out.extend_from_slice(&s[start..i]);
        start = i + 1;
        match c {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            8 => out.extend_from_slice(b"\\b"),
            12 => out.extend_from_slice(b"\\f"),
            _ => {
                const HEX: &[u8; 16] = b"0123456789abcdef";
                out.extend_from_slice(&[b'\\', b'u', b'0', b'0', HEX[(c >> 4) as usize], HEX[(c & 15) as usize]]);
            }
        }
    }
    out.extend_from_slice(&s[start..]);
    out.push(b'"');
}

fn render(out: &mut Vec<u8>, r: &Rec, data: &[u8], a: &Arena) {
    let t = &r.ts;
    out.extend_from_slice(b"{\"ts\":\"");
    put2(out, (t.y / 100) as u8);
    put2(out, (t.y % 100) as u8);
    out.push(b'-');
    put2(out, t.mo);
    out.push(b'-');
    put2(out, t.d);
    out.push(b'T');
    put2(out, t.h);
    out.push(b':');
    put2(out, t.mi);
    out.push(b':');
    put2(out, t.s);
    out.extend_from_slice(b"Z\",\"level\":\"");
    out.extend_from_slice(LEVEL_NAME[r.level as usize]);
    out.extend_from_slice(b"\",\"sev\":");
    out.push(SEV[r.level as usize]);
    out.extend_from_slice(b",\"component\":");
    put_str(out, get(r.comp, data, &a.bytes));
    out.extend_from_slice(b",\"msg\":");
    put_str(out, get(r.msg, data, &a.bytes));
    out.extend_from_slice(b",\"kv\":{");
    let kvs = &a.kvs[r.kv_lo as usize..(r.kv_lo + r.kv_n) as usize];
    for (i, &(k, v)) in kvs.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        put_str(out, get(k, data, &a.bytes));
        out.push(b':');
        put_str(out, get(v, data, &a.bytes));
    }
    out.extend_from_slice(b"}}\n");
}

/// One batch: parse every line into a record in the arenas, then render them all into `out`.
fn process(fmt: Fmt, data: &[u8], a: &mut Arena, out: &mut Vec<u8>, rejects: Option<&mut Vec<u8>>, c: &mut Counts) {
    let mut rejects = rejects;
    assert!(data.len() + (1 << 30) < u32::MAX as usize, "batch too large for u32 spans");
    if a.recs.capacity() == 0 {
        a.recs.reserve(BATCH);
    }
    a.recs.clear();
    a.kvs.clear();
    a.bytes.clear();
    a.bytes.extend_from_slice(STATIC);
    let base = data.as_ptr() as usize;
    let dl = data.len() as u32;
    // Spans of the input (from a subslice of data) and of the byte arena.
    let in_data = |x: &[u8]| Sp { off: (x.as_ptr() as usize - base) as u32, len: x.len() as u32 };
    let fixed = |k: &[u8]| {
        let o = match k {
            b"pid" => 0,
            b"host" => 3,
            b"blk" => 7,
            b"node" => 15,
            b"alert" => 19,
            _ => 10, // httpd
        };
        Sp { off: dl + o, len: k.len() as u32 }
    };
    let mut start = 0;
    while start < data.len() {
        let e = memchr::memchr(b'\n', &data[start..]).map_or(data.len(), |k| start + k);
        let raw = &data[start..e];
        let mut s = raw;
        start = e + 1;
        if let [rest @ .., b'\r'] = s {
            s = rest;
        }
        c.lines += 1;
        let parsed = match fmt {
            Fmt::Hdfs => parse_hdfs(s),
            Fmt::Ssh => parse_ssh(s),
            Fmt::Apache => parse_apache(s),
            Fmt::Bgl => parse_bgl(s),
        };
        let Some(h) = parsed else {
            c.malformed += 1;
            if let Some(r) = rejects.as_deref_mut() {
                r.extend_from_slice(raw);
                r.push(b'\n');
            }
            continue;
        };
        if h.level < min_level(h.comp) || (fmt == Fmt::Bgl && h.level < ERROR && h.comp == b"APP") {
            c.dropped += 1;
            continue;
        }
        c.kept += 1;
        let comp = if fmt == Fmt::Apache { fixed(b"httpd") } else { in_data(h.comp) };
        let at = a.bytes.len();
        let mut changed = redact(h.msg, &mut a.bytes);
        if !changed && next_hex(h.msg, 0).is_some() {
            a.bytes.extend_from_slice(h.msg);
            changed = true;
        }
        if changed {
            redact_hex(&mut a.bytes, at);
        }
        let msg = if changed {
            Sp { off: dl + at as u32, len: (a.bytes.len() - at) as u32 }
        } else {
            in_data(h.msg)
        };
        let Arena { kvs, bytes, kv, recs } = &mut *a;
        let bytes = &bytes[..];
        kv.clear();
        for &(k, v) in &h.fp[..h.nf] {
            add_pair(kv, data, bytes, fixed(k), in_data(v));
        }
        let m = get(msg, data, bytes);
        let mut t = 0;
        for tok in m.split(|&b| b == b' ') {
            let p = tok.iter().position(|&b| b == b'=' || !is_key_byte(b));
            if let Some(p) = p {
                if p > 0 && tok[p] == b'=' {
                    let o = msg.off + t as u32;
                    let (k, v) = (Sp { off: o, len: p as u32 }, Sp { off: o + p as u32 + 1, len: (tok.len() - p - 1) as u32 });
                    add_pair(kv, data, bytes, k, v);
                }
            }
            t += tok.len() + 1;
        }
        let kv_lo = kvs.len() as u32;
        kvs.extend_from_slice(kv);
        recs.push(Rec { ts: h.ts, level: h.level, comp, msg, kv_lo, kv_n: kv.len() as u32 });
    }
    for r in &a.recs {
        render(out, r, data, a);
    }
}

// --- reading batches ------------------------------------------------------------------

/// A file read in 1 MiB blocks into a buffer that keeps its capacity: `buf[..filled]` holds the bytes
/// not yet handed out as a batch.
struct Reader {
    input: Box<dyn Read>,
    name: String,
    buf: Vec<u8>,
    filled: usize,
    eof: bool,
}

impl Reader {
    /// A reader over `file` that fills `buf` (a buffer from an earlier file, reused).
    fn new(input: Box<dyn Read>, name: String, buf: Vec<u8>) -> Reader {
        Reader { input, name, buf, filled: 0, eof: false }
    }

    /// The length of the next batch at the front of `buf[..filled]`: through its 65,536th newline, or
    /// all that's left at the end of the file. 0 when the file is done.
    fn next_batch(&mut self) -> usize {
        let mut lines = 0;
        let mut scan = 0;
        loop {
            for k in memchr::memchr_iter(b'\n', &self.buf[scan..self.filled]) {
                lines += 1;
                if lines == BATCH {
                    return scan + k + 1;
                }
            }
            scan = self.filled;
            if self.eof {
                return self.filled;
            }
            if self.buf.len() < self.filled + BLOCK {
                self.buf.resize(self.filled + BLOCK, 0);
            }
            let name = &self.name;
            let n = self.input.read(&mut self.buf[self.filled..self.filled + BLOCK]).unwrap_or_else(|e| io_fail(&format!("cannot read {name}: {e}")));
            if n == 0 {
                self.eof = true;
            }
            self.filled += n;
        }
    }

    /// Drops the first n bytes, keeping the rest at the front.
    fn consume(&mut self, n: usize) {
        self.buf.copy_within(n..self.filled, 0);
        self.filled -= n;
    }
}

// --- main ---------------------------------------------------------------------------

/// --out's temporary file, removed on failure.
static TMP: OnceLock<String> = OnceLock::new();

fn abandon() {
    if let Some(t) = TMP.get() {
        let _ = fs::remove_file(t);
    }
}

/// Exit codes, SPEC A2: 1 reject rate exceeded, 2 bad command line, 3 I/O failure.
fn io_fail(msg: &str) -> ! {
    abandon();
    eprintln!("sanitize: {msg}");
    std::process::exit(3);
}

fn usage() -> ! {
    eprintln!("usage: sanitize [--out FILE] [--rejects FILE] [--max-reject-rate R] FORMAT PATH [FORMAT PATH ...]");
    std::process::exit(2);
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    let mut a = 1;
    let (mut out_path, mut rejects_path, mut max_rate) = (None, None, None);
    while a < argv.len() && argv[a].starts_with("--") {
        if a + 1 >= argv.len() {
            usage();
        }
        match argv[a].as_str() {
            "--out" => out_path = Some(argv[a + 1].clone()),
            "--rejects" => rejects_path = Some(argv[a + 1].clone()),
            "--max-reject-rate" => max_rate = Some(argv[a + 1].parse::<f64>().unwrap_or_else(|_| usage())),
            _ => usage(),
        }
        a += 2;
    }
    if argv.len() <= a || (argv.len() - a) % 2 != 0 {
        usage();
    }
    let inputs: Vec<(Fmt, &str)> = argv[a..]
        .chunks(2)
        .map(|p| {
            let fmt = match p[0].as_str() {
                "hdfs" => Fmt::Hdfs,
                "ssh" => Fmt::Ssh,
                "apache" => Fmt::Apache,
                "bgl" => Fmt::Bgl,
                _ => usage(),
            };
            (fmt, p[1].as_str())
        })
        .collect();

    // Writes go straight to the descriptor: std's stdout would scan each buffer for newlines.
    let mut out: File = match &out_path {
        Some(p) => {
            let tmp = format!("{p}.tmp");
            let f = File::create(&tmp).unwrap_or_else(|e| io_fail(&format!("cannot create {p}: {e}")));
            let _ = TMP.set(tmp);
            f
        }
        None => File::from(std::io::stdout().as_fd().try_clone_to_owned().unwrap_or_else(|e| io_fail(&format!("stdout: {e}")))),
    };
    let mut rejects_file = rejects_path.as_ref().map(|p| File::create(p).unwrap_or_else(|e| io_fail(&format!("cannot create {p}: {e}"))));

    let mut total = Counts::default();
    let mut arena = Arena::default();
    let (mut rendered, mut rejects, mut buf) = (Vec::new(), Vec::new(), Vec::new());
    for &(fmt, path) in &inputs {
        let input: Box<dyn Read> = if path == "-" {
            Box::new(std::io::stdin().lock())
        } else {
            Box::new(File::open(path).unwrap_or_else(|e| io_fail(&format!("cannot open {path}: {e}"))))
        };
        let mut r = Reader::new(input, path.to_string(), buf);
        loop {
            let end = r.next_batch();
            if end == 0 {
                break;
            }
            rendered.clear();
            rejects.clear();
            process(fmt, &r.buf[..end], &mut arena, &mut rendered, rejects_file.as_ref().map(|_| &mut rejects), &mut total);
            out.write_all(&rendered).unwrap_or_else(|e| io_fail(&format!("cannot write output: {e}")));
            if let Some(f) = rejects_file.as_mut() {
                f.write_all(&rejects).unwrap_or_else(|e| io_fail(&format!("cannot write rejects: {e}")));
            }
            r.consume(end);
        }
        buf = r.buf;
    }
    eprintln!("lines={} kept={} dropped={} malformed={}", total.lines, total.kept, total.dropped, total.malformed);
    if let Some(r) = max_rate {
        if total.lines > 0 && total.malformed as f64 / total.lines as f64 > r {
            abandon();
            eprintln!("sanitize: reject rate exceeded");
            std::process::exit(1);
        }
    }
    if let Some(p) = &out_path {
        drop(out);
        fs::rename(TMP.get().expect("set above"), p).unwrap_or_else(|e| io_fail(&format!("cannot rename to {p}: {e}")));
    }
}
