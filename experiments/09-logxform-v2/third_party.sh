#!/usr/bin/env bash
# Everything needed to run the evaluation on a machine that isn't the project owner's: a fresh Ubuntu 22.04 or 24.04 x86_64 host,
# such as a c7i.4xlarge. It installs what's missing, checks the pinned versions, and runs the frozen tests. It rents nothing:
# someone has to start the machine and run this on it. usage: third_party.sh LABEL [ROUNDS, default 3]
# LABEL names the hardware, for example c7i.4xlarge. Published results are compared when the label is a published tier.
# Keep this script outside the clone, because it checks out the frozen commit there.
set -euo pipefail
LABEL=${1:?usage: third_party.sh LABEL [ROUNDS]}; ROUNDS=${2:-3}
REPO=${REPO:-https://github.com/artsensiva/symidx}
COMMIT=cdb484f6a187384f3589e0bbcda8c1d6d7d0e528
GO_SHA256=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053
ROOT=${ROOT:-$HOME/lxbench}; mkdir -p "$ROOT"; cd "$ROOT"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  echo "Docker installed. Log in again, so the docker group applies, and rerun this script."; exit 0
fi
sudo apt-get install -y -qq python3 git curl make unzip >/dev/null
if [ ! -x go/bin/go ]; then
  curl -fsSL -o go.tgz https://go.dev/dl/go1.26.5.linux-amd64.tar.gz
  sha256sum go.tgz | grep -q "^$GO_SHA256" || { echo "Go archive doesn't match"; exit 1; }
  tar xzf go.tgz
fi
export PATH=$ROOT/go/bin:$PATH
[ -d symidx ] || git clone -q "$REPO" symidx
[ -d PipeBench ] || git clone -q https://github.com/VirtualMetric/PipeBench
git -C PipeBench checkout -q "$COMMIT"
X=$ROOT/symidx/experiments/09-logxform-v2
if [ -f "$X/FREEZE.md" ]; then
  want=$(sed -n 's/^Commit: *`\([0-9a-f]*\)`.*/\1/p' "$X/FREEZE.md" | head -1)
  [ -n "$want" ] && git -C symidx checkout -q "$want" && echo "at the frozen commit $want"
fi
bash symidx/experiments/02-logxform/corpus/fetch.sh
python3 -I "$X/pipebench/install.py" PipeBench
python3 -I "$X/pipebench/real_cases.py" PipeBench symidx/experiments/02-logxform/corpus/src
(cd PipeBench && make build build-containers)
"$X/pipebench/build_images.sh"
export PIPEBENCH=$ROOT/PipeBench
"$X/pipebench/run_formal.sh" "$LABEL" "$ROUNDS"
python3 -I "$X/pipebench/summarize.py" "$X/results/$LABEL" --published "PipeBench/web/results/$LABEL" | tee "$X/results/$LABEL/summary.md"
echo "Results are in $X/results/$LABEL"
