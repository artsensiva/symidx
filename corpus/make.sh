#!/usr/bin/env bash
# Готовит корпуса corpus/{S,M,L}: только обычные *.py файлы.
#   S = Django, M = CPython + Django (~1.6 млн строк), L = M × 31 (~50 млн строк).
set -euo pipefail
cd "$(dirname "$0")"

CPYTHON_TAG=v3.14.10   # b703b2c5e704341d61e367b9b940b77ed11dded0
DJANGO_TAG=6.1.2       # 2212534bae393714e1e51db2341d4fd5545e19f6
L_COPIES=31

mkdir -p src
[ -d src/cpython ] || git clone -q --depth 1 -b "$CPYTHON_TAG" https://github.com/python/cpython src/cpython
[ -d src/django ]  || git clone -q --depth 1 -b "$DJANGO_TAG"  https://github.com/django/django  src/django

copy_py() {  # copy_py <src> <dst>
  (cd "$1" && find . -type f -name '*.py' -print0) | (cd "$1" && cpio -0pdm --quiet "$2")
}

rm -rf S M L
mkdir -p S M L
copy_py src/django "$PWD/S/django"
copy_py src/cpython "$PWD/M/cpython"
cp -a S/django M/django
for i in $(seq -w 1 "$L_COPIES"); do cp -a M "L/copy$i"; done

for s in S M L; do
  printf '%s: files=%s lines=%s size=%s\n' "$s" \
    "$(find "$s" -type f | wc -l)" "$(find "$s" -type f -print0 | xargs -0 cat | wc -l)" "$(du -sh "$s" | cut -f1)"
done
