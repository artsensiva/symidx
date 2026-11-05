# The Rust version, same design. Build context: experiments/09-logxform-v2.
FROM rust:1.99.1-slim-trixie AS build
WORKDIR /b
COPY rust/Cargo.toml rust/Cargo.lock ./
COPY rust/src ./src
RUN cargo build --release --locked && cp target/release/logxform /logxform

FROM debian:trixie-slim
COPY --from=build /logxform /usr/local/bin/logxform
RUN mkdir -p /var/lib/logxform
ENTRYPOINT ["/usr/local/bin/logxform"]
