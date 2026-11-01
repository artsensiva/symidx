// Spike: the grouped verified layout from CLAUDE.md, saved with to_bytes and
// reloaded with from_bytes, then tampered with.

import std;
import os;

struct File { lo: u32 upto paths, hi: u32 upto paths }
struct Occ { file: u32 in files, line: varint, kind: u8 }
struct NameGroup { name: u8[varint], occs: Occ[varint] }

var paths: u8[>..] = [];
var files: File[>..] = [];
var groups: NameGroup[>..] = [];

fn add_file(p: u8[:]) -> u32 in files {
    let lo = paths.len as (u32 upto paths);
    paths.append(p);
    let hi = paths.len as (u32 upto paths);
    files.push(File { lo: lo, hi: hi });
    return (files.len - 1) as (u32 in files);
}

// Reads one LEB128 varint at s[i..]; returns the value and the index after it.
fn uleb(s: u8[:], i: i64) -> i64, i64 {
    var v = 0;
    var shift = 0;
    var j = i;
    loop {
        let b = s[j];
        j++;
        v = v | ((b & 0x7f) as i64 << shift);
        if b < 0x80 { break; }
        shift += 7;
    }
    return v, j;
}

// The image is three to_bytes frames back to back: paths, files, groups.
fn save() -> u8[>..] {
    var img: u8[>..] = [];
    to_bytes(paths, img);
    to_bytes(files, img);
    to_bytes(groups, img);
    return img;
}

// Loads into the (empty) globals; false on any rejected frame.
fn load(img: u8[:]) -> bool {
    var at = 0;
    var frame = 0;
    var ok = true;
    while ok && frame < 3 {
        guard at < img.len else { return false; }
        let n, body = uleb(img, at);
        guard body + n <= img.len else { return false; }
        let s = img[at..body + n];
        if frame == 0 {
            var p, pok = from_bytes<u8[>..]>(s);
            ok = pok;
            paths.append(p);
        } else if frame == 1 {
            var f, fok = from_bytes<File[>..]>(s);
            ok = fok;
            files.append(f);
        } else {
            var g, gok = from_bytes<NameGroup[>..]>(s);
            ok = gok;
            groups.append(g);
        }
        at = body + n;
        frame++;
    }
    return ok && at == img.len;
}

fn reset() {
    // Shrinking `paths`/`files` is forbidden (index types pin them), so a
    // reload into the same process cannot clear them; see FINDINGS.
}

fn dump() {
    for g in groups {
        for o in g.occs {
            let f = files[o.file];
            print(g.name, "\t", if o.kind == 0 { "def" } else { "class" }, "\t",
                  paths[f.lo..f.hi], "\t", o.line);
        }
    }
}

fn main() {
    let a = add_file("pkg/a.py");
    let b = add_file("pkg/b.py");
    var occs: Occ[>..] = [];
    occs.push(Occ { file: a, line: 3, kind: 0 });
    occs.push(Occ { file: b, line: 300, kind: 1 });
    groups.push(NameGroup { name: "Model", occs: copy(occs) });
    var occs2: Occ[>..] = [];
    occs2.push(Occ { file: b, line: 1, kind: 0 });
    groups.push(NameGroup { name: "get_x", occs: copy(occs2) });

    let img = save();
    print("image ", img.len, " bytes: paths ", bytes_of(paths).len, ", files ", bytes_of(files).len,
          ", groups ", bytes_of(groups).len);
    var bytes: u8[>..] = [];
    for x in img { format(bytes, x, " "); }
    print(bytes);
    dump();
    guard write_file("spike.img", img) else { abort("write"); }
}
