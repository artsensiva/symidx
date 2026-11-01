#!/usr/bin/env bash
# Prepares corpora corpus/{S,M,L}: regular *.py files only.
#   S = Django, M = CPython + Django (~1.6M lines), L = M × 31 (~50M lines).
#   corpus/make.sh [S M L]   — which corpora to (re)build (default: all; L needs M)
set -euo pipefail
cd "$(dirname "$0")"

CPYTHON_TAG=v3.14.10   # b703b2c5e704341d61e367b9b940b77ed11dded0
DJANGO_TAG=6.1.2       # 2212534bae393714e1e51db2341d4fd5545e19f6
L_COPIES=31

SIZES=("${@:-S M L}"); SIZES=(${SIZES[*]})
want() { case " ${SIZES[*]} " in *" $1 "*) return 0 ;; esac; return 1; }
want L && ! want M && [ ! -d M ] && SIZES+=(M)

mkdir -p src
[ -d src/cpython ] || git clone -q --depth 1 -b "$CPYTHON_TAG" https://github.com/python/cpython src/cpython
[ -d src/django ]  || git clone -q --depth 1 -b "$DJANGO_TAG"  https://github.com/django/django  src/django

copy_py() {  # copy_py <src> <dst>
  (cd "$1" && find . -type f -name '*.py' -print0) | (cd "$1" && cpio -0pdm --quiet "$2")
}

if want S; then rm -rf S && mkdir S && copy_py src/django "$PWD/S/django"; fi
if want M; then rm -rf M && mkdir M && copy_py src/cpython "$PWD/M/cpython" && copy_py src/django "$PWD/M/django"; fi
if want L; then rm -rf L && mkdir L && for i in $(seq -w 1 "$L_COPIES"); do cp -a M "L/copy$i"; done; fi

for s in "${SIZES[@]}"; do
  printf '%s: files=%s lines=%s size=%s\n' "$s" \
    "$(find "$s" -type f | wc -l)" "$(find "$s" -type f -print0 | xargs -0 cat | wc -l)" "$(du -sh "$s" | cut -f1)"
done
