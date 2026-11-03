//! logxform, the arena Rust version: see experiments/02-logxform/SPEC.md.
//!
//! A hand-written byte parser builds each batch's records in a per-batch `bumpalo` arena. Records borrow
//! from the batch's input bytes; only a message that redaction rewrites and the key-value lists are
//! allocated, in the arena. Rendering writes straight into a reused output buffer. The arena is reset
//! for the next batch, so steady state does no heap allocation at all.

use bumpalo::collections::Vec as BVec;
use bumpalo::Bump;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Write};

const BATCH: usize = 65536;
const BLOCK: usize = 1 << 20;

#[derive(Clone, Copy, PartialEq)]
enum Fmt {
    Hdfs,
    Ssh,
    Apache,
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

struct Rec<'a> {
    ts: Ts,
    level: u8,
    comp: &'a [u8],
    msg: &'a [u8],
    kv: &'a [Kv<'a>],
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

/// The redacted message: borrowed as is when it has no address, else built once in the arena.
fn redact<'a>(msg: &'a [u8], bump: &'a Bump) -> &'a [u8] {
    let Some(mut ip) = next_ip(msg, 0) else { return msg };
    let mut out = BVec::with_capacity_in(msg.len(), bump);
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
    out.into_bump_slice()
}

#[inline]
fn is_key_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'-'
}

