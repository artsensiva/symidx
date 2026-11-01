// Repro (goose v2026.3, runtime 4d3da949e563): an index type into a global that
// was grown with `append` makes from_bytes reject a valid image. Prints `false`;
// bug_from_bytes_append_control.goose fills the array with push and prints `true`.
var bytes: u8[>..] = [];
fn main() {
    bytes.append("abcd");
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
