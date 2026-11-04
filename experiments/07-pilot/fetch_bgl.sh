#!/usr/bin/env bash
# The change request's held-out corpus (SPEC A6): Loghub BGL from Zenodo record 8196385. usage: fetch_bgl.sh DIR
set -euo pipefail
D=$1; mkdir -p "$D"; cd "$D"
[ -s BGL.zip ] || curl -fsSL --retry 3 -o BGL.zip https://zenodo.org/api/records/8196385/files/BGL.zip/content
echo "d67fd82a711aea0157a9b83175892c6ee60e384a2ddf5bc51f39118453816da8  BGL.zip" | sha256sum -c -
[ -s BGL.log ] || python3 -I -c "import zipfile; zipfile.ZipFile('BGL.zip').extract('BGL.log')"
echo "666130b15ef44eb32fd02bd053e6c6e007c37696b5e7e8b9d8e45b729876a5d2  BGL.log" | sha256sum -c -