/// Dictionary semantics: an existing key keeps its place and takes the new value.
#[inline]
fn add_pair<'a>(kv: &mut Vec<Kv<'a>>, k: &'a [u8], v: &'a [u8]) {
    match kv.iter_mut().find(|(key, _)| *key == k) {
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
fn put_str(out: &mut Vec<u8>, s: &[u8]) {
    out.push(b'"');
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

fn render(out: &mut Vec<u8>, r: &Rec) {
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
    put_str(out, r.comp);
    out.extend_from_slice(b",\"msg\":");
    put_str(out, r.msg);
    out.extend_from_slice(b",\"kv\":{");
    for (i, (k, v)) in r.kv.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        put_str(out, k);
        out.push(b':');
        put_str(out, v);
    }
    out.extend_from_slice(b"}}\n");
}

/// One batch: parse every line into a record in the arena, then render them all into `out`.
fn process(fmt: Fmt, data: &[u8], bump: &mut Bump, out: &mut Vec<u8>, c: &mut Counts) {
    bump.reset();
    let bump = &*bump;
    let mut recs: BVec<Rec> = BVec::with_capacity_in(BATCH, bump);
    // Pairs are collected in a reused scratch list, then copied into the arena at their exact size.
    let mut kv: Vec<Kv> = Vec::with_capacity(16);
    let mut start = 0;
    while start < data.len() {
        let e = memchr::memchr(b'\n', &data[start..]).map_or(data.len(), |k| start + k);
        let mut s = &data[start..e];
        start = e + 1;
        if let [rest @ .., b'\r'] = s {
            s = rest;
        }
        c.lines += 1;
        let parsed = match fmt {
            Fmt::Hdfs => parse_hdfs(s),
            Fmt::Ssh => parse_ssh(s),
            Fmt::Apache => parse_apache(s),
        };
        let Some(h) = parsed else {
            c.malformed += 1;
            continue;
        };
        if h.level < min_level(h.comp) {
            c.dropped += 1;
            continue;
        }
        c.kept += 1;
        let msg = redact(h.msg, bump);
        kv.clear();
        for &(k, v) in &h.fp[..h.nf] {
            add_pair(&mut kv, k, v);
        }
        for tok in msg.split(|&b| b == b' ') {
            let p = tok.iter().position(|&b| b == b'=' || !is_key_byte(b));
            if let Some(p) = p {
                if p > 0 && tok[p] == b'=' {
                    add_pair(&mut kv, &tok[..p], &tok[p + 1..]);
                }
            }
        }
        recs.push(Rec { ts: h.ts, level: h.level, comp: h.comp, msg, kv: bump.alloc_slice_copy(&kv) });
    }
    for r in &recs {
        render(out, r);
    }
}

// --- reading batches ------------------------------------------------------------------

/// A file read in 1 MiB blocks into a buffer that keeps its capacity: `buf[..filled]` holds the bytes
/// not yet handed out as a batch.
struct Reader {
    file: File,
    buf: Vec<u8>,
    filled: usize,
    eof: bool,
}

impl Reader {
    fn new(file: File) -> Reader {
        Reader { file, buf: Vec::new(), filled: 0, eof: false }
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
            let n = self.file.read(&mut self.buf[self.filled..self.filled + BLOCK]).unwrap_or_else(|e| fail(&format!("read: {e}")));
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

fn fail(msg: &str) -> ! {
    eprintln!("logxform: {msg}");
    std::process::exit(1);
}

// --- threads ----------------------------------------------------------------------------

struct Job {
    seq: u64,
    fmt: Fmt,
    data: Vec<u8>,
}

struct Done {
    seq: u64,
    c: Counts,
    data: Vec<u8>,
    out: Vec<u8>,
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    let mut a = 1;
    let mut threads = 1usize;
    if argv.len() > 2 && argv[1] == "-t" {
        threads = argv[2].parse().ok().filter(|&n| n >= 1).unwrap_or_else(|| usage());
        a = 3;
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
                f => fail(&format!("unknown format {f}")),
            };
            (fmt, p[1].as_str())
        })
        .collect();
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    let total = if threads == 1 { run_single(&inputs, &mut stdout) } else { run_threads(&inputs, threads, &mut stdout) };
    stdout.flush().unwrap_or_else(|e| fail(&format!("write: {e}")));
    eprintln!("lines={} kept={} dropped={} malformed={}", total.lines, total.kept, total.dropped, total.malformed);
}

fn usage() -> ! {
    fail("usage: logxform [-t N] FORMAT FILE [FORMAT FILE ...]")
}

fn open(path: &str) -> File {
    File::open(path).unwrap_or_else(|e| fail(&format!("cannot open {path}: {e}")))
}

fn write_out(w: &mut impl Write, b: &[u8]) {
    w.write_all(b).unwrap_or_else(|e| fail(&format!("write: {e}")));
}

fn run_single(inputs: &[(Fmt, &str)], w: &mut impl Write) -> Counts {
    let mut total = Counts::default();
    let mut bump = Bump::new();
    let mut out = Vec::new();
    for &(fmt, path) in inputs {
        let mut r = Reader::new(open(path));
        loop {
            let end = r.next_batch();
            if end == 0 {
                break;
            }
            out.clear();
            process(fmt, &r.buf[..end], &mut bump, &mut out, &mut total);
            write_out(w, &out);
            r.consume(end);
        }
    }
    total
}

/// The main thread reads and writes; workers process. A batch's input buffer is handed to a worker
/// whole (the unread remainder is copied into a recycled buffer instead), and input and output buffers
/// come back to be reused. Results are written in sequence; early ones wait in `pending`.
fn run_threads(inputs: &[(Fmt, &str)], threads: usize, w: &mut impl Write) -> Counts {
    let cap = 2 * threads;
    let (job_tx, job_rx) = crossbeam_channel::bounded::<Job>(cap);
    let (done_tx, done_rx) = crossbeam_channel::bounded::<Done>(cap);
    let (outbuf_tx, outbuf_rx) = crossbeam_channel::unbounded::<Vec<u8>>();
    let mut total = Counts::default();
    std::thread::scope(|scope| {
        for _ in 0..threads {
            let (job_rx, done_tx, outbuf_rx) = (job_rx.clone(), done_tx.clone(), outbuf_rx.clone());
            scope.spawn(move || {
                let mut bump = Bump::new();
                for job in job_rx {
                    let mut out = outbuf_rx.try_recv().unwrap_or_default();
                    out.clear();
                    let mut c = Counts::default();
                    process(job.fmt, &job.data, &mut bump, &mut out, &mut c);
                    if done_tx.send(Done { seq: job.seq, c, data: job.data, out }).is_err() {
                        break;
                    }
                }
            });
        }
        drop(done_tx);
        let mut free_in: Vec<Vec<u8>> = Vec::new();
        let mut pending: BTreeMap<u64, Done> = BTreeMap::new();
        let (mut seq, mut next_write, mut in_flight) = (0u64, 0u64, 0usize);
        let mut receive = |free_in: &mut Vec<Vec<u8>>, in_flight: &mut usize, total: &mut Counts| {
            let d = done_rx.recv().expect("workers alive");
            total.add(&d.c);
            pending.insert(d.seq, d);
            while let Some(d) = pending.remove(&next_write) {
                write_out(w, &d.out);
                next_write += 1;
                *in_flight -= 1;
                free_in.push(d.data);
                let _ = outbuf_tx.send(d.out);
            }
        };
        for &(fmt, path) in inputs {
            let mut r = Reader::new(open(path));
            loop {
                let end = r.next_batch();
                if end == 0 {
                    break;
                }
                while in_flight >= cap {
                    receive(&mut free_in, &mut in_flight, &mut total);
                }
                // Hand over the reader's buffer; the remainder moves to a recycled one.
                let mut next = free_in.pop().unwrap_or_default();
                next.clear();
                next.extend_from_slice(&r.buf[end..r.filled]);
                let mut data = std::mem::replace(&mut r.buf, next);
                r.filled -= end;
                data.truncate(end);
                job_tx.send(Job { seq, fmt, data }).expect("workers alive");
                seq += 1;
                in_flight += 1;
            }
        }
        while in_flight > 0 {
            receive(&mut free_in, &mut in_flight, &mut total);
        }
        drop(job_tx);
    });
    total
}
