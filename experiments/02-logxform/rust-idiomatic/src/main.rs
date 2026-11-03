//! logxform, the idiomatic Rust version (context only): see experiments/02-logxform/SPEC.md.
//!
//! Owned `String`s for every line and field, a `Vec<Record>` per batch, `serde` derive and `serde_json`
//! for rendering. Written the way most Rust code would be written first.

use serde::ser::{Serialize, SerializeMap, Serializer};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

const BATCH: usize = 65536;
const BLOCK: usize = 1 << 20;

#[derive(Clone, Copy, PartialEq, PartialOrd)]
enum Level {
    Trace,
    Debug,
    Info,
    Notice,
    Warn,
    Error,
    Fatal,
}

impl Level {
    fn name(self) -> &'static str {
        match self {
            Level::Trace => "TRACE",
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Notice => "NOTICE",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
            Level::Fatal => "FATAL",
        }
    }
    fn sev(self) -> u8 {
        match self {
            Level::Fatal => 2,
            Level::Error => 3,
            Level::Warn => 4,
            Level::Notice => 5,
            Level::Info => 6,
            Level::Debug | Level::Trace => 7,
        }
    }
}

/// An insertion-ordered map with dictionary semantics, serialized as a JSON object.
#[derive(Default)]
struct Fields(Vec<(String, String)>);

impl Fields {
    fn insert(&mut self, k: String, v: String) {
        match self.0.iter_mut().find(|(key, _)| *key == k) {
            Some(p) => p.1 = v,
            None => self.0.push((k, v)),
        }
    }
}

impl Serialize for Fields {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(Some(self.0.len()))?;
        for (k, v) in &self.0 {
            m.serialize_entry(k, v)?;
        }
        m.end()
    }
}

#[derive(serde::Serialize)]
struct Record {
    ts: String,
    level: &'static str,
    sev: u8,
    component: String,
    msg: String,
    kv: Fields,
}

/// A parsed line, before the transform.
struct Parsed {
    ts: (u32, u32, u32, u32, u32, u32),
    level: Level,
    component: String,
    msg: String,
    pairs: Vec<(String, String)>,
}

#[derive(Clone, Copy, Default)]
struct Counts {
    lines: u64,
    kept: u64,
    dropped: u64,
    malformed: u64,
}

#[derive(Clone, Copy)]
enum Format {
    Hdfs,
    Ssh,
    Apache,
}

const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// A fixed-width number of exactly `width` digits.
fn num(s: &str, width: usize) -> Option<u32> {
    if s.len() == width && all_digits(s) {
        s.parse().ok()
    } else {
        None
    }
}

fn month(s: &str) -> Option<u32> {
    MONTHS.iter().position(|m| *m == s).map(|i| i as u32 + 1)
}

/// HH:MM:SS
fn clock(s: &str) -> Option<(u32, u32, u32)> {
    let mut it = s.split(':');
    let (h, m, sec) = (it.next()?, it.next()?, it.next()?);
    if it.next().is_some() {
        return None;
    }
    Some((num(h, 2)?, num(m, 2)?, num(sec, 2)?))
}

fn valid_ts(t: (u32, u32, u32, u32, u32, u32)) -> bool {
    (1..=12).contains(&t.1) && (1..=31).contains(&t.2) && t.3 <= 23 && t.4 <= 59 && t.5 <= 59
}

/// YYMMDD HHMMSS PID LEVEL COMPONENT: MSG
fn parse_hdfs(line: &str) -> Option<Parsed> {
    let mut it = line.splitn(5, ' ');
    let (date, time, pid, level, rest) = (it.next()?, it.next()?, it.next()?, it.next()?, it.next()?);
    let (date, time) = (num(date, 6)?, num(time, 6)?);
    if !all_digits(pid) {
        return None;
    }
    let level = match level {
        "TRACE" => Level::Trace,
        "DEBUG" => Level::Debug,
        "INFO" => Level::Info,
        "WARN" => Level::Warn,
        "ERROR" => Level::Error,
        "FATAL" => Level::Fatal,
        _ => return None,
    };
    let (component, msg) = rest.split_once(": ")?;
    if component.is_empty() || component.contains(' ') {
        return None;
    }
    let ts = (2000 + date / 10000, date / 100 % 100, date % 100, time / 10000, time / 100 % 100, time % 100);
    let mut pairs = vec![("pid".to_string(), pid.to_string())];
    if let Some(tok) = msg.split(' ').find(|t| t.starts_with("blk_")) {
        let tail = &tok[4..];
        let sign = usize::from(tail.starts_with('-'));
        let n = tail[sign..].bytes().take_while(|b| b.is_ascii_digit()).count();
        if n > 0 {
            pairs.push(("blk".to_string(), tok[..4 + sign + n].to_string()));
        }
    }
    Some(Parsed { ts, level, component: component.to_string(), msg: msg.to_string(), pairs })
}

