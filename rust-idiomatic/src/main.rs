//! symidx, the idiomatic Rust version: the grouped layout as owned `String`s and `Vec`s,
//! saved with serde + bincode. See CLAUDE.md and bench/SPEC.md.

use bincode::Options;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_bytes::ByteBuf;
use std::fs;
use std::io::{self, BufWriter, Write};
use std::path::Path;
use std::process::exit;
use std::time::Instant;

const MAGIC: &[u8; 8] = b"SYMIDX1\n";

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Def,
    Class,
}

#[derive(Serialize, Deserialize)]
struct Occ {
    file: u32,
    line: u32,
    kind: Kind,
}

#[derive(Serialize, Deserialize)]
struct Group {
    #[serde(with = "serde_bytes")]
    name: Vec<u8>, // names are bytes: SPEC allows any byte >= 0x80
    occs: Vec<Occ>,
}

#[derive(Serialize, Deserialize)]
struct Index {
    files: Vec<ByteBuf>, // relative paths, in path order
    groups: Vec<Group>,  // one per unique name, in name order
}

fn fail(msg: &str) -> ! {
    eprintln!("symidx: {msg}");
    exit(1);
}

/// bench/SPEC.md "Line parsing": the name and kind, if the line declares a symbol.
fn parse_line(s: &[u8]) -> Option<(&[u8], Kind)> {
    let ws = |c: u8| c == b' ' || c == b'\t';
    let ident = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c >= 0x80;
    let mut i = s.iter().position(|&c| !ws(c)).unwrap_or(s.len());
    if s[i..].starts_with(b"async") && s.get(i + 5).is_some_and(|&c| ws(c)) {
        i += 5;
        while i < s.len() && ws(s[i]) {
            i += 1;
        }
    }
    let (kind, mut j) = if s[i..].starts_with(b"def") {
        (Kind::Def, i + 3)
    } else if s[i..].starts_with(b"class") {
        (Kind::Class, i + 5)
    } else {
        return None;
    };
    if !s.get(j).is_some_and(|&c| ws(c)) {
        return None;
    }
    while j < s.len() && ws(s[j]) {
        j += 1;
    }
    let k = j + s[j..].iter().take_while(|&&c| ident(c)).count();
    (k > j).then(|| (&s[j..k], kind))
}

/// Every regular *.py file under `dir`, relative, '/'-separated; symlinks are not followed.
fn walk(root: &Path, rel: &mut Vec<u8>, out: &mut Vec<Vec<u8>>) {
    let dir = if rel.is_empty() { root.to_path_buf() } else { root.join(bytes_to_path(rel)) };
    let entries = fs::read_dir(&dir).unwrap_or_else(|e| fail(&format!("cannot list {}: {e}", dir.display())));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| fail(&e.to_string()));
        let ty = entry.file_type().unwrap_or_else(|e| fail(&e.to_string()));
        let name = entry.file_name();
        let name = name.as_encoded_bytes();
        let len = rel.len();
        if !rel.is_empty() {
            rel.push(b'/');
        }
        rel.extend_from_slice(name);
        if ty.is_dir() {
            walk(root, rel, out);
        } else if ty.is_file() && name.ends_with(b".py") {
            out.push(rel.clone());
        }
        rel.truncate(len);
    }
}

fn bytes_to_path(b: &[u8]) -> &Path {
    use std::os::unix::ffi::OsStrExt;
    Path::new(std::ffi::OsStr::from_bytes(b))
}

