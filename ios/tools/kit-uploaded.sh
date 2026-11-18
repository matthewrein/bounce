#!/usr/bin/env bash
# The one command once the owner says "kit uploaded" (ios/CaptureKit.md, "When the kit is uploaded"):
#
#   ios/tools/kit-uploaded.sh [captures repository URL or path] [--no-score] [--no-synthetic] [--measured]
#
# 1. Fetches the private captures repository (default https://github.com/matthewrein/bounce-captures; in a Claude
#    session attach it first with add_repo) into $BOUNCE_PRIVATE/bounce-captures (default ~/bounce-private; a folder
#    inside this repository is refused), cloning it the first time and updating it after that.
# 2. Finds every kit's bundle parts in it, wherever they sit and also when renamed ("...-part1of3 (1).zip"), and checks
#    each kit: all its parts there, every zip's CRCs (unzip -t), the same kit.json in every part, each part within the
#    24,000,000-byte limit; the same part uploaded twice is used once (the newest upload if they differ).
# 3. Unzips each kit afresh into $BOUNCE_PRIVATE/kits/<kitId> and checks it holds every file its kit.json says it
#    captured (bounce-kit check: sizes, frame and sample counts). An incomplete kit never replaces a complete copy.
# 4. Scores every kit there with score-kits.sh (the synthetic kit too, unless --no-synthetic), which saves the scores
#    in $BOUNCE_PRIVATE/scores and compares them with the previous run, and prints a report per kit: parts, shots
#    captured and skipped, the scores (Markdown), then one line per kit: "all parts verified: the owner can delete this
#    kit from the phone", or what is missing.
#
# Running it again is safe: it re-checks and re-scores every kit, a new upload included. Kits are private: it prints
# kit ids, part numbers, shot ids and numbers, never paths or anything from the pictures. Needs git, unzip, ffmpeg and
# a Swift toolchain. Exit status: 0 every kit complete (and scored); 1 setup or usage; 2 a kit is incomplete or
# damaged, or nothing was uploaded; 3 scoring failed; 10 the repository could not be fetched.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
repo_phys=$(cd "$repo" && pwd -P)
private=${BOUNCE_PRIVATE:-$HOME/bounce-private}
source_url=${BOUNCE_CAPTURES:-https://github.com/matthewrein/bounce-captures}
limit=24000000
upload_limit=26214400   # GitHub's web upload: 25 MiB a file
score=1
score_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-score) score=0; shift ;;
    --no-synthetic|--measured) score_args+=("$1"); shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1 (see --help)" >&2; exit 1 ;;
    *) source_url=$1; shift ;;
  esac
done

say() { printf '%s\n' "$*"; }
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
private=$(private_dir "$private" "BOUNCE_PRIVATE")
clone="${private:?}/bounce-captures"
kits=$(private_dir "$private/kits" "the kits folder")
work="${private:?}/.kit-uploaded"
rm -rf "${work:?}"; mkdir -p "$work"
trap 'rm -rf "${work:?}"' EXIT

for t in git unzip; do command -v "$t" >/dev/null || { echo "$t is not installed" >&2; exit 1; }; done
# Swift: on PATH, else the newest toolchain under /opt (as in Claude's Linux sessions)
if ! command -v swift >/dev/null; then
  for d in $(ls -d /opt/swift-*/usr/bin 2>/dev/null | sort -V -r); do [ -x "$d/swift" ] && { PATH="$d:$PATH"; break; }; done
fi
command -v swift >/dev/null || { echo "Swift is not installed (or not on PATH): it builds the scorer" >&2; exit 1; }
export PATH

# --- 1. the captures repository ---------------------------------------------------------------------------------------
case "$source_url" in
  http://*|https://*|git@*|ssh://*) where="$source_url" ;;
  *) where="a local repository"; [ -d "$source_url" ] && source_url=$(cd "$source_url" && pwd -P) ;;