/// Mmm DD HH:MM:SS HOST PROG[PID]: MSG
fn parse_ssh(line: &str) -> Option<Parsed> {
    if line.len() < 16 || !line.is_char_boundary(16) || &line[15..16] != " " || &line[3..4] != " " || &line[6..7] != " " {
        return None;
    }
    let mo = month(&line[0..3])?;
    let day = match line[4..6].strip_prefix(' ') {
        Some(d) => num(d, 1)?,
        None => num(&line[4..6], 2)?,
    };
    let (h, mi, s) = clock(&line[7..15])?;
    let (host, rest) = line[16..].split_once(' ')?;
    if host.is_empty() {
        return None;
    }
    let (prog, rest) = rest.split_once('[')?;
    if prog.is_empty() || prog.contains(' ') {
        return None;
    }
    let (pid, msg) = rest.split_once("]: ")?;
    if !all_digits(pid) {
        return None;
    }
    let level = if msg.starts_with("error: ") {
        Level::Error
    } else if msg.starts_with("fatal: ") {
        Level::Fatal
    } else if msg.starts_with("Failed ") || msg.starts_with("Invalid user ") || msg.starts_with("reverse mapping ") {
        Level::Warn
    } else {
        Level::Info
    };
    let year = if mo >= 7 { 2017 } else { 2018 };
    Some(Parsed {
        ts: (year, mo, day, h, mi, s),
        level,
        component: prog.to_string(),
        msg: msg.to_string(),
        pairs: vec![("host".to_string(), host.to_string()), ("pid".to_string(), pid.to_string())],
    })
}

/// [Www Mmm DD HH:MM:SS YYYY] [level] MSG
fn parse_apache(line: &str) -> Option<Parsed> {
    let rest = line.strip_prefix('[')?;
    let (stamp, rest) = rest.split_once("] [")?;
    let f: Vec<&str> = stamp.split(' ').collect();
    if f.len() != 5 || !WEEKDAYS.contains(&f[0]) {
        return None;
    }
    let mo = month(f[1])?;
    let day = num(f[2], 2)?;
    let (h, mi, s) = clock(f[3])?;
    let year = num(f[4], 4)?;
    let (level, msg) = rest.split_once("] ")?;
    let level = match level {
        "emerg" | "alert" | "crit" => Level::Fatal,
        "error" => Level::Error,
        "warn" => Level::Warn,
        "notice" => Level::Notice,
        "info" => Level::Info,
        "debug" => Level::Debug,
        _ => return None,
    };
    Some(Parsed { ts: (year, mo, day, h, mi, s), level, component: "httpd".to_string(), msg: msg.to_string(), pairs: Vec::new() })
}

fn min_level(component: &str) -> Level {
    match component {
        "dfs.DataNode$PacketResponder" | "dfs.FSDataset" => Level::Warn,
        _ => Level::Info,
    }
}

fn is_ipv4(s: &str) -> bool {
    s.split('.').count() == 4 && s.split('.').all(|g| (1..=3).contains(&g.len()))
}

fn redact(msg: &str) -> String {
    let b = msg.as_bytes();
    let mut out = String::with_capacity(msg.len());
    let (mut i, mut start) = (0, 0);
    while i < b.len() {
        if b[i].is_ascii_digit() && (i == 0 || !(b[i - 1].is_ascii_digit() || b[i - 1] == b'.')) {
            let j = i + b[i..].iter().take_while(|&&c| c.is_ascii_digit() || c == b'.').count();
            let core = msg[i..j].trim_end_matches('.');
            if is_ipv4(core) {
                out.push_str(&msg[start..i]);
                out.push_str("<ip>");
                start = i + core.len();
            }
            i = j;
        } else {
            i += 1;
        }
    }
    out.push_str(&msg[start..]);
    out
}

fn transform(p: Parsed) -> Record {
    let (y, mo, d, h, mi, s) = p.ts;
    let msg = redact(&p.msg);
    let mut kv = Fields::default();
    for (k, v) in p.pairs {
        kv.insert(k, v);
    }
    for tok in msg.split(' ') {
        if let Some((k, v)) = tok.split_once('=') {
            if !k.is_empty() && k.bytes().all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c)) {
                kv.insert(k.to_string(), v.to_string());
            }
        }
    }
    Record {
        ts: format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z"),
        level: p.level.name(),
        sev: p.level.sev(),
        component: p.component,
        msg,
        kv,
    }
}

/// One batch: parse every line into a record, then render them all.
fn process(format: Format, lines: &[String], c: &mut Counts) -> Vec<u8> {
    let mut records = Vec::new();
    for line in lines {
        c.lines += 1;
        let parsed = match format {
            Format::Hdfs => parse_hdfs(line),
            Format::Ssh => parse_ssh(line),
            Format::Apache => parse_apache(line),
        };
        let Some(p) = parsed.filter(|p| valid_ts(p.ts)) else {
            c.malformed += 1;
            continue;
        };
        if p.level < min_level(&p.component) {
            c.dropped += 1;
            continue;
        }
        c.kept += 1;
        records.push(transform(p));
    }
    let mut out = Vec::new();
    for r in &records {
        serde_json::to_writer(&mut out, r).expect("serializing a record");
        out.push(b'\n');
    }
    out
}

