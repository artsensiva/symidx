#!/usr/bin/env bash
# Builds both subject images from this directory's source.
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t logxform-goose:dev -f docker/goose.Dockerfile .
docker build -q -t logxform-rust:dev -f docker/rust.Dockerfile .
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep logxform
