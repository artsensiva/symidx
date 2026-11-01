// Spike: load spike.img (written by ser.goose) after one named mutation,
// and report whether from_bytes accepts it. One process per case, since the
// pinned globals cannot be cleared between loads.

import std;
import os;

struct File { lo: u32 upto paths, hi: u32 upto paths }
struct Occ { file: u32 in files, line: varint, kind: u8 }
struct NameGroup { name: u8[varint], occs: Occ[varint] }

var paths: u8[>..] = [];
var files: File[>..] = [];
var groups: NameGroup[>..] = [];
var group_at: (NameGroup&<u32 in groups>)[>..] = [];

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
            for x in p { paths.push(x); }
        } else if frame == 1 {
            var f, fok = from_bytes<File[>..]>(s);
            ok = fok;
            for x in f { files.push(x); }
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
    let argv = args();
    let mode = argv[1];
    var img: u8[>..] = [];
    guard read_file("spike.img", img) else { abort("read"); }
    // Offsets into the 68-byte image printed by ser.goose: paths frame 0..16,
    // files frame 17..33, groups frame 34.. (35 name length, 41 occurrence
    // count, 42..45 first occ's file, 46 its line, 47 its kind).
    if mode == "trunc" { img.pop(); }
    else if mode == "namelen" { img[35] = 100; }     // first group's name length
    else if mode == "occcount" { img[41] = 7; }      // first group's occurrence count
    else if mode == "fileidx" { img[42] = 2; }       // first occ's file index = files.len (2)
    else if mode == "span" { img[30] = 17; }         // file 1's hi past paths.len (16)
    else if mode == "lohi" { img[18] = 9; }          // file 0's lo above its hi (8)
    else if mode == "kind" { img[47] = 7; }          // first occ's kind
    else if mode == "negline" { img[46] = 5; }       // first occ's line, zigzag -3
    else { guard mode == "ok" else { abort("mode"); } }
    let ok = load(img);
    print(mode, ": from_bytes accepts=", ok, " groups=", groups.len, " files=", files.len);
    if ok { dump(); }
    if ok && mode == "ok" {
        for g in groups { group_at.push(g); }
        for i in [1, 0] { print("group_at[", i, "] = ", group_at[i].name, " (", group_at[i].occs.len, " occs)"); }
    }
}