/// Batches of up to 65,536 lines, read through a 1 MiB buffer.
struct Batches {
    reader: BufReader<File>,
}

impl Iterator for Batches {
    type Item = Vec<String>;
    fn next(&mut self) -> Option<Vec<String>> {
        let mut lines = Vec::with_capacity(BATCH);
        while lines.len() < BATCH {
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    if line.ends_with('\n') {
                        line.pop();
                    }
                    if line.ends_with('\r') {
                        line.pop();
                    }
                    lines.push(line);
                }
                Err(e) => fail(&format!("read: {e}")),
            }
        }
        if lines.is_empty() {
            None
        } else {
            Some(lines)
        }
    }
}

fn fail(msg: &str) -> ! {
    eprintln!("logxform: {msg}");
    std::process::exit(1);
}

fn usage() -> ! {
    fail("usage: logxform [-t N] FORMAT FILE [FORMAT FILE ...]")
}

fn batches(path: &str) -> Batches {
    let file = File::open(path).unwrap_or_else(|e| fail(&format!("cannot open {path}: {e}")));
    Batches { reader: BufReader::with_capacity(BLOCK, file) }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (threads, files) = match args.as_slice() {
        [flag, n, rest @ ..] if flag == "-t" => (n.parse::<usize>().ok().filter(|&n| n >= 1).unwrap_or_else(|| usage()), rest),
        rest => (1, rest),
    };
    if files.is_empty() || files.len() % 2 != 0 {
        usage();
    }
    let inputs: Vec<(Format, String)> = files
        .chunks(2)
        .map(|p| {
            let format = match p[0].as_str() {
                "hdfs" => Format::Hdfs,
                "ssh" => Format::Ssh,
                "apache" => Format::Apache,
                f => fail(&format!("unknown format {f}")),
            };
            (format, p[1].clone())
        })
        .collect();

    let mut stdout = std::io::stdout().lock();
    let mut total = Counts::default();
    if threads == 1 {
        for (format, path) in &inputs {
            for batch in batches(path) {
                let out = process(*format, &batch, &mut total);
                stdout.write_all(&out).unwrap_or_else(|e| fail(&format!("write: {e}")));
            }
        }
    } else {
        total = run_threads(&inputs, threads, &mut stdout);
    }
    stdout.flush().unwrap_or_else(|e| fail(&format!("write: {e}")));
    eprintln!("lines={} kept={} dropped={} malformed={}", total.lines, total.kept, total.dropped, total.malformed);
}

/// Workers take batches from a shared queue; the main thread reads, and writes results in order.
fn run_threads(inputs: &[(Format, String)], threads: usize, stdout: &mut impl Write) -> Counts {
    let (job_tx, job_rx) = mpsc::sync_channel::<(u64, Format, Vec<String>)>(threads);
    let job_rx = Arc::new(Mutex::new(job_rx));
    let (done_tx, done_rx) = mpsc::channel::<(u64, Counts, Vec<u8>)>();
    let mut workers = Vec::new();
    for _ in 0..threads {
        let (job_rx, done_tx) = (Arc::clone(&job_rx), done_tx.clone());
        workers.push(std::thread::spawn(move || loop {
            let job = job_rx.lock().unwrap().recv();
            let Ok((seq, format, lines)) = job else { break };
            let mut c = Counts::default();
            let out = process(format, &lines, &mut c);
            if done_tx.send((seq, c, out)).is_err() {
                break;
            }
        }));
    }
    drop(done_tx);

    let mut total = Counts::default();
    let mut pending = BTreeMap::new();
    let (mut seq, mut next_write, mut in_flight) = (0u64, 0u64, 0usize);
    let mut receive = |total: &mut Counts, in_flight: &mut usize| {
        let (s, c, out) = done_rx.recv().expect("workers alive");
        total.lines += c.lines;
        total.kept += c.kept;
        total.dropped += c.dropped;
        total.malformed += c.malformed;
        pending.insert(s, out);
        while let Some(out) = pending.remove(&next_write) {
            stdout.write_all(&out).unwrap_or_else(|e| fail(&format!("write: {e}")));
            next_write += 1;
            *in_flight -= 1;
        }
    };
    for (format, path) in inputs {
        for batch in batches(path) {
            while in_flight >= 2 * threads {
                receive(&mut total, &mut in_flight);
            }
            job_tx.send((seq, *format, batch)).expect("workers alive");
            seq += 1;
            in_flight += 1;
        }
    }
    while in_flight > 0 {
        receive(&mut total, &mut in_flight);
    }
    drop(job_tx);
    for w in workers {
        w.join().expect("worker");
    }
    total
}
