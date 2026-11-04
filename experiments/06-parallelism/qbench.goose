// The cost of one queue message, alone: a worker echoes messages of a given size back to main.
//   qbench <bytes> <round trips>
// put = constructing and sending; get = waiting for and receiving. No other work happens.
import std;
import os;

struct Msg { seq: i64, data: u8[] }
struct Back { seq: i64, data: u8[] }

thread_fn echo() {
    loop {
        let m = qget<Msg>();
        guard m.seq >= 0 else { break; }
        qput(Back { seq: m.seq, data: m.data[..] });
    }
}

fn main() {
    let argv = args();
    guard argv.len == 3 else { print("usage: qbench <bytes> <round trips>"); exit(2); }
    let size, a = parse_int(argv[1]);
    let trips, b = parse_int(argv[2]);
    guard a && b else { exit(2); }
    var payload: u8[>..] = [];
    for i in size { payload.push('x'); }
    let id = thread_spawn(echo);
    var put = 0;
    var get = 0;
    let t0 = clock_ns();
    for i in trips {
        let p0 = clock_ns();
        qput(Msg { seq: i, data: payload[..] });
        let p1 = clock_ns();
        let r = qget<Back>();
        let p2 = clock_ns();
        put += p1 - p0;
        get += p2 - p1;
        guard r.data.len == size else { print("wrong size"); exit(1); }
    }
    let t1 = clock_ns();
    qput(Msg { seq: -1, data: "" });
    thread_wait(id);
    print(str("bytes=", size, " trips=", trips, " us_per_trip=", (t1 - t0) / 1000 / trips, " put_us=", put / 1000 / trips, " get_us=", get / 1000 / trips));
}
