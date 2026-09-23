#!/usr/bin/env bash
# Upstream sync: regenerate bindings against the checked-out engine sources,
# run the compatibility checks, and advance upstream.lock only when they pass.
#
#   mobile/Codegen/sync.sh            # check + regenerate + lock
#   mobile/Codegen/sync.sh --check    # verify the working tree, write nothing
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
lock="$root/mobile/upstream.lock"
head=$(git -C "$root" rev-parse HEAD)
locked=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["upstream"])' "$lock")

if [[ "${1:-}" == "--check" ]]; then
  python3 "$root/mobile/Codegen/generate.py" --check
  exit
fi

if [[ "$head" == "$locked" ]]; then
  echo "upstream.lock already at $head"
  exit
fi

echo "upstream: $locked -> $head"
sources=$(python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));print(" ".join(m["sources"]+[m["methods"]]))' "$root/mobile/Codegen/mappings.json")
echo "review handwritten counterparts for:"
git -C "$root" diff --stat "$locked" "$head" -- $sources crates/rpc/src | sed 's/^/  /'

python3 "$root/mobile/Codegen/generate.py"
(cd "$root" && cargo test --locked -p zeron-doc --test mobile_fixtures)
(cd "$root" && cargo test --locked -p zeron-rpc --lib mobile::)
(cd "$root/mobile" && swift build --build-tests && swift test --skip-build --filter 'WireTests|TranscriptTests')

skip_version=$(skip version | awk '{print $NF}')
printf '{\n  "upstream": "%s",\n  "skip": "%s"\n}\n' "$head" "$skip_version" > "$lock"
echo "upstream.lock -> $head"
