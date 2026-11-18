#!/usr/bin/env bash
# Regions grown per slab search: the bench built against a scratch copy of BounceCore whose SlabFinder logs each sweep
# (BounceCore keeps the count internal, so the normal build cannot report it). Nothing in the repository changes: the
# copy is made in a temporary folder (symlinks to BounceCore's sources, one patched file) and removed afterwards.
#
#     ios/BounceBench/sweep-stats.sh [bench options]     e.g. --cache DIR
#
# Prints the bench's slab-search stages with a "regions grown" column (and the fixtures'), of at most maxSweepRegions.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
core="$here/../BounceCore/Sources/BounceCore"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Sources/BounceCore"
for f in "$core"/*.swift; do
  [ "$(basename "$f")" = SlabFinder.swift ] || ln -s "$f" "$tmp/Sources/BounceCore/"
done
ln -s "$here/Sources/bounce-bench" "$tmp/Sources/bounce-bench"
python3 - "$core/SlabFinder.swift" "$tmp/Sources/BounceCore/SlabFinder.swift" <<'EOF'
import sys
s = open(sys.argv[1]).read()
end = "        return found.sorted { $0.area > $1.area }.map(canonical)\n"
if s.count(end) != 1:
    sys.exit("sweep-stats: SlabFinder's sweep has changed; update the patch in this script")
s = s.replace(end, "        benchSweepLog.append((grown, regionsTried, regionsKept, refined))\n" + end)
s = s.replace("import Foundation\n", "import Foundation\n\npublic var benchSweepLog: [(grown: Int, tried: Int, kept: Int, refined: Int)] = []\n", 1)
open(sys.argv[2], "w").write(s)
EOF
cat > "$tmp/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "BenchSweepStats",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BounceCore", swiftSettings: [.define("BENCH_SWEEP_STATS")]),
        .executableTarget(name: "bounce-bench", dependencies: ["BounceCore"], swiftSettings: [.define("BENCH_SWEEP_STATS")]),
    ]
)
EOF
swift build -c release --package-path "$tmp" >&2
cd "$here/.."
"$tmp/.build/release/bounce-bench" --only "search, cold" --iterations 3 "$@"
