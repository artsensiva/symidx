# logXform of Goose, built from source against the pinned, unpatched Goose release. Build context: experiments/09-logxform-v2.
FROM debian:trixie-slim AS build
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends clang libc6-dev curl ca-certificates >/dev/null
WORKDIR /b
RUN curl -fsSL -o g.tgz https://github.com/aardappel/goose/releases/download/v2026.3/goose-v2026.3-linux-x64.tar.gz \
 && echo "06ac30284338269d3996d457412bf4f2b47c1f9a5601de65b6317187fe78d5c9  g.tgz" | sha256sum -c - && tar xzf g.tgz
COPY goose/ /b/src/
RUN cd /b/src && rm -f logxform && /b/goose-v2026.3-linux-x64/goose build logxform.goose --cc clang --stack-reserve 1G -o /logxform

FROM debian:trixie-slim
COPY --from=build /logxform /usr/local/bin/logxform
RUN mkdir -p /var/lib/logxform
ENTRYPOINT ["/usr/local/bin/logxform"]
