#!/usr/bin/env bash
# Scores the owner's capture kits and the synthetic kit with the release build of bounce-score, keeps the scores
# outside the repository and compares them with the previous run (ios/CaptureKit.md, "Scoring").
#
#   ios/tools/score-kits.sh [bundle parts (.zip) or folders holding them ...] [--kits DIR] [--scores DIR]
#                           [--measured] [--fail-on-regression]
#
# Bundle parts (<kitId>-partNofM.zip) are unzipped together into the kits folder (default ~/bounce-private/kits), so
# all the parts of a kit rebuild it. Every kit in that folder is scored, then the synthetic kit. The scores are saved
# as ~/bounce-private/scores/<UTC date>-<git short hash>.json (--scores for another folder), compared with the newest
# earlier file there, and printed as Markdown. Kits are private: both folders must be outside this repository, and
# nothing here prints their paths. Needs ffmpeg (to decode the kits' video), unzip and a Swift toolchain.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
repo_phys=$(cd "$repo" && pwd -P)
private=${BOUNCE_PRIVATE:-$HOME/bounce-private}
kits="$private/kits"
scores="$private/scores"
extra=()
inputs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --kits) [ $# -ge 2 ] || { echo "--kits needs a folder" >&2; exit 1; }; kits=$2; shift 2 ;;
    --scores) [ $# -ge 2 ] || { echo "--scores needs a folder" >&2; exit 1; }; scores=$2; shift 2 ;;
    --measured|--fail-on-regression) extra+=("$1"); shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 1 ;;
    *) inputs+=("$1"); shift ;;
  esac
done

# A folder for private files: refused inside the repository (before and after following links), created if needed.
private_dir() {
  local p=$1
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  for r in "$repo" "$repo_phys"; do
    case "$p/" in "$r"/*) echo "refusing a private folder inside the repository: $2 must be outside it" >&2; exit 1 ;; esac
  done
  mkdir -p "$p"
  p=$(cd "$p" && pwd -P)
  case "$p/" in "$repo_phys"/*) echo "refusing a private folder inside the repository: $2 must be outside it" >&2; exit 1 ;; esac
  printf '%s\n' "$p"
}
kits=$(private_dir "$kits" "the kits folder")
scores=$(private_dir "$scores" "the scores folder")

# unzip the bundle parts
parts=()
for i in ${inputs[@]+"${inputs[@]}"}; do
  if [ -d "$i" ]; then
    while IFS= read -r f; do parts+=("$f"); done < <(find "$i" -maxdepth 2 -type f -name '*-part*of*.zip' | sort)
  elif [ -f "$i" ]; then
    parts+=("$i")
  else
    echo "not a file or folder: argument ${#parts[@]}" >&2; exit 1
  fi
done
if [ ${#parts[@]} -gt 0 ]; then
  command -v unzip >/dev/null || { echo "unzip is not installed" >&2; exit 1; }
  for p in "${parts[@]}"; do unzip -o -q "$p" -d "$kits"; done
  # each kit's parts: all there?
  for id in $(for p in "${parts[@]}"; do basename "$p" | sed -E 's/-part[0-9]+of[0-9]+\.zip$//'; done | sort -u); do
    want=$(for p in "${parts[@]}"; do basename "$p"; done | grep -E "^${id}-part[0-9]+of[0-9]+\.zip$" | head -1 | sed -E 's/.*of([0-9]+)\.zip$/\1/')
    have=$(for p in "${parts[@]}"; do basename "$p"; done | grep -cE "^${id}-part[0-9]+of[0-9]+\.zip$" || true)
    if [ "$have" -lt "$want" ]; then echo "$id: only $have of its $want parts were given; it may be incomplete" >&2
    else echo "$id: unzipped $have of $have parts" >&2; fi
  done
fi

# the release scorer
pkg="$repo/ios/BounceCore"
swift build -c release --package-path "$pkg" --product bounce-score >&2
bin="$(swift build -c release --package-path "$pkg" --show-bin-path)/bounce-score"

hash=$(git -C "$repo" rev-parse --short HEAD)
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then hash="$hash-dirty"; fi
out="$scores/$(date -u +%Y%m%d-%H%M%S)-$hash.json"
previous=$(find "$scores" -maxdepth 1 -type f -name '*.json' | sort | tail -1)

args=()
if find "$kits" -mindepth 2 -maxdepth 2 -name kit.json | grep -q .; then args+=("$kits"); else echo "no kits in the kits folder: scoring the synthetic kit only" >&2; fi
args+=(--synthetic --markdown --json "$out" --scorer "$hash")
if [ -n "$previous" ]; then args+=(--compare "$previous"); echo "comparing with the scores of $(basename "$previous" .json)" >&2; fi
status=0
"$bin" "${args[@]}" ${extra[@]+"${extra[@]}"} || status=$?
echo "scores saved as $(basename "$out") in the scores folder" >&2
exit $status
