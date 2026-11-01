// Spike: is the slow first from_bytes page faults? Load groups twice in one
// fresh process; the second load reuses memory the first one faulted in.
import std;
import os;
struct File { lo: u32 upto paths, hi: u32 upto paths }
struct Occ { file: u32 in files, line: varint, kind: u8 }
struct NameGroup { name: u8[varint], occs: Occ[varint] }
var paths: u8[>..] = [];
var files: File[>..] = [];
var groups: NameGroup[>..] = [];
extern fn prefault(at: const u8[:], bytes: i64, huge: bool) -> i32;
extern fn file_size(path: const u8[:]) -> i64;

fn uleb(s: u8[:], i: i64) -> i64, i64 {
    var v = 0; var shift = 0; var j = i;
    loop { let b = s[j]; j++; v = v | ((b & 0x7f) as i64 << shift); if b < 0x80 { break; } shift += 7; }
    return v, j;
}
fn ms_since(t: f64) -> u8[>..] { var o: u8[>..] = []; format_flt(o, (clock() - t) * 1000.0, 3); return o; }

fn main() {
    let argv = args();
    let mode = if argv.len > 2 { argv[2] } else { "none" };
    let pf = mode != "none";
    let huge = mode == "huge";
    let t_all = clock();
    var img: u8[>..] = [];
    let size = file_size(argv[1]);
    if pf { assert(prefault(bytes_of(img), size, huge) == 0); }
    var t = clock();
    guard read_file(argv[1], img) else { abort("read"); }
    print("read_file:                              ", ms_since(t), " ms (mode ", mode, ")");
    var at = 8;
    let n1, b1 = uleb(img, at);
    var p, pok = from_bytes<u8[>..]>(img[at..b1 + n1]);
    for c in p { paths.push(c); }
    at = b1 + n1;
    let n2, b2 = uleb(img, at);
    var f, fok = from_bytes<File[>..]>(img[at..b2 + n2]);
    for x in f { files.push(x); }
    at = b2 + n2;
    let fg = img[at..];
    var ok = false;
    if pf { assert(prefault(bytes_of(groups), fg.len, huge) == 0); }
    t = clock();
    groups, ok = from_bytes<NameGroup[>..]>(fg);
    print("1st from_bytes groups (fresh memory):   ", ms_since(t), " ms ", ok);
    print("TOTAL read..groups incl. prefault:      ", ms_since(t_all), " ms");
    t = clock();
    groups, ok = from_bytes<NameGroup[>..]>(fg);
    print("2nd from_bytes groups (same memory):    ", ms_since(t), " ms ", ok);
    t = clock();
    groups, ok = from_bytes<NameGroup[>..]>(fg);
    print("3rd:                                    ", ms_since(t), " ms ", ok);
}
