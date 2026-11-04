//! symidx, the expert Rust version: string arenas and offset tables, archived with rkyv and
//! accessed in place over an mmap. `rkyv::access` (bytecheck) checks structure; `validate`
//! checks every cross-reference before any query (bench/SPEC.md "Image validation").

use rayon::prelude::*;
use rkyv::rancor::Error;
use rkyv::{Archive, Serialize};
use rustc_hash::FxHashMap;
use std::fs;
use std::io::{self, BufWriter, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::Path;
use std::process::exit;
use std::time::Instant;

const MAGIC: &[u8; 8] = b"SYMIDX1\n";

/// Offset tables carry a sentinel: item i spans `starts[i]..starts[i + 1]`.
#[derive(Archive, Serialize)]
struct Index {
    paths: Vec<u8>,       // all relative paths, concatenated in path order
    path_at: Vec<u32>,    // files + 1 offsets into paths
    names: Vec<u8>,       // all unique names, concatenated in name order
    name_at: Vec<u32>,    // groups + 1 offsets into names
    occ_at: Vec<u32>,     // groups + 1 offsets into occs
    occs: Vec<Occ>,       // sorted by (name, file, line)
}

#[derive(Archive, Serialize, Clone, Copy)]
struct Occ {
    file: u32,
    line_kind: u32, // line << 1 | kind (0 def, 1 class)
}

fn fail(msg: &str) -> ! {
    eprintln!("symidx: {msg}");
    exit(1);
}

/// bench/SPEC.md "Line parsing": the name's byte range and the kind (0 def, 1 class).
fn parse_line(s: &[u8]) -> Option<(usize, usize, u32)> {
    let ws = |c: u8| c == b' ' || c == b'\t';
    let ident = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c >= 0x80;
    let skip = |mut i: usize| {
        while i < s.len() && ws(s[i]) {
            i += 1;
        }
        i
    };
    let mut i = skip(0);
    if s[i..].starts_with(b"async") && s.get(i + 5).is_some_and(|&c| ws(c)) {
        i = skip(i + 5);
    }
    let (kind, j) = if s[i..].starts_with(b"def") {
        (0, i + 3)
    } else if s[i..].starts_with(b"class") {
        (1, i + 5)
    } else {
        return None;
    };
    if !s.get(j).is_some_and(|&c| ws(c)) {
        return None;
    }
    let j = skip(j);
    let k = j + s[j..].iter().take_while(|&&c| ident(c)).count();
    (k > j).then_some((j, k, kind))
}

fn walk(root: &Path, rel: &mut Vec<u8>, out: &mut Vec<Vec<u8>>) {
    let dir = root.join(std::ffi::OsStr::from_bytes(rel));
    let entries = fs::read_dir(&dir).unwrap_or_else(|e| fail(&format!("cannot list {}: {e}", dir.display())));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| fail(&e.to_string()));
        let ty = entry.file_type().unwrap_or_else(|e| fail(&e.to_string())); // lstat semantics
        let name = entry.file_name().into_vec();
        let len = rel.len();
        if len > 0 {
            rel.push(b'/');
        }
        rel.extend_from_slice(&name);
        if ty.is_dir() {
            walk(root, rel, out);
        } else if ty.is_file() && name.ends_with(b".py") {
            out.push(rel.clone());
        }
        rel.truncate(len);
    }
}

/// One file's symbols: names concatenated in `text`, (end in text, line, kind) per symbol.
struct Parsed {
    text: Vec<u8>,
    syms: Vec<(u32, u32, u32)>,
}

fn build(root: &str, out: &str) {
    let root = Path::new(root);
    let mut files = Vec::new();
    walk(root, &mut Vec::new(), &mut files);
    files.sort_unstable();
    if std::env::var_os("SYMIDX_BUILD").is_some_and(|v| v == "batch") {
        build_batch(root, files, out)
    } else {
        build_streaming(root, files, out)
    }
}