esac
cannot_fetch() {
  local why
  why=$(grep -v '^ *$' "$work/git.err" 2>/dev/null | tail -1 | sed "s|$clone|the captures clone|g; s|$private|the private folder|g" || true)
  # a local path given (the dry run) stays out of the output too
  case "$source_url" in http://*|https://*|git@*|ssh://*) ;; *) why=${why//"$source_url"/the repository given} ;; esac
  say "Could not fetch the captures repository ($where)${why:+: $why}."
  say "In a Claude session, attach it first: the add_repo tool with owner \"matthewrein\" and repo \"bounce-captures\", then"
  say "run this again. If attaching is refused or the repository does not exist, the owner has to create the private"
  say "repository bounce-captures (with a README) and give Claude's GitHub app access to it: ios/README.md, \"Sending it,"
  say "privately\" (github.com/new, then github.com/settings/installations > Claude > Configure > Repository access)."
  exit 10
}
if [ -d "$clone/.git" ]; then
  git -C "$clone" remote set-url origin "$source_url"
  git -C "$clone" fetch -q --prune origin 2>"$work/git.err" || cannot_fetch
  git -C "$clone" remote set-head origin -a >/dev/null 2>&1 || true
else
  rm -rf "${clone:?}"
  git clone -q "$source_url" "$clone" 2>"$work/git.err" || { rm -rf "${clone:?}"; cannot_fetch; }
fi
branch=$(git -C "$clone" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -z "$branch" ]; then
  for b in origin/main origin/master; do git -C "$clone" rev-parse -q --verify "$b" >/dev/null && { branch=$b; break; }; done
fi
if [ -z "$branch" ]; then
  say "The captures repository ($where) is empty: nothing has been uploaded yet. (It needs a README to have an upload"
  say "page: ios/README.md, \"Sending it, privately\".)"
  exit 2
fi
git -C "$clone" checkout -q --detach "$branch" 2>"$work/git.err" || cannot_fetch
git -C "$clone" reset -q --hard "$branch"
git -C "$clone" clean -q -ffdx
say "Captures repository ($where) at $(git -C "$clone" log -1 --format='%h, committed %cd' --date=format:'%Y-%m-%d %H:%M %z'),"
say "$(git -C "$clone" rev-list --count HEAD) commits."

# the checker (bounce-kit) and, later, the scorer: release builds of this checkout
pkg="$repo/ios/BounceCore"
if ! swift build -c release --package-path "$pkg" --product bounce-kit > "$work/build.log" 2>&1; then
  echo "could not build bounce-kit:" >&2; tail -20 "$work/build.log" >&2; exit 1
fi
bk="$(swift build -c release --package-path "$pkg" --show-bin-path)/bounce-kit"

