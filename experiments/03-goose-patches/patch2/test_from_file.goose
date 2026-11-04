// Tests for patch 2's from_file and read_file_range (experiment 3). Needs the patched compiler.
//   goose build test_from_file.goose --cc clang -o test_from_file && ./test_from_file <scratch dir>

import std;
import os;

struct Item { k: u32 in keys, name: u8[varint] }

var keys: u8[>..] = [];
var items: Item[>..] = [];
var loaded: Item[>..] = [];
var fails = 0;

fn check(name: u8[:], cond: bool) {
    if cond { print(str("ok   ", name)); } else { print(str("FAIL ", name)); fails++; }
}

fn same(a: Item[>..]&, b: Item[>..]&) -> bool {
    return bytes_of(a) == bytes_of(b);
}

fn main() {
    let argv = args();
    guard argv.len == 2 else { print("usage: test_from_file <scratch dir>"); exit(2); }
    let p = str(argv[1], "/t.img");
    for c in "abcd" { keys.push(c); }
    items.push(Item { k: 0 as u32 in keys, name: "zero" });
    items.push(Item { k: 3 as u32 in keys, name: "three" });
    items.push(Item { k: 1 as u32 in keys, name: "" });

    var img: u8[>..] = [];
    img.append("HDR!");
    to_bytes(keys, img);
    let at_items = img.len;
    to_bytes(items, img);
    check("write image", write_file(p, img));

    // read_file_range
    var h: u8[>..] = [];
    check("range: header", read_file_range(p, 0, 4, h) && h == "HDR!");
    h.clear();
    check("range: clipped at end", read_file_range(p, img.len - 2, 10, h) && h.len == 2);
    h.clear();
    check("range: at end is empty", read_file_range(p, img.len, 5, h) && h.len == 0);
    check("range: past end is empty", read_file_range(p, img.len + 7, 5, h) && h.len == 0);
    check("range: negative offset fails", !read_file_range(p, -1, 5, h));
    check("range: missing file fails", !read_file_range(str(argv[1], "/missing"), 0, 5, h));

    // from_file against from_bytes over the same bytes
    var k2, n1, ok1 = from_file<u8[>..]>(p, 4);
    check("u8 frame loads", ok1 && k2 == keys && n1 == at_items);
    var n2 = 0;
    var ok2 = false;
    loaded, n2, ok2 = from_file<Item[>..]>(p, n1);
    check("var-size frame loads into a global", ok2 && n2 == img.len && same(loaded, items));
    var whole: u8[>..] = [];
    guard read_file(p, whole) else { print("cannot read"); exit(2); }
    var viab, okb = from_bytes<Item[>..]>(whole[at_items..whole.len]);
    var vf, n3, okf = from_file<Item[>..]>(p, at_items);
    check("local result equals from_bytes", okb && okf && n3 == n2 && same(vf, viab));
    var count = 0;
    for it in vf { count++; }
    check("element count", count == 3);

    // rejections: each leaves an empty result and next = -1
    var r1, m1, e1 = from_file<Item[>..]>(p, 1);          // inside the header: not a frame
    check("bad prefix rejected", !e1 && m1 == -1 && r1.len == 0);
    var r2, m2, e2 = from_file<Item[>..]>(p, img.len);    // at the end
    check("offset at end rejected", !e2 && m2 == -1 && r2.len == 0);
    var r3, m3, e3 = from_file<Item[>..]>(p, -5);
    check("negative offset rejected", !e3 && m3 == -1 && r3.len == 0);
    var r4, m4, e4 = from_file<Item[>..]>(str(argv[1], "/missing"), 0);
    check("missing file rejected", !e4 && m4 == -1 && r4.len == 0);

    let pt = str(argv[1], "/trunc.img");
    check("write truncated", write_file(pt, img[0..img.len - 1]));
    var r5, m5, e5 = from_file<Item[>..]>(pt, at_items);  // prefix claims a byte the file lacks
    check("truncated frame rejected", !e5 && m5 == -1 && r5.len == 0);

    // an index out of range: the first item's k (u32, right after the 1-byte prefix) set to 200
    var bad: u8[>..] = [];
    bad.append(img);
    bad[at_items + 1] = 200;
    let pb = str(argv[1], "/bad.img");
    check("write bad index", write_file(pb, bad));
    var r6, m6, e6 = from_file<Item[>..]>(pb, at_items);
    var r6b, e6b = from_bytes<Item[>..]>(bad[at_items..bad.len]);
    check("bad index rejected, as from_bytes does", !e6 && !e6b && m6 == -1 && r6.len == 0);

    // a bad name length: the varint after k claims more bytes than the frame has
    var bad2: u8[>..] = [];
    bad2.append(img);
    bad2[at_items + 5] = 100;
    let pb2 = str(argv[1], "/bad2.img");
    check("write bad length", write_file(pb2, bad2));
    var r7, m7, e7 = from_file<Item[>..]>(pb2, at_items);
    check("bad inner length rejected", !e7 && m7 == -1 && r7.len == 0);

    // a rejected load into a global that held data leaves it empty
    var m8 = 0;
    var e8 = true;
    loaded, m8, e8 = from_file<Item[>..]>(pb, at_items);
    check("rejected load empties the global", !e8 && loaded.len == 0);

    // Assigning onto an existing array (read straight into it): arguments that name it see its old contents.
    let pa = str(argv[1], "/alias.img");
    var pb3: u8[>..] = [];
    to_bytes("abcdefgh", pb3);
    check("write alias image", write_file(pa, pb3));
    var named: u8[>..] = [];
    named.append(pa);
    var m9 = 0;
    var e9 = false;
    named, m9, e9 = from_file<u8[>..]>(named, 0);       // the path is the array being replaced
    check("path naming the target", e9 && named == "abcdefgh" && m9 == pb3.len);
    var again = 0;
    var eb = false;
    var padded: u8[>..] = [];
    padded.append("xxxx");
    padded.append(pb3);
    check("write padded image", write_file(pa, padded));
    named.clear();
    named.append("wxyz");
    named, again, eb = from_file<u8[>..]>(pa, named.len); // the offset reads the target's old length (4)
    check("offset reading the target's length", eb && named == "abcdefgh");
    named, again, eb = from_file<u8[>..]>(pa, 1);         // rejected: the target ends up empty
    check("rejected assignment empties a local", !eb && named.len == 0 && again == -1);
    var grown: u8[>..] = [];
    for i in 100000 { grown.push('z'); }
    grown, again, eb = from_file<u8[>..]>(pa, 4);         // smaller than what it replaces
    check("shrinking assignment", eb && grown == "abcdefgh");
    grown.push('!');
    check("push after in-place load", grown == "abcdefgh!");

    if fails > 0 { print(str(fails, " failed")); exit(1); }
    print("all passed");
}