fn parse_file(root: &Path, rel: &[u8]) -> Parsed {
    let src = fs::read(root.join(std::ffi::OsStr::from_bytes(rel))).unwrap_or_default();
    let mut p = Parsed { text: Vec::new(), syms: Vec::new() };
    for (n, line) in src.split(|&c| c == b'\n').enumerate() {
        if let Some((lo, hi, kind)) = parse_line(line) {
            p.text.extend_from_slice(&line[lo..hi]);
            p.syms.push((p.text.len() as u32, n as u32 + 1, kind));
        }
    }
    p
}

/// Names interned into one arena; the table holds ids and hashes the arena bytes, so no name is stored twice.
struct Interner {
    arena: Vec<u8>,
    spans: Vec<(u32, u32)>,
    table: hashbrown::HashTable<u32>,
    hasher: rustc_hash::FxBuildHasher,
}

impl Interner {
    fn name(&self, id: u32) -> &[u8] {
        let (lo, hi) = self.spans[id as usize];
        &self.arena[lo as usize..hi as usize]
    }

    fn intern(&mut self, name: &[u8]) -> u32 {
        use std::hash::BuildHasher;
        let h = self.hasher.hash_one(name);
        let Self { arena, spans, table, hasher } = self;
        let name_of = |id: &u32| {
            let (lo, hi) = spans[*id as usize];
            &arena[lo as usize..hi as usize]
        };
        if let Some(&id) = table.find(h, |id| name_of(id) == name) {
            return id;
        }
        let id = spans.len() as u32;
        let lo = arena.len() as u32;
        arena.extend_from_slice(name);
        spans.push((lo, arena.len() as u32));
        let (arena, spans) = (&*arena, &*spans);
        table.insert_unique(h, id, |id| {
            let (lo, hi) = spans[*id as usize];
            hasher.hash_one(&arena[lo as usize..hi as usize])
        });
        id
    }
}

/// Workers take files from a shared counter and send each file's symbols through a bounded
/// channel; the main thread interns them and drops the text, like goose/'s job window.
fn build_streaming(root: &Path, files: Vec<Vec<u8>>, out: &str) {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let workers = std::thread::available_parallelism().map_or(4, |n| n.get());
    let next = AtomicUsize::new(0);
    let mut it = Interner {
        arena: Vec::new(),
        spans: Vec::new(),
        table: hashbrown::HashTable::new(),
        hasher: Default::default(),
    };
    let mut syms: Vec<(u32, u32, u32)> = Vec::new();
    std::thread::scope(|s| {
        let (tx, rx) = std::sync::mpsc::sync_channel::<(u32, Parsed)>(4 * workers);
        for _ in 0..workers {
            let tx = tx.clone();
            let (next, files) = (&next, &files);
            s.spawn(move || loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                if i >= files.len() {
                    break;
                }
                if tx.send((i as u32, parse_file(root, &files[i]))).is_err() {
                    break;
                }
            });
        }
        drop(tx);
        for (file, p) in rx {
            let mut lo = 0usize;
            for &(hi, line, kind) in &p.syms {
                let id = it.intern(&p.text[lo..hi as usize]);
                lo = hi as usize;
                syms.push((id, file, line << 1 | kind));
            }
        }
    });

    let mut order: Vec<u32> = (0..it.spans.len() as u32).collect();
    order.par_sort_unstable_by(|&a, &b| it.name(a).cmp(it.name(b)));
    let mut rank = vec![0u32; order.len()];
    for (r, &id) in order.iter().enumerate() {
        rank[id as usize] = r as u32;
    }
    // In place: (rank, file, line << 1 | kind) sorts by (name, file, line), lines being unique per file.
    for s in &mut syms {
        s.0 = rank[s.0 as usize];
    }
    drop(rank);
    syms.par_sort_unstable();

    let mut index = Index {
        paths: Vec::new(),
        path_at: vec![0],
        names: Vec::with_capacity(it.arena.len()),
        name_at: vec![0],
        occ_at: vec![0],
        occs: Vec::with_capacity(syms.len()),
    };
    for f in &files {
        index.paths.extend_from_slice(f);
        index.path_at.push(index.paths.len() as u32);
    }
    drop(files);
    for &id in &order {
        index.names.extend_from_slice(it.name(id));
        index.name_at.push(index.names.len() as u32);
    }
    drop(it);
    for (i, &(r, file, lk)) in syms.iter().enumerate() {
        if i > 0 && r != syms[i - 1].0 {
            index.occ_at.push(index.occs.len() as u32);
        }
        index.occs.push(Occ { file, line_kind: lk });
    }
    if !syms.is_empty() {
        index.occ_at.push(index.occs.len() as u32);
    }
    let count = syms.len();
    drop(syms);
    let nfiles = index.path_at.len() - 1;
    write_image(&index, out);
    println!("symbols={count} files={nfiles}");
}

