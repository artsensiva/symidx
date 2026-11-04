// F3 (in-place `a, n, ok = from_file(...)`) must not change what a program does. This prints what happened, for
// compare with the same program built by a compiler without F3 (the differential check in check_f3.sh), and it
// also checks the expected values itself. Regression for the review's finding: a from_file nested in the
// arguments of another took its parent's pending reset, giving wrong data reported as success.
//   test_f3_differential <scratch dir>
import std;
import os;

var target: u8[>..] = [];
var other: u8[>..] = [];
var p_new: u8[>..] = [];
var p_two: u8[>..] = [];
var p_bad: u8[>..] = [];
var fails = 0;

fn show(name: u8[:], a: u8[:], n: i64, ok: bool, want_a: u8[:], want_n: i64, want_ok: bool) {
    let good = a == want_a && n == want_n && ok == want_ok;
    print(str(if good { "ok   " } else { "FAIL " }, name, ": [", a, "] ", n, " ", if ok { "true" } else { "false" }));
    if !good { fails++; }
}

// Inlined at -O1 and up: a nested load into another array, then an append to the outer target.
fn nested_append() -> i64 {
    var n = 0;
    var ok = false;
    other, n, ok = from_file<u8[>..]>(p_two, 0);
    target.push('X');
    return 0;
}

// Never inlined: recursive.
recursive fn nested_rec(k: i64) -> i64 {
    if k > 0 { return nested_rec(k - 1); }
    var n = 0;
    var ok = false;
    other, n, ok = from_file<u8[>..]>(p_two, 0);
    target.push('Y');
    return 0;
}

// A nested load into the outer target itself.
fn nested_same() -> i64 {
    var n = 0;
    var ok = false;
    target, n, ok = from_file<u8[>..]>(p_two, 0);
    return 0;
}

// A nested load that is rejected.
fn nested_rejected() -> i64 {
    var n = 0;
    var ok = true;
    other, n, ok = from_file<u8[>..]>(p_bad, 0);
    return 0;
}

// An argument that fails, into a target with old contents: the outer load is what's rejected.
fn nested_then_bad_offset() -> i64 {
    var n = 0;
    var ok = false;
    other, n, ok = from_file<u8[>..]>(p_two, 0);
    return 1000000;
}

fn path_with_effect() -> u8[:] {
    target.push('P');
    return p_new[..];
}

fn through_reference(r: u8[>..]&) -> bool {
    var n = 0;
    var ok = false;
    r, n, ok = from_file<u8[>..]>(p_new, 0);
    return ok && n == 4;
}

fn main() {
    let argv = args();
    guard argv.len == 2 else { print("usage: test_f3_differential <scratch dir>"); exit(2); }
    p_new.append(str(argv[1], "/f3-new.img"));
    p_two.append(str(argv[1], "/f3-two.img"));
    p_bad.append(str(argv[1], "/f3-bad.img"));
    var a: u8[>..] = [];
    to_bytes("NEW", a);
    guard write_file(p_new, a) else { exit(2); }
    a.clear();
    to_bytes("TWO22", a);
    guard write_file(p_two, a) else { exit(2); }
    guard write_file(p_bad, "\x7f") else { exit(2); }

    var n = 0;
    var ok = false;

    target.clear(); target.append("OLD");
    target, n, ok = from_file<u8[>..]>(p_new, nested_append());
    show("nested, inlined, appends to target", target, n, ok, "NEW", 4, true);
    show("  its inner load", other, 0, true, "TWO22", 0, true);

    target.clear(); target.append("OLD");
    target, n, ok = from_file<u8[>..]>(p_new, nested_rec(3));
    show("nested, not inlined, appends to target", target, n, ok, "NEW", 4, true);

    target.clear(); target.append("OLD");
    target, n, ok = from_file<u8[>..]>(p_new, nested_same());
    show("nested load into the same target", target, n, ok, "NEW", 4, true);

    target.clear(); target.append("OLD");
    target, n, ok = from_file<u8[>..]>(p_new, nested_rejected());
    show("nested load rejected, outer fine", target, n, ok, "NEW", 4, true);
    show("  its inner load", other, 0, true, "", 0, true);

    target.clear(); target.append("OLD");
    target, n, ok = from_file<u8[>..]>(p_new, nested_then_bad_offset());
    show("nested fine, outer rejected", target, n, ok, "", -1, false);

    target.clear(); target.append("OLD");
    target, n, ok = from_file<u8[>..]>(path_with_effect(), 0);
    show("path argument appends to target", target, n, ok, "NEW", 4, true);

    target.clear(); target.append("OLD");
    target, n, ok = from_file<u8[>..]>(p_new, target.len - 3);
    show("offset reads target's length", target, n, ok, "NEW", 4, true);

    target.clear();
    target.append(p_new);
    target, n, ok = from_file<u8[>..]>(target, 0);
    show("path is the target", target, n, ok, "NEW", 4, true);

    var i = 0;
    while i < 3 {
        target, n, ok = from_file<u8[>..]>(p_new, 0);
        target.push('!');
        i++;
    }
    show("repeated in a loop, then push", target, n, ok, "NEW!", 4, true);

    var local: u8[>..] = [];
    for k in 100000 { local.push('z'); }
    local, n, ok = from_file<u8[>..]>(p_new, 0);
    show("large local replaced by a small load", local, n, ok, "NEW", 4, true);
    local.push('!');
    show("  then pushed to", local, n, ok, "NEW!", 4, true);

    var viaref: u8[>..] = [];
    viaref.append("OLD");
    let rok = through_reference(viaref);
    show("target through a reference", viaref, 4, rok, "NEW", 4, true);

    if fails > 0 { print(str(fails, " failed")); exit(1); }
    print("all passed");
}