# --- 2. the parts ---------------------------------------------------------------------------------------------------
# one line per zip: kit, part, of, bytes, commit time, content hash, kit.json hash, CRCs ok (1/0), entries ok (1/0), path
tsv="$work/parts.tsv"; : > "$tsv"
# a kit id is a plain folder name ("slab-kit-20261117-153000"): nothing that could reach outside the kits folder
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }
others=0
while IFS= read -r rel; do
  f="$clone/$rel"
  if ! unzip -Z1 "$f" > "$work/entries" 2>/dev/null; then
    # not even a zip directory: a part cut short? Name it by its file name if that names a kit part
    b=$(basename "$rel")
    if [[ "$b" =~ ^(.+)-part([0-9]+)of([0-9]+) ]] && valid_id "${BASH_REMATCH[1]}"; then
      printf '%s\t%s\t%s\t%s\t0\t-\t-\t0\t1\t%s\n' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))" \
        "$(wc -c < "$f" | tr -d ' ')" "$rel" >> "$tsv"
    else others=$((others + 1)); fi
    continue
  fi
  kit=$(grep -E '^[^/]+/kit\.json$' "$work/entries" | head -1 | cut -d/ -f1 || true)
  if [ -z "$kit" ] || ! valid_id "$kit"; then others=$((others + 1)); continue; fi
  b=$(basename "$rel")
  idx="?"; cnt="?"
  if [[ "$b" =~ -part([0-9]+)of([0-9]+) ]]; then idx=$((10#${BASH_REMATCH[1]})); cnt=$((10#${BASH_REMATCH[2]})); fi
  ok=0; unzip -tqq "$f" >/dev/null 2>&1 && ok=1
  # every entry inside the kit's folder, no ".." anywhere
  inside=1
  awk -v k="$kit/" 'index($0, k) != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ { bad = 1 } END { exit bad }' "$work/entries" || inside=0
  kj=$(unzip -p "$f" "$kit/kit.json" 2>/dev/null | git hash-object --stdin)
  when=$(git -C "$clone" log -1 --format=%ct -- "$rel" 2>/dev/null || echo 0)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kit" "$idx" "$cnt" "$(wc -c < "$f" | tr -d ' ')" "${when:-0}" \
    "$(git hash-object "$f")" "$kj" "$ok" "$inside" "$rel" >> "$tsv"
done < <(cd "$clone" && find . -path ./.git -prune -o -type f -iname '*.zip' -print | sed 's|^\./||' | LC_ALL=C sort)

kit_ids=$(cut -f1 "$tsv" | LC_ALL=C sort -u)
if [ -z "$kit_ids" ]; then
  say ""
  extra_note=""; [ "$others" -gt 0 ] && extra_note=" ($others other zip file(s) ignored)"
  say "No kit parts in the captures repository yet$extra_note: ask the owner to upload"
  say "the parts (ios/README.md, \"Sending it, privately\")."
  exit 2
fi
[ "$others" -gt 0 ] && say "$others zip file(s) that are not kit parts were ignored."

# field helpers over the parts table
rows() { awk -F'\t' -v k="$1" '$1 == k' "$tsv"; }

status=0
verdicts=()
reports=()
for kit in $kit_ids; do
  r="$work/report-$kit"; : > "$r"
  note() { printf '  %s\n' "$*" >> "$r"; }
  problems=0
  rows "$kit" > "$work/rows"
  # which bundle: the part count M whose parts are all there (the newest upload if two are), else the one with the most
  best=""; best_key=-1; best_have=0
  for m in $(awk -F'\t' '$3 != "?" { print $3 }' "$work/rows" | sort -un); do
    have=$(awk -F'\t' -v m="$m" '$3 == m && $8 == 1 && $9 == 1 && $2 >= 1 && $2 <= m { print $2 }' "$work/rows" | sort -u | wc -l | tr -d ' ')
    newest=$(awk -F'\t' -v m="$m" '$3 == m { print $5 }' "$work/rows" | sort -n | tail -1)
    # complete beats incomplete; then the newest upload (complete) or the most parts, then the newest (incomplete)
    if [ "$have" -eq "$m" ]; then key=$((1000000000000 + newest)); else key=$((have * 10000000000 + newest)); fi
    if [ "$key" -gt "$best_key" ]; then best=$m; best_key=$key; best_have=$have; fi
  done
  : > "$work/chosen"
  largest=0
  if [ -n "$best" ]; then
    for m in $(awk -F'\t' -v b="$best" '$3 != "?" && $3 != b { print $3 }' "$work/rows" | sort -un); do
      note "an earlier bundle of this kit in $m parts was also uploaded: not used"
    done
    i=1
    while [ "$i" -le "$best" ]; do
      good=$(awk -F'\t' -v m="$best" -v i="$i" '$3 == m && $2 == i && $8 == 1 && $9 == 1' "$work/rows" | sort -t"$(printf '\t')" -k5,5n)
      if [ -n "$good" ]; then
        pick=$(printf '%s\n' "$good" | tail -1)
        printf '%s\n' "$pick" >> "$work/chosen"
        n=$(printf '%s\n' "$good" | cut -f6 | sort -u | wc -l | tr -d ' ')
        [ "$n" -gt 1 ] && note "part $i of $best was uploaded $n times with different contents: the newest upload is used"
        bytes=$(printf '%s\n' "$pick" | cut -f4)
        [ "$bytes" -gt "$largest" ] && largest=$bytes
        if [ "$bytes" -gt "$upload_limit" ]; then note "part $i of $best has $bytes bytes, over GitHub's 25 MiB upload limit"; problems=$((problems + 1))
        elif [ "$bytes" -gt "$limit" ]; then note "part $i of $best has $bytes bytes, over the bundle's $limit-byte limit (a file too large for a part)"; fi
      elif awk -F'\t' -v m="$best" -v i="$i" '$3 == m && $2 == i && $9 == 0 { f = 1 } END { exit !f }' "$work/rows"; then
        note "part $i of $best holds files outside the kit's folder: not used"; problems=$((problems + 1))
      elif awk -F'\t' -v m="$best" -v i="$i" '$3 == m && $2 == i { f = 1 } END { exit !f }' "$work/rows"; then
        note "part $i of $best is damaged (its CRC check failed): ask the owner to upload $kit-part${i}of$best.zip again"; problems=$((problems + 1))
      else
        note "part $i of $best is missing: ask the owner to upload $kit-part${i}of$best.zip"; problems=$((problems + 1))
      fi
      i=$((i + 1))
    done
  fi
  # parts whose names lost their number: used too (the contents check below says whether the kit is whole)
  unnumbered=$(awk -F'\t' '$2 == "?" && $8 == 1 && $9 == 1' "$work/rows")
  if [ -n "$unnumbered" ]; then
    printf '%s\n' "$unnumbered" | while IFS= read -r x; do
      h=$(printf '%s\n' "$x" | cut -f6)
      grep -qF "$h" "$work/chosen" || printf '%s\n' "$x" >> "$work/chosen"
    done
    note "$(printf '%s\n' "$unnumbered" | wc -l | tr -d ' ') part(s) with no part number in their name: used as well"
  fi
  if [ -z "$best" ] && [ -z "$unnumbered" ]; then note "no readable part"; problems=$((problems + 1)); fi
  if [ -s "$work/chosen" ]; then
    n=$(cut -f7 "$work/chosen" | sort -u | wc -l | tr -d ' ')
    if [ "$n" -gt 1 ]; then
      note "the parts hold $n different kit.json files (parts from two builds of the bundle): ask the owner to upload every part again"
      problems=$((problems + 1))
    fi
  fi
  have=$(wc -l < "$work/chosen" | tr -d ' ')
  if [ -n "$best" ] && [ "$problems" -eq 0 ]; then
    summary_line="parts: $best of $best, every zip's CRCs check out, the same kit.json in each, the largest $largest bytes (limit $limit)"
  elif [ -n "$best" ]; then
    summary_line="parts: $best_have of $best usable"
  else
    summary_line="parts: $have with no part numbers"
  fi

  # unzip afresh, check the contents, and put it in place (an incomplete kit never replaces a complete copy)
  stage="$work/stage-$kit"; rm -rf "$stage"; mkdir -p "$stage"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    unzip -o -qq "$clone/$(printf '%s\n' "$x" | cut -f10-)" -d "$stage" 2>/dev/null || { note "a part could not be unzipped"; problems=$((problems + 1)); }
  done < "$work/chosen"
  contents_ok=0
  if [ -f "$stage/$kit/kit.json" ]; then
    "$bk" check "$stage/$kit" > "$work/check" 2>&1 && contents_ok=1 || true
    tail -n +2 "$work/check" >> "$r"
  else
    note "contents: no kit.json could be unzipped"
  fi
  [ "$contents_ok" = 1 ] || problems=$((problems + 1))
  if [ "$problems" -eq 0 ] || [ ! -d "$kits/$kit" ] || ! "$bk" check "$kits/$kit" >/dev/null 2>&1; then
    if [ -d "$stage/$kit" ]; then rm -rf "${kits:?}/$kit"; mv "$stage/$kit" "$kits/$kit"; fi
  else
    note "the copy unzipped earlier is complete and is kept for scoring"
  fi
  rm -rf "$stage"
  { printf '%s\n' "== $kit ==" "  $summary_line"; cat "$r"; } > "$r.full"
  reports+=("$r.full")
  if [ "$problems" -eq 0 ]; then
    verdicts+=("$kit: all parts verified: the owner can delete this kit from the phone")
  else
    verdicts+=("$kit: NOT complete ($problems problem(s) above): the owner must keep the kit on the phone until it is uploaded whole")
    status=2
  fi
done

say ""
for f in "${reports[@]}"; do cat "$f"; say ""; done

# --- 4. the scores ------------------------------------------------------------------------------------------------------
if [ "$score" = 1 ]; then
  say "Scoring every kit in the kits folder (score-kits.sh; a few minutes a kit) ..."
  sstatus=0
  "$here/score-kits.sh" --kits "$kits" --scores "$private/scores" ${score_args[@]+"${score_args[@]}"} \
    > "$work/scores.md" 2> "$work/scores.log" || sstatus=$?
  grep -E '^(comparing with|scores saved as|no kits)' "$work/scores.log" || true
  if [ "$sstatus" -eq 0 ]; then
    say ""; cat "$work/scores.md"
  else
    say "Scoring failed (status $sstatus); its last lines:"
    grep -v '^\[' "$work/scores.log" | tail -15 | sed "s|$private|the private folder|g"
    [ "$status" -eq 0 ] && status=3
  fi
else
  say "Not scored (--no-score)."
fi

say ""
for v in "${verdicts[@]}"; do say "$v"; done
exit $status