/// Magic, then the rkyv bytes, written in two parts rather than concatenated.
fn write_image(index: &Index, out: &str) {
    let bytes = rkyv::to_bytes::<Error>(index).unwrap_or_else(|e| fail(&e.to_string()));
    let mut f = fs::File::create(out).unwrap_or_else(|e| fail(&format!("cannot write {out}: {e}")));
    f.write_all(MAGIC).and_then(|_| f.write_all(&bytes)).unwrap_or_else(|e| fail(&format!("cannot write {out}: {e}")));
}

/// The first version, kept for the build-RAM comparison: every file's parsed text is held
/// until interning, and symbols are sorted as separate 16-byte keys.
fn build_batch(root: &Path, files: Vec<Vec<u8>>, out: &str) {
    let parsed: Vec<Parsed> = files.par_iter().map(|rel| parse_file(root, rel)).collect();

    // Intern names into an arena; symbols become (name id, file, line << 1 | kind).
    let mut arena: Vec<u8> = Vec::new();
    let mut spans: Vec<(u32, u32)> = Vec::new();
    let mut ids: FxHashMap<&[u8], u32> = FxHashMap::default();
    let mut syms: Vec<(u32, u32, u32)> = Vec::with_capacity(parsed.iter().map(|p| p.syms.len()).sum());
    for (file, p) in parsed.iter().enumerate() {
        let mut lo = 0usize;
        for &(hi, line, kind) in &p.syms {
            let name = &p.text[lo..hi as usize];
            lo = hi as usize;
            let id = *ids.entry(name).or_insert_with(|| {
                let start = arena.len() as u32;
                arena.extend_from_slice(name);
                spans.push((start, arena.len() as u32));
                spans.len() as u32 - 1
            });
            syms.push((id, file as u32, line << 1 | kind));
        }
    }
    let name_of = |id: u32| {
        let (lo, hi) = spans[id as usize];
        &arena[lo as usize..hi as usize]
    };
    let mut order: Vec<u32> = (0..spans.len() as u32).collect();
    order.par_sort_unstable_by(|&a, &b| name_of(a).cmp(name_of(b)));
    let mut rank = vec![0u32; order.len()];
    for (r, &id) in order.iter().enumerate() {
        rank[id as usize] = r as u32;
    }
    // (rank, file, line): line_kind sorts by line since kind is the low bit and lines are unique per file.
    let mut keys: Vec<u128> = syms
        .iter()
        .map(|&(id, file, lk)| (rank[id as usize] as u128) << 64 | (file as u128) << 32 | lk as u128)
        .collect();
    keys.par_sort_unstable();

    let mut index = Index {
        paths: Vec::new(),
        path_at: vec![0],
        names: Vec::with_capacity(arena.len()),
        name_at: vec![0],
        occ_at: vec![0],
        occs: Vec::with_capacity(keys.len()),
    };
    for f in &files {
        index.paths.extend_from_slice(f);
        index.path_at.push(index.paths.len() as u32);
    }
    for &id in &order {
        index.names.extend_from_slice(name_of(id));
        index.name_at.push(index.names.len() as u32);
    }
    let mut prev = u32::MAX;
    for &k in &keys {
        let r = (k >> 64) as u32;
        if r != prev && prev != u32::MAX {
            index.occ_at.push(index.occs.len() as u32);
        }
        prev = r;
        index.occs.push(Occ { file: (k >> 32) as u32, line_kind: k as u32 });
    }
    if !keys.is_empty() {
        index.occ_at.push(index.occs.len() as u32);
    }

    write_image(&index, out);
    println!("symbols={} files={}", keys.len(), files.len());
}

