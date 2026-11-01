// Spike: from_bytes throughput of alternative group layouts on a real image.
//   goose build load_layouts.goose --cc clang && ./load_layouts ../path/M.img
import std;
import os;

let MAGIC = "SYMIDX1\n";

struct File { lo: u32 upto paths, hi: u32 upto paths }
struct Occ { file: u32 in files, line: varint, kind: u8 }        // kind: 0 = def, 1 = class
struct NameGroup { name: u8[varint], occs: Occ[varint] }

// `paths` and `files` are pinned by index types, so they only ever grow, and
// only by push: from_bytes rejects an index into an array grown with append
// (spike/FINDINGS.md).
var paths: u8[>..] = [];
var files: File[>..] = [];
var groups: NameGroup[>..] = [];
var group_at: (NameGroup&<u32 in groups>)[>..] = [];      // in memory only, for binary search


fn fail(msg: u8[:]) { write_stderr(str(msg, "\n")); exit(1); }

// B: fixed-size occurrences inside each group.
struct OccB { file: u32 in files, line: u32, kind: u8 }
struct GroupB { name: u8[varint], occs: OccB[varint] }
// C: groups hold a span into one fixed-size occurrence array.
struct OccC { file: u32 in files, line: u32, kind: u8 }
var occs_c: OccC[>..] = [];
struct GroupC { name: u8[varint], lo: u32 upto occs_c, hi: u32 upto occs_c }
// D: as C, with kind packed into the line: 8 bytes an occurrence.
struct OccD { file: u32 in files, lk: u32 }
var occs_d: OccD[>..] = [];
struct GroupD { name: u8[varint], lo: u32 upto occs_d, hi: u32 upto occs_d }
// A': the current layout without the index type on file.
struct OccA2 { file: u32, line: varint, kind: u8 }
struct GroupA2 { name: u8[varint], occs: OccA2[varint] }

// One LEB128 varint at s[i..]: the value and the index after it, or -1 if it runs off the end.
fn uleb(s: u8[:], i: i64) -> i64, i64 {
    var v = 0;
    var shift = 0;
    var j = i;
    loop {
        guard j < s.len && shift < 63 else { return 0, -1; }
        let b = s[j];
        j++;
        v = v | ((b & 0x7f) as i64 << shift);
        if b < 0x80 { break; }
        shift += 7;
    }
    return v, j;
}

// The frame starting at img[at..]: its bytes (prefix included) and where the next one starts.
fn frame(img: u8[:], at: i64) -> u8[:], i64 {
    let n, body = uleb(img, at);
    guard body >= 0 && n <= img.len - body else { fail("image is truncated"); }
    return img[at..body + n], body + n;
}


var first_ms = 0.0;

fn best_ms<F>() -> f64 {
    var best = 1.0e9;
    for r in 15 {
        let t = clock();
        F();
        let ms = (clock() - t) * 1000.0;
        if r == 0 { first_ms = ms; }
        best = min(best, ms);
    }
    return best;
}

fn report(label: u8[:], bytes: i64, ms: f64) {
    var line: u8[>..] = [];
    format(line, label, ": ", bytes, " bytes, ");
    format_flt(line, ms, 3);
    line.append(" ms, ");
    format_flt(line, bytes / 1000.0 / ms, 0);
    line.append(" MB/s; first call ");
    format_flt(line, first_ms, 3);
    line.append(" ms");
    print(line);
}

fn main() {
    let argv = args();
    var img: u8[>..] = [];
    guard read_file(argv[1], img) else { fail("read"); }
    var at = MAGIC.len;
    let fp, a1 = frame(img, at);
    var p, pok = from_bytes<u8[>..]>(fp);
    for c in p { paths.push(c); }
    let ff, a2 = frame(img, a1);
    var f, fok = from_bytes<File[>..]>(ff);
    for x in f { files.push(x); }
    let fg, a3 = frame(img, a2);
    var gok = false;
    if argv.len > 2 {
        // Spin first, so the core is at full clock before the timed call.
        let until = clock() + 0.1;
        var spins: u64 = 0;
        while clock() < until { spins += 1; }
        print("spun ", spins);
    }
    let t0 = clock();
    groups, gok = from_bytes<NameGroup[>..]>(fg);
    var l0: u8[>..] = [];
    format(l0, "first from_bytes of groups in this process: ");
    format_flt(l0, (clock() - t0) * 1000.0, 3);
    print(l0, " ms");
    assert(pok && fok && gok);

    var gb: GroupB[>..] = [];
    var gc: GroupC[>..] = [];
    var gd: GroupD[>..] = [];
    var ga2: GroupA2[>..] = [];
    for g in groups {
        var ob: OccB[>..] = [];
        var oa: OccA2[>..] = [];
        let lo_c = occs_c.len as (u32 upto occs_c);
        let lo_d = occs_d.len as (u32 upto occs_d);
        for o in g.occs {
            ob.push(OccB { file: o.file, line: o.line as! u32, kind: o.kind });
            oa.push(OccA2 { file: o.file, line: o.line, kind: o.kind });
            occs_c.push(OccC { file: o.file, line: o.line as! u32, kind: o.kind });
            occs_d.push(OccD { file: o.file, lk: ((o.line as! u32) << 1) | o.kind });
        }
        gb.push(GroupB { name: g.name[..], occs: copy(ob) });
        ga2.push(GroupA2 { name: g.name[..], occs: copy(oa) });
        gc.push(GroupC { name: g.name[..], lo: lo_c, hi: occs_c.len as (u32 upto occs_c) });
        gd.push(GroupD { name: g.name[..], lo: lo_d, hi: occs_d.len as (u32 upto occs_d) });
    }

    let ia = to_bytes(groups);
    report("A  current (varint line, nested occs)", ia.len, best_ms() { var x, ok = from_bytes<NameGroup[>..]>(ia); assert(ok); });
    let ia2 = to_bytes(ga2);
    report("A' current, file not an index type   ", ia2.len, best_ms() { var x, ok = from_bytes<GroupA2[>..]>(ia2); assert(ok); });
    let ib = to_bytes(gb);
    report("B  fixed occs nested (9 B)           ", ib.len, best_ms() { var x, ok = from_bytes<GroupB[>..]>(ib); assert(ok); });
    let icg = to_bytes(gc);
    let ico = to_bytes(occs_c);
    report("C  groups+span, occs array (9 B)     ", icg.len + ico.len, best_ms() {
        var o, ok1 = from_bytes<OccC[>..]>(ico); var g, ok2 = from_bytes<GroupC[>..]>(icg); assert(ok1 && ok2); });
    report("   C groups frame alone              ", icg.len, best_ms() { var g, ok = from_bytes<GroupC[>..]>(icg); assert(ok); });
    report("   C occs frame alone                ", ico.len, best_ms() { var o, ok = from_bytes<OccC[>..]>(ico); assert(ok); });
    let idg = to_bytes(gd);
    let ido = to_bytes(occs_d);
    report("D  groups+span, packed occs (8 B)    ", idg.len + ido.len, best_ms() {
        var o, ok1 = from_bytes<OccD[>..]>(ido); var g, ok2 = from_bytes<GroupD[>..]>(idg); assert(ok1 && ok2); });
    var raw: u8[>..] = [];
    raw.append(ia);
    report("memcpy baseline (u8 array of A)      ", raw.len, best_ms() { var x = copy(raw); });
}
