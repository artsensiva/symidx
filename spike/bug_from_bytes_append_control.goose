// Control for bug_from_bytes_append.goose: the same program, the global grown with push.
var bytes: u8[>..] = [];
fn main() {
    for c in "abcd" { bytes.push(c); }
    print("len ", bytes.len);
    let i = 2 as (u32 in bytes);
    print("cast ok: ", i, " -> ", bytes[i]);
    var b: (u32 in bytes)[>..] = [];
    b.push(i);
    let img = b.to_bytes();
    var dump: u8[>..] = [];
    for x in img { format(dump, x, " "); }
    print("image: ", dump);
    var rb, bok = from_bytes<(u32 in bytes)[>..]>(img);
    print("from_bytes: ", bok, " len ", rb.len);
}