/// Checks every offset table and cross-reference; returns the symbol count.
fn validate(ix: &ArchivedIndex) -> usize {
    fn table(at: &[rkyv::rend::u32_le], end: usize, strict: bool, what: &str) -> usize {
        let ok = !at.is_empty()
            && at.windows(2).all(|w| if strict { w[0] < w[1] } else { w[0] <= w[1] })
            && at[at.len() - 1].to_native() as usize == end;
        if !ok {
            fail(&format!("invalid image: {what}"));
        }
        at.len() - 1
    }
    let nfiles = table(&ix.path_at, ix.paths.len(), false, "path table");
    let ngroups = table(&ix.name_at, ix.names.len(), true, "name table");
    if table(&ix.occ_at, ix.occs.len(), true, "occurrence table") != ngroups {
        fail("invalid image: group count");
    }
    for o in ix.occs.iter() {
        if o.file.to_native() as usize >= nfiles || o.line_kind.to_native() >> 1 == 0 {
            fail("invalid image: occurrence");
        }
    }
    ix.occs.len()
}

fn load(path: &str) -> (memmap2::Mmap, usize) {
    let file = fs::File::open(path).unwrap_or_else(|e| fail(&format!("cannot read {path}: {e}")));
    // SAFETY: the image is not modified while mapped; that's the deal symidx's CLI makes with its caller.
    let map = unsafe { memmap2::Mmap::map(&file) }.unwrap_or_else(|e| fail(&format!("cannot map {path}: {e}")));
    if !map.starts_with(MAGIC) {
        fail("not a symidx image");
    }
    let ix = rkyv::access::<ArchivedIndex, Error>(&map[MAGIC.len()..]).unwrap_or_else(|e| fail(&format!("invalid image: {e}")));
    let n = validate(ix);
    (map, n)
}

fn archived(map: &memmap2::Mmap) -> &ArchivedIndex {
    // SAFETY: `load` already ran `rkyv::access` (bytecheck) and `validate` over these bytes.
    unsafe { rkyv::access_unchecked::<ArchivedIndex>(&map[MAGIC.len()..]) }
}

fn find(ix: &ArchivedIndex, prefix: &[u8]) {
    let ngroups = ix.name_at.len() - 1;
    let at = |t: &[rkyv::rend::u32_le], i: usize| t[i].to_native() as usize;
    let name = |g: usize| &ix.names[at(&ix.name_at, g)..at(&ix.name_at, g + 1)];
    let (mut lo, mut hi) = (0, ngroups);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if name(mid) < prefix { lo = mid + 1 } else { hi = mid }
    }
    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(1 << 20, stdout.lock());
    let mut buf = itoa_buf();
    for g in lo..ngroups {
        let n = name(g);
        if !n.starts_with(prefix) {
            break;
        }
        for o in &ix.occs[at(&ix.occ_at, g)..at(&ix.occ_at, g + 1)] {
            let f = o.file.to_native() as usize;
            let lk = o.line_kind.to_native();
            out.write_all(n).unwrap();
            out.write_all(if lk & 1 == 0 { b"\tdef\t" } else { b"\tclass\t" }).unwrap();
            out.write_all(&ix.paths[at(&ix.path_at, f)..at(&ix.path_at, f + 1)]).unwrap();
            out.write_all(b"\t").unwrap();
            out.write_all(fmt_u32(&mut buf, lk >> 1)).unwrap();
            out.write_all(b"\n").unwrap();
        }
    }
    out.flush().unwrap();
}

// --- experiment: segmented validation (SYMIDX_VALIDATE=lazy) -----------------------------
// Not SPEC-conformant: SPEC requires eager validation of the whole image. Here `load` checks only
// structure (bytecheck) and the O(1) invariants; each 1024-entry chunk of an offset table, and the
// occurrences a chunk of groups spans, is checked the first time a query touches it and before
// anything from it is returned. Every chunk is monotonic and bounded by its array's length.

const CHUNK: usize = 1024;

struct Lazy<'a> {
    ix: &'a ArchivedIndex,
    nfiles: usize,
    names_ok: Vec<bool>,
    occs_ok: Vec<bool>,
    paths_ok: Vec<bool>,
}

