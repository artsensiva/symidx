// json::plain, after experiment 5's rewrite: every byte value, in every position of strings of every length up to 80,
// against the definition. The lengths cover a vectorized loop's main body and its scalar tail.
import std;
import json;

fn main() {
    var checked = 0;
    var s: u8[>..] = [];
    for n in 81 {
        s.clear();
        for i in n { s.push('a'); }
        check_plain(s, true);
        checked++;
        for p in n {
            for b in 256 {
                s[p] = b as! u8;
                let c = b as! u8;
                let want = !(c < 0x20 || c == '"' || c == '\\');
                check_plain(s, want);
                checked++;
            }
            s[p] = 'a';
        }
    }
    print(str("all passed: ", checked, " strings"));
}

fn check_plain(s: u8[:], want: bool) {
    guard json::plain(s) == want else {
        print(str("FAIL: length ", s.len, " want ", if want { "plain" } else { "not plain" }));
        exit(1);
    }
}
