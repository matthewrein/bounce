#!/usr/bin/env bash
# Dry run of the hand-off (ios/CaptureKit.md, "When the kit is uploaded"), end to end from nothing, in a private
# folder outside the repository:
#
#   ios/tools/handoff-dryrun.sh [--dir DIR] [--short] [--keep]
#   ios/tools/handoff-dryrun.sh --app-bundle DIR [--dir DIR] [--keep]
#
#   1. the phone: a synthetic kit the size of a real one, written as the app writes it (bounce-kit write-synthetic:
#      KitStore, HEVC at the phone's size and bitrate, LiDAR depth, every shot kind, a retry, skipped shots), and its
#      bundle as the app makes it (KitBundle, 24,000,000-byte parts); every part must be under the limit and under
#      GitHub's 25 MiB upload limit, and unzipping all the parts must rebuild the kit byte for byte;
#   2. the upload: a local bare repository stands in for the private bounce-captures (a README first, as the owner
#      creates it); parts are committed at its root as GitHub's web upload does ("Add files via upload");
#   3. the one command (kit-uploaded.sh) after each upload, with what it must say:
#        a. only the first part uploaded: the kit is incomplete, the missing parts named, no "can delete", not scored;
#        b. the other parts in a second commit: complete, scored (median tilt error at most 2°), "can delete" (before
#           the scores and again after them);
#        c. a second kit (H.264, no LiDAR) uploaded later: both complete, the new one scored, the old one still fine;
#        d. the same parts uploaded again (one renamed "... (1).zip" in a folder, one re-committed as it was): still fine;
#        e. a damaged part replacing a good one: that kit is reported damaged, its complete copy kept; then repaired;
#           a part cut short (no zip directory) and the good one uploaded again as "... (1).zip"; a part whose kit.json
#           is damaged; an empty part of a kit never uploaded: each reported, the other kits still verified;
#        f. a repository that cannot be fetched: exit status 10 and what to do (add_repo, the README's steps);
#        g. parts committed to another branch (the upload page's pull-request choice): used, and the branch named;
#        h. a kit from a newer build whose kit.json this checkout cannot read: "NOT verified", update the checkout;
#      and never a private path in its output;
#   4. with --app-bundle DIR instead (CI: the bundle parts the real app made in the Simulator's end-to-end test), only
#      those parts through steps 2 and 3: a stand-in repository, the one command, complete and scored.
#
# --short runs the plan at a quarter of its timings and bundles it in 10,000,000-byte parts, so it still has several
# (CI); the default is the full-length kit in the app's 24,000,000-byte parts (about 20-40 minutes).
# --dir DIR works there (default: a new folder under $TMPDIR); --keep keeps it afterwards (it is kept on failure).
# Exits non-zero if anything is not as expected. Needs Swift, ffmpeg, unzip, git and gzip.
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
repo_phys=$(cd "$repo" && pwd -P)
dir=""; short=0; keep=0; app_bundle=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || { echo "--dir needs a folder" >&2; exit 1; }; dir=$2; shift 2 ;;
    --short) short=1; shift ;;
    --keep) keep=1; shift ;;
    --app-bundle) [ $# -ge 2 ] || { echo "--app-bundle needs a folder" >&2; exit 1; }; app_bundle=$(cd "$2" && pwd -P); shift 2 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 1 ;;
  esac
done
if ! command -v swift >/dev/null; then sbin=$("$here/install-swift.sh") || exit 1; PATH="$sbin:$PATH"; fi
for t in swift ffmpeg ffprobe unzip git gzip; do command -v "$t" >/dev/null || { echo "$t is not installed" >&2; exit 1; }; done
export PATH

if [ -z "$dir" ]; then dir=$(mktemp -d "${TMPDIR:-/tmp}/bounce-handoff-dryrun.XXXXXX"); fi
case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
case "$dir/" in "$repo_phys"/*|"$repo"/*) echo "refusing to work inside the repository: --dir must be outside it" >&2; exit 1 ;; esac
mkdir -p "$dir"; dir=$(cd "$dir" && pwd -P)
case "$dir/" in "$repo_phys"/*|"$repo"/*) echo "refusing to work inside the repository: --dir must be outside it" >&2; exit 1 ;; esac
# the folder is the dry run's own: a folder with other things in it (no marker from an earlier dry run) is refused
marker="${dir:?}/.bounce-handoff-dryrun"
if [ -n "$(ls -A "$dir")" ] && [ ! -f "$marker" ]; then echo "refusing --dir: it is not empty and not an earlier dry run's folder" >&2; exit 1; fi
find "$dir" -mindepth 1 -maxdepth 1 ! -name .bounce-handoff-dryrun -exec rm -rf {} +
touch "$marker"
mkdir -p "$dir/logs"
repo_status_before=$(git -C "$repo" status --porcelain)

failures=0
step() { printf '\n=== %s\n' "$*"; }
ok() { printf '  ok: %s\n' "$*"; }
bad() { printf '  FAILED: %s\n' "$*"; failures=$((failures + 1)); }
finish() {
  local code=$?
  if [ "$failures" -gt 0 ] || [ "$code" -ne 0 ]; then
    echo; echo "dry run FAILED ($failures check(s); exit $code); its files are kept for a look"; exit 1
  fi
  if [ "$keep" = 0 ] && [ -f "$marker" ]; then rm -rf "${dir:?}"; else echo "files kept"; fi
  echo; echo "dry run passed"
}
trap finish EXIT
t_start=$(date +%s)
elapsed() { echo "$(( $(date +%s) - t_start )) s"; }

pkg="$repo/ios/BounceCore"
step "building bounce-kit and bounce-score (release)"
swift build -c release --package-path "$pkg" --product bounce-kit > "$dir/logs/build.log" 2>&1
swift build -c release --package-path "$pkg" --product bounce-score >> "$dir/logs/build.log" 2>&1
bin=$(swift build -c release --package-path "$pkg" --show-bin-path)
bk="$bin/bounce-kit"
ok "built ($(elapsed))"

# the one command and what it must say
export BOUNCE_PRIVATE="$dir/private"
run_one() {  # <log name> <expected exit status> <arguments...>: the one command
  local name=$1 want=$2; shift 2
  local got=0 t0
  t0=$(date +%s)
  "$here/kit-uploaded.sh" "$@" > "$dir/logs/$name.txt" 2>&1 || got=$?
  sed 's/^/  | /' "$dir/logs/$name.txt"
  if [ "$got" = "$want" ]; then ok "$name: exit status $got as expected ($(( $(date +%s) - t0 )) s)"
  else bad "$name: exit status $got, expected $want"; fi
  if grep -qF "$dir" "$dir/logs/$name.txt"; then bad "$name printed a private path"; else ok "$name printed no private path"; fi
}
expect_in() { if grep -qF -- "$2" "$dir/logs/$1.txt"; then ok "$1 says \"$2\""; else bad "$1 does not say \"$2\""; fi; }
expect_not() { if grep -qF -- "$2" "$dir/logs/$1.txt"; then bad "$1 says \"$2\""; else ok "$1 does not say \"$2\""; fi; }
expect_twice() {  # the verdicts come before the scores (which take minutes) and again at the end
  local n; n=$(grep -cF -- "$2" "$dir/logs/$1.txt" || true)
  if [ "$n" -ge 2 ]; then ok "$1 says \"$2\" before the scores and after them"; else bad "$1 says \"$2\" $n time(s), not twice"; fi
}
latest_scores() { find "$BOUNCE_PRIVATE/scores" -maxdepth 1 -name '*.json' | sort | tail -1; }
can_delete=": all parts verified: the owner can delete this kit from the phone"
# the stand-in for github.com/matthewrein/bounce-captures (a local bare repository) and the owner's commits to it
gitc() { local b=$1; shift; git -C "$b" -c user.name=owner -c user.email=owner@users.noreply.github.com -c push.negotiate=false "$@"; }
stand_in() {  # <bare repository> <the owner's view of it>: a new private repository with a README, as github.com/new makes it
  git init -q --bare -b main "$1"
  git clone -q "$1" "$2" 2>/dev/null
  printf '# bounce-captures\n' > "$2/README.md"
  gitc "$2" add README.md; gitc "$2" commit -qm "Initial commit"; gitc "$2" push -q origin main 2>/dev/null
}

if [ -z "$app_bundle" ]; then
# --- 1. the phone ---------------------------------------------------------------------------------------------------------
scale=(); [ "$short" = 1 ] && scale=(--time-scale 0.25)
# the short kit (CI) is bundled in parts of 10,000,000 bytes, so it too comes in several parts; the full-length kit in
# the app's 24,000,000
limit=(); [ "$short" = 1 ] && limit=(--limit 10000000)
phone_kit() {  # <date> [write-synthetic options]: writes a kit into the phone's Application Support and bundles it
  local date=$1; shift
  local id
  id=$("$bk" write-synthetic "$dir/phone/AppSupport/Kits" --date "$date" "$@" 2>> "$dir/logs/write-$date.log")
  tail -1 "$dir/logs/write-$date.log" | sed 's/^/  /' >&2
  "$bk" bundle "$dir/phone/AppSupport/Kits/$id" "$dir/phone/Documents/Kits/$id" ${limit[@]+"${limit[@]}"} > "$dir/logs/bundle-$id.txt" 2> "$dir/logs/bundle-$id.err" \
    || { cat "$dir/logs/bundle-$id.txt" "$dir/logs/bundle-$id.err" | sed 's/^/  /' >&2; return 1; }
  sed 's/^/  /' "$dir/logs/bundle-$id.txt" "$dir/logs/bundle-$id.err" >&2
  printf '%s\n' "$id"
}
check_parts() {  # <kit id> <parts folder>: sizes, and that unzipping all of them rebuilds the kit byte for byte
  local id=$1 parts=$2 n=0 over=0 p s
  for p in "$parts"/"$id"-part*of*.zip; do
    n=$((n + 1)); s=$(wc -c < "$p" | tr -d ' ')
    [ "$s" -le 24000000 ] || over=$((over + 1))
    [ "$s" -le 26214400 ] || over=$((over + 1))
  done
  if [ "$n" -gt 0 ] && [ "$over" = 0 ]; then ok "$id: $n part(s), each at most 24,000,000 bytes (and under GitHub's 25 MiB)"
  else bad "$id: $n part(s), $over size problem(s)"; fi
}
step "the phone: a synthetic kit as the app writes it, and its bundle"
kit_a=$(phone_kit 20261119-083000 "${scale[@]+"${scale[@]}"}")
ok "kit $kit_a written and bundled ($(elapsed))"
parts_a="$dir/phone/Documents/Kits/$kit_a"
check_parts "$kit_a" "$parts_a"
mkdir -p "$dir/rebuilt"
for p in "$parts_a"/*.zip; do unzip -o -qq "$p" -d "$dir/rebuilt"; done
if diff -r "$dir/phone/AppSupport/Kits/$kit_a" "$dir/rebuilt/$kit_a" > "$dir/logs/rebuilt.diff" 2>&1; then
  ok "unzipping every part rebuilds the kit byte for byte"
else bad "the parts do not rebuild the kit ($(wc -l < "$dir/logs/rebuilt.diff") differences)"; fi
"$bk" check "$dir/rebuilt/$kit_a" > "$dir/logs/check-rebuilt.txt" && ok "the rebuilt kit holds every file kit.json names" \
  || { bad "bounce-kit check on the rebuilt kit"; sed 's/^/  /' "$dir/logs/check-rebuilt.txt"; }
sed 's/^/  /' "$dir/logs/check-rebuilt.txt"
n_a=$(ls "$parts_a"/*.zip | wc -l | tr -d ' ')

# --- 2. the stand-in for github.com/matthewrein/bounce-captures ----------------------------------------------------------
step "the upload: a local stand-in for the private captures repository"
remote="$dir/github/bounce-captures.git"
browser="$dir/github/browser"
stand_in "$remote" "$browser"
gitb() { gitc "$browser" "$@"; }
# GitHub's web upload: the files at the repository's root (or the folder the page is in), one commit
upload() {  # <folder in the repository, "." for the root> <files...>
  local to=$1; shift
  mkdir -p "$browser/$to"
  cp "$@" "$browser/$to/"
  gitb add -A
  gitb commit -q --allow-empty -m "Add files via upload"
  gitb push -q origin main 2>/dev/null
}
ok "bare repository with a README"

step "3a. the first part only"
if [ "$n_a" -ge 2 ]; then
  upload . "$parts_a/$kit_a-part1of$n_a.zip"
  # scoring on: an incomplete kit is not scored (it would become the baseline the complete kit is compared with)
  run_one 3a-first-part 2 "$remote"
  expect_in 3a-first-part "part 2 of $n_a is missing"
  expect_not 3a-first-part "$kit_a$can_delete"
  expect_in 3a-first-part "Not scored: no complete kit yet."
  if [ -z "$(find "$BOUNCE_PRIVATE/scores" -maxdepth 1 -name '*.json' 2>/dev/null)" ]; then ok "no scores saved for the incomplete kit"
  else bad "scores were saved for the incomplete kit"; fi
  rest=(); for i in $(seq 2 "$n_a"); do rest+=("$parts_a/$kit_a-part${i}of$n_a.zip"); done
else
  ok "the kit has a single part: the incomplete upload is checked by dropping it (3e) instead"
  rest=("$parts_a"/*.zip)
fi

step "3b. the other parts, in a second commit"
upload . "${rest[@]}"
# the full-length dry run scores the synthetic kit as well (--synthetic); the command leaves it out by default
if [ "$short" = 1 ]; then run_one 3b-complete 0 "$remote"; else run_one 3b-complete 0 "$remote" --synthetic; fi
expect_twice 3b-complete "$kit_a$can_delete"
expect_in 3b-complete "parts: $n_a of $n_a, every zip's CRCs check out"
expect_in 3b-complete "## Capture kit scores"
if [ "$short" = 1 ]; then expect_not 3b-complete "(synthetic kit)"; else expect_in 3b-complete "(synthetic kit)"; fi
"$bk" expect "$(latest_scores)" --kit "$kit_a" --max-tilt-error 2 --min-lock-rate 0.5 > "$dir/logs/expect-a.txt" 2>&1 \
  && ok "$(cat "$dir/logs/expect-a.txt")" || { bad "the scores of $kit_a"; sed 's/^/  /' "$dir/logs/expect-a.txt"; }

step "3c. a second kit, uploaded later (H.264, no LiDAR)"
kit_b=$(phone_kit 20261119-091500 --codec h264 --no-lidar --time-scale 0.1)
parts_b="$dir/phone/Documents/Kits/$kit_b"
check_parts "$kit_b" "$parts_b"
upload . "$parts_b"/*.zip
run_one 3c-second-kit 0 "$remote"
expect_in 3c-second-kit "$kit_a$can_delete"
expect_in 3c-second-kit "$kit_b$can_delete"
"$bk" expect "$(latest_scores)" --kit "$kit_b" > "$dir/logs/expect-b.txt" 2>&1 && ok "$kit_b scored: $(cat "$dir/logs/expect-b.txt")" \
  || { bad "$kit_b was not scored"; sed 's/^/  /' "$dir/logs/expect-b.txt"; }
"$bk" expect "$(latest_scores)" --kit "$kit_a" --max-tilt-error 2 > /dev/null 2>&1 && ok "$kit_a scored again, still within 2°" \
  || bad "$kit_a not scored again"

step "3d. the same parts uploaded again (renamed by Safari, in a folder; and re-committed as they were)"
mkdir -p "$dir/again"
first_b=$(ls "$parts_b"/*.zip | head -1)
renamed="$dir/again/$(basename "$first_b" .zip) (1).zip"
cp "$first_b" "$renamed"
upload "uploads from the phone" "$renamed"
upload . "$parts_a/$kit_a-part1of$n_a.zip"
run_one 3d-again 0 "$remote" --no-score
expect_in 3d-again "$kit_a$can_delete"
expect_in 3d-again "$kit_b$can_delete"

step "3e. a damaged part replacing a good one, then the good one again"
victim=$(ls "$parts_a"/*.zip | tail -1)
vname=$(basename "$victim")
mkdir -p "$dir/damaged"; cp "$victim" "$dir/damaged/$vname"
size=$(wc -c < "$victim" | tr -d ' ')
printf 'XXXXXXXXXXXXXXXX' | dd of="$dir/damaged/$vname" bs=1 seek=$((size / 2)) conv=notrunc status=none
upload . "$dir/damaged/$vname"
run_one 3e-damaged 2 "$remote" --no-score
expect_in 3e-damaged "part $n_a of $n_a is damaged (its CRC check failed"
expect_in 3e-damaged "the copy unzipped earlier is complete and is kept"
expect_not 3e-damaged "$kit_a$can_delete"
expect_in 3e-damaged "$kit_b$can_delete"
upload . "$victim"
run_one 3e-repaired 0 "$remote" --no-score
expect_in 3e-repaired "$kit_a$can_delete"

step "3e. a part whose kit.json is damaged (near the start of the zip), then the good one again"
p1="$kit_a-part1of$n_a.zip"
mkdir -p "$dir/kitjson"; cp "$parts_a/$p1" "$dir/kitjson/$p1"
printf 'XXXXXXXX' | dd of="$dir/kitjson/$p1" bs=1 seek=120 conv=notrunc status=none
upload . "$dir/kitjson/$p1"
run_one 3e-kitjson-damaged 2 "$remote" --no-score
expect_in 3e-kitjson-damaged "== $kit_a =="
expect_in 3e-kitjson-damaged "part 1 of $n_a is damaged"
expect_not 3e-kitjson-damaged "$kit_a$can_delete"
expect_in 3e-kitjson-damaged "$kit_b$can_delete"
upload . "$parts_a/$p1"
run_one 3e-kitjson-repaired 0 "$remote" --no-score
expect_in 3e-kitjson-repaired "$kit_a$can_delete"

step "3e. a part cut short (no zip directory), then the good one again as \"... (1).zip\""
mkdir -p "$dir/cut"; head -c 200000 "$parts_a/$p1" > "$dir/cut/$p1"
upload . "$dir/cut/$p1"
run_one 3e-cut-short 2 "$remote" --no-score
expect_in 3e-cut-short "part 1 of $n_a is damaged (its CRC check failed, or it was cut short)"
expect_not 3e-cut-short "$kit_a$can_delete"
expect_in 3e-cut-short "$kit_b$can_delete"
cp "$parts_a/$p1" "$dir/cut/$(basename "$p1" .zip) (1).zip"
upload . "$dir/cut/$(basename "$p1" .zip) (1).zip"
run_one 3e-cut-reuploaded 0 "$remote" --no-score
expect_in 3e-cut-reuploaded "$kit_a$can_delete"
expect_in 3e-cut-reuploaded "$kit_b$can_delete"

step "3e. an empty part of a kit never uploaded, next to the complete kits"
empty="slab-kit-20261121-090000-part1of2.zip"
: > "$dir/cut/$empty"
upload . "$dir/cut/$empty"
run_one 3e-empty-part 2 "$remote" --no-score
expect_in 3e-empty-part "slab-kit-20261121-090000: NOT complete (2 missing or damaged part(s)"
expect_in 3e-empty-part "$kit_a$can_delete"
expect_in 3e-empty-part "$kit_b$can_delete"
gitb rm -q "$empty"; gitb commit -qm "Delete $empty"; gitb push -q origin main 2>/dev/null

step "3f. a repository that cannot be fetched"
BOUNCE_PRIVATE="$dir/private-unreachable" run_one 3f-unreachable 10 "$dir/github/no-such-repository.git" --no-score
expect_in 3f-unreachable "add_repo"
expect_in 3f-unreachable "Sending it"

step "3g. parts committed to another branch (the upload page's \"Create a new branch ... pull request\")"
if [ "$n_a" -ge 2 ]; then
  g_browser="$dir/github-branch/browser"
  stand_in "$dir/github-branch/bounce-captures.git" "$g_browser"
  cp "$parts_a/$p1" "$g_browser/"
  gitc "$g_browser" add -A; gitc "$g_browser" commit -qm "Add files via upload"; gitc "$g_browser" push -q origin main 2>/dev/null
  gitc "$g_browser" checkout -q -b owner-patch-1
  cp "${rest[@]}" "$g_browser/"
  gitc "$g_browser" add -A; gitc "$g_browser" commit -qm "Add files via upload"; gitc "$g_browser" push -q origin owner-patch-1 2>/dev/null
  BOUNCE_PRIVATE="$dir/private-branch" run_one 3g-branch 0 "$dir/github-branch/bounce-captures.git" --no-score
  expect_in 3g-branch "$kit_a$can_delete"
  expect_in 3g-branch "are on branch owner-patch-1, not on main"
else
  ok "the kit has a single part: no parts to put on another branch"
fi

step "3h. a kit from a newer build: a kit.json this checkout cannot read"
newer="$dir/newer"; mkdir -p "$newer/AppSupport"
cp -R "$dir/phone/AppSupport/Kits/$kit_b" "$newer/AppSupport/$kit_b"
# a shot status this checkout does not know, as a later build might write
awk '!d && /"status" : "[a-z]*"/ { sub(/"status" : "[a-z]*"/, "\"status\" : \"deferred\""); d = 1 } { print }' \
  "$dir/phone/AppSupport/Kits/$kit_b/kit.json" > "$newer/AppSupport/$kit_b/kit.json"
if grep -q '"deferred"' "$newer/AppSupport/$kit_b/kit.json"; then
  "$bk" bundle "$newer/AppSupport/$kit_b" "$newer/Documents/$kit_b" > "$dir/logs/bundle-newer.txt" 2>&1
  h_browser="$dir/github-newer/browser"
  stand_in "$dir/github-newer/bounce-captures.git" "$h_browser"
  cp "$newer/Documents/$kit_b"/*.zip "$h_browser/"
  gitc "$h_browser" add -A; gitc "$h_browser" commit -qm "Add files via upload"; gitc "$h_browser" push -q origin main 2>/dev/null
  BOUNCE_PRIVATE="$dir/private-newer" run_one 3h-newer-build 2 "$dir/github-newer/bounce-captures.git" --no-score
  expect_in 3h-newer-build "$kit_b: NOT verified: this checkout cannot read its kit.json"
  expect_in 3h-newer-build "this checkout cannot read kit.json at shots["
  expect_not 3h-newer-build "$kit_b$can_delete"
else
  bad "could not make a kit.json from a newer build"
fi

fi

# --- 4. the bundle the real app made (CI: the Simulator's demo kit) ------------------------------------------------------
if [ -n "$app_bundle" ]; then
  step "4. the bundle the app made in the Simulator"
  found=$(find "$app_bundle" -type f -name '*-part*of*.zip' | sort)
  if [ -z "$found" ]; then bad "no bundle parts in the --app-bundle folder"; else
    demo_remote="$dir/demo/bounce-captures.git"
    stand_in "$demo_remote" "$dir/demo/browser"
    while IFS= read -r p; do cp "$p" "$dir/demo/browser/"; done <<< "$found"
    gitc "$dir/demo/browser" add -A; gitc "$dir/demo/browser" commit -qm "Add files via upload"; gitc "$dir/demo/browser" push -q origin main 2>/dev/null
    while IFS= read -r p; do
      s=$(wc -c < "$p" | tr -d ' '); [ "$s" -le 24000000 ] && ok "$(basename "$p"): $s bytes" || bad "$(basename "$p"): $s bytes"
    done <<< "$found"
    BOUNCE_PRIVATE="$dir/private-demo" run_one 4-app-bundle 0 "$demo_remote"
    expect_in 4-app-bundle "$can_delete"
    expect_in 4-app-bundle "## Capture kit scores"
  fi
fi

step "privacy"
if [ "$(git -C "$repo" status --porcelain)" = "$repo_status_before" ]; then ok "nothing was written into the repository"
else bad "the repository's status changed during the dry run"; fi

step "summary ($(elapsed))"
if [ -z "$app_bundle" ]; then
  for f in "$dir"/logs/bundle-*.err; do sed 's/^/  /' "$f"; done
  echo "  $kit_a: $(du -sk "$dir/phone/AppSupport/Kits/$kit_a" | cut -f1) KB on the phone, $n_a part(s)"
  grep -E "^slab-kit-.*(verified|NOT complete)" "$dir/logs/3b-complete.txt" | sed 's/^/  /' || true
else
  grep -E "^slab-kit-.*(verified|NOT complete)" "$dir/logs/4-app-bundle.txt" | sed 's/^/  /' || true
fi