fn chunk_ok(at: &[rkyv::rend::u32_le], c: usize, end: usize, strict: bool) -> bool {
    let lo = c * CHUNK;
    let hi = (lo + CHUNK).min(at.len() - 1);
    at[lo..=hi].windows(2).all(|w| if strict { w[0] < w[1] } else { w[0] <= w[1] }) && at[hi].to_native() as usize <= end
}

impl<'a> Lazy<'a> {
    /// The O(1) part of validation: table lengths and sentinels.
    fn new(ix: &'a ArchivedIndex) -> Self {
        let ok = !ix.path_at.is_empty()
            && !ix.name_at.is_empty()
            && ix.name_at.len() == ix.occ_at.len()
            && ix.path_at[ix.path_at.len() - 1].to_native() as usize == ix.paths.len()
            && ix.name_at[ix.name_at.len() - 1].to_native() as usize == ix.names.len()
            && ix.occ_at[ix.occ_at.len() - 1].to_native() as usize == ix.occs.len();
        if !ok {
            fail("invalid image: tables");
        }
        let chunks = |t: &[rkyv::rend::u32_le]| (t.len() - 1).div_ceil(CHUNK).max(1);
        Lazy {
            ix,
            nfiles: ix.path_at.len() - 1,
            names_ok: vec![false; chunks(&ix.name_at)],
            occs_ok: vec![false; chunks(&ix.occ_at)],
            paths_ok: vec![false; chunks(&ix.path_at)],
        }
    }

    fn at(t: &[rkyv::rend::u32_le], i: usize) -> usize {
        t[i].to_native() as usize
    }

    fn name(&mut self, g: usize) -> &'a [u8] {
        let c = g / CHUNK;
        if !self.names_ok[c] {
            if !chunk_ok(&self.ix.name_at, c, self.ix.names.len(), true) {
                fail("invalid image: name table");
            }
            self.names_ok[c] = true;
        }
        &self.ix.names[Self::at(&self.ix.name_at, g)..Self::at(&self.ix.name_at, g + 1)]
    }

    fn occs(&mut self, g: usize) -> &'a [ArchivedOcc] {
        let c = g / CHUNK;
        if !self.occs_ok[c] {
            let ix = self.ix;
            if !chunk_ok(&ix.occ_at, c, ix.occs.len(), true) {
                fail("invalid image: occurrence table");
            }
            let lo = Self::at(&ix.occ_at, c * CHUNK);
            let hi = Self::at(&ix.occ_at, (c * CHUNK + CHUNK).min(ix.occ_at.len() - 1));
            if ix.occs[lo..hi].iter().any(|o| o.file.to_native() as usize >= self.nfiles || o.line_kind.to_native() >> 1 == 0) {
                fail("invalid image: occurrence");
            }
            self.occs_ok[c] = true;
        }
        &self.ix.occs[Self::at(&self.ix.occ_at, g)..Self::at(&self.ix.occ_at, g + 1)]
    }

    fn path(&mut self, f: usize) -> &'a [u8] {
        let c = f / CHUNK;
        if !self.paths_ok[c] {
            if !chunk_ok(&self.ix.path_at, c, self.ix.paths.len(), false) {
                fail("invalid image: path table");
            }
            self.paths_ok[c] = true;
        }
        &self.ix.paths[Self::at(&self.ix.path_at, f)..Self::at(&self.ix.path_at, f + 1)]
    }
}

fn load_lazy(map: &memmap2::Mmap) -> Lazy<'_> {
    if !map.starts_with(MAGIC) {
        fail("not a symidx image");
    }
    let ix = rkyv::access::<ArchivedIndex, Error>(&map[MAGIC.len()..]).unwrap_or_else(|e| fail(&format!("invalid image: {e}")));
    Lazy::new(ix)
}

/// Experiment 3 (SYMIDX_VALIDATE=stream): the fair counterpart of Goose's `chunked` layout. Every
/// chunk is validated during load, so this conforms to SPEC's eager rule, and the mapping's pages are
/// dropped after each chunk, so validation doesn't leave the image resident.
fn load_stream(map: &memmap2::Mmap) -> Lazy<'_> {
    let mut lz = load_lazy(map);
    // SAFETY: the mapping is read-only and file-backed, so dropped pages fault back in unchanged.
    let drop_pages = || unsafe { map.unchecked_advise(memmap2::UncheckedAdvice::DontNeed) }.unwrap_or_else(|e| fail(&format!("madvise: {e}")));
    for g in (0..lz.ix.name_at.len() - 1).step_by(CHUNK) {
        lz.name(g);
        lz.occs(g);
        drop_pages();
    }
    for f in (0..lz.nfiles).step_by(CHUNK) {
        lz.path(f);
        drop_pages();
    }
    lz
}