fn build(root: &str, out: &str) {
    let root = Path::new(root);
    let mut files = Vec::new();
    walk(root, &mut Vec::new(), &mut files);
    files.sort();

    // (name, file, line, kind) per symbol, parsed in parallel.
    let mut syms: Vec<(Vec<u8>, u32, u32, Kind)> = files
        .par_iter()
        .enumerate()
        .flat_map_iter(|(fi, rel)| {
            let text = fs::read(root.join(bytes_to_path(rel))).unwrap_or_default();
            let mut found = Vec::new();
            for (n, line) in text.split(|&c| c == b'\n').enumerate() {
                if let Some((name, kind)) = parse_line(line) {
                    found.push((name.to_vec(), fi as u32, n as u32 + 1, kind));
                }
            }
            found
        })
        .collect();
    let count = syms.len();
    syms.par_sort_unstable_by(|a, b| (&a.0, a.1, a.2).cmp(&(&b.0, b.1, b.2)));

    // Sorted by name, so each name's symbols are one run: one group per run.
    let mut groups: Vec<Group> = Vec::new();
    for (name, file, line, kind) in syms {
        let occ = Occ { file, line, kind };
        match groups.last_mut() {
            Some(g) if g.name == name => g.occs.push(occ),
            _ => groups.push(Group { name, occs: vec![occ] }),
        }
    }

    let index = Index { files: files.into_iter().map(ByteBuf::from).collect(), groups };
    let mut bytes = MAGIC.to_vec();
    bincode::serialize_into(&mut bytes, &index).unwrap_or_else(|e| fail(&e.to_string()));
    fs::write(out, bytes).unwrap_or_else(|e| fail(&format!("cannot write {out}: {e}")));
    println!("symbols={count} files={}", index.files.len());
}

/// Deserializes and verifies the whole image (bench/SPEC.md "Image validation"): bincode checks
/// structure; the pass below checks every cross-reference before any query.
fn load(path: &str) -> (Index, usize) {
    let bytes = fs::read(path).unwrap_or_else(|e| fail(&format!("cannot read {path}: {e}")));
    let body = bytes.strip_prefix(MAGIC).unwrap_or_else(|| fail("not a symidx image"));
    let index: Index = bincode::options()
        .with_fixint_encoding()
        .reject_trailing_bytes()
        .deserialize(body)
        .unwrap_or_else(|e| fail(&format!("invalid image: {e}")));
    let nfiles = index.files.len() as u32;
    let mut count = 0;
    for g in &index.groups {
        if g.name.is_empty() || g.occs.is_empty() {
            fail("invalid image: empty group");
        }
        for o in &g.occs {
            if o.file >= nfiles || o.line == 0 {
                fail("invalid image: occurrence");
            }
        }
        count += g.occs.len();
    }
    (index, count)
}

fn find(index: &Index, prefix: &[u8]) {
    let start = index.groups.partition_point(|g| g.name.as_slice() < prefix);
    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(1 << 20, stdout.lock());
    for g in index.groups[start..].iter().take_while(|g| g.name.starts_with(prefix)) {
        for o in &g.occs {
            let kind: &[u8] = if o.kind == Kind::Def { b"def" } else { b"class" };
            out.write_all(&g.name).unwrap();
            out.write_all(b"\t").unwrap();
            out.write_all(kind).unwrap();
            out.write_all(b"\t").unwrap();
            out.write_all(&index.files[o.file as usize]).unwrap();
            writeln!(out, "\t{}", o.line).unwrap();
        }
    }
    out.flush().unwrap();
}

fn main() {
    use std::os::unix::ffi::OsStrExt;
    let args: Vec<std::ffi::OsString> = std::env::args_os().collect();
    let arg = |i: usize| args[i].as_bytes();
    let usage = || fail("usage: symidx build <dir> -o <img> | symidx load <img> | symidx find <img> <prefix>");
    let s = |i: usize| args[i].to_str().unwrap_or_else(|| fail("non-UTF-8 path"));
    match (args.len(), args.get(1).map(|a| a.as_bytes())) {
        (5, Some(b"build")) if arg(3) == b"-o" => build(s(2), s(4)),
        (3, Some(b"load")) => {
            let t = Instant::now();
            let (_index, n) = load(s(2));
            println!("symbols={n} load_ms={:.3}", t.elapsed().as_secs_f64() * 1000.0);
        }
        (4, Some(b"find")) => {
            let (index, _) = load(s(2));
            find(&index, arg(3));
        }
        _ => usage(),
    }
}
