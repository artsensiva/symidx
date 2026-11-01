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

    let parsed: Vec<Parsed> = files
        .par_iter()
        .map(|rel| {
            let src = fs::read(root.join(std::ffi::OsStr::from_bytes(rel))).unwrap_or_default();
            let mut p = Parsed { text: Vec::new(), syms: Vec::new() };
            for (n, line) in src.split(|&c| c == b'\n').enumerate() {
                if let Some((lo, hi, kind)) = parse_line(line) {
                    p.text.extend_from_slice(&line[lo..hi]);
                    p.syms.push((p.text.len() as u32, n as u32 + 1, kind));
                }
            }
            p
        })
        .collect();

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

    let bytes = rkyv::to_bytes::<Error>(&index).unwrap_or_else(|e| fail(&e.to_string()));
    let mut img = Vec::with_capacity(MAGIC.len() + bytes.len());
    img.extend_from_slice(MAGIC);
    img.extend_from_slice(&bytes);
    fs::write(out, img).unwrap_or_else(|e| fail(&format!("cannot write {out}: {e}")));
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