fn find_lazy(lz: &mut Lazy, prefix: &[u8]) {
    let ngroups = lz.ix.name_at.len() - 1;
    let (mut lo, mut hi) = (0, ngroups);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if lz.name(mid) < prefix { lo = mid + 1 } else { hi = mid }
    }
    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(1 << 20, stdout.lock());
    let mut buf = itoa_buf();
    for g in lo..ngroups {
        let n = lz.name(g);
        if !n.starts_with(prefix) {
            break;
        }
        for o in lz.occs(g) {
            let lk = o.line_kind.to_native();
            out.write_all(n).unwrap();
            out.write_all(if lk & 1 == 0 { b"\tdef\t" } else { b"\tclass\t" }).unwrap();
            out.write_all(lz.path(o.file.to_native() as usize)).unwrap();
            out.write_all(b"\t").unwrap();
            out.write_all(fmt_u32(&mut buf, lk >> 1)).unwrap();
            out.write_all(b"\n").unwrap();
        }
    }
    out.flush().unwrap();
}

fn map_file(path: &str) -> memmap2::Mmap {
    let file = fs::File::open(path).unwrap_or_else(|e| fail(&format!("cannot read {path}: {e}")));
    // SAFETY: as in `load`.
    unsafe { memmap2::Mmap::map(&file) }.unwrap_or_else(|e| fail(&format!("cannot map {path}: {e}")))
}

fn itoa_buf() -> [u8; 10] {
    [0; 10]
}

fn fmt_u32(buf: &mut [u8; 10], mut v: u32) -> &[u8] {
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            return &buf[i..];
        }
    }
}

fn main() {
    let args: Vec<std::ffi::OsString> = std::env::args_os().collect();
    let s = |i: usize| args[i].to_str().unwrap_or_else(|| fail("non-UTF-8 path"));
    if std::env::var_os("SYMIDX_VALIDATE").is_some_and(|v| v == "stream") {
        match (args.len(), args.get(1).map(|a| a.as_bytes())) {
            (3, Some(b"load")) => {
                let t = Instant::now();
                let map = map_file(s(2));
                let n = load_stream(&map).ix.occs.len();
                println!("symbols={n} load_ms={:.3}", t.elapsed().as_secs_f64() * 1000.0);
                return;
            }
            (4, Some(b"find")) => {
                let map = map_file(s(2));
                find_lazy(&mut load_stream(&map), args[3].as_bytes());
                return;
            }
            _ => {}
        }
    }
    if std::env::var_os("SYMIDX_VALIDATE").is_some_and(|v| v == "lazy") {
        match (args.len(), args.get(1).map(|a| a.as_bytes())) {
            (3, Some(b"load")) => {
                let t = Instant::now();
                let map = map_file(s(2));
                let n = load_lazy(&map).ix.occs.len();
                println!("symbols={n} load_ms={:.3}", t.elapsed().as_secs_f64() * 1000.0);
                return;
            }
            (4, Some(b"find")) => {
                let map = map_file(s(2));
                find_lazy(&mut load_lazy(&map), args[3].as_bytes());
                return;
            }
            _ => {}
        }
    }
    match (args.len(), args.get(1).map(|a| a.as_bytes())) {
        (5, Some(b"build")) if args[3] == "-o" => build(s(2), s(4)),
        (3, Some(b"load")) => {
            let t = Instant::now();
            let (_map, n) = load(s(2));
            println!("symbols={n} load_ms={:.3}", t.elapsed().as_secs_f64() * 1000.0);
        }
        (4, Some(b"find")) => {
            let (map, _) = load(s(2));
            find(archived(&map), args[3].as_bytes());
        }
        _ => fail("usage: symidx build <dir> -o <img> | symidx load <img> | symidx find <img> <prefix>"),
    }
}
