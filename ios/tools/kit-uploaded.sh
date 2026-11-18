#!/usr/bin/env bash
# The one command once the owner says "kit uploaded" (ios/CaptureKit.md, "When the kit is uploaded"):
#
#   ios/tools/kit-uploaded.sh [captures repository URL or path] [--no-score] [--synthetic] [--measured]
#
# 1. Fetches the private captures repository (default https://github.com/matthewrein/bounce-captures; in a Claude
#    session attach it first with add_repo) into $BOUNCE_PRIVATE/bounce-captures (default ~/bounce-private; a folder
#    inside this repository is refused), cloning it the first time and updating it after that.
# 2. Finds every kit's bundle parts in it, wherever they sit and also when renamed ("...-part1of3 (1).zip"), on its
#    default branch and on any other branch (the upload page's "new branch ... pull request" choice), and checks each
#    kit: all its parts there, every zip's CRCs (unzip -t), the same kit.json in every part, each part within the
#    24,000,000-byte limit; the same part uploaded twice is used once (the newest upload if they differ).
# 3. Unzips each kit afresh and checks it holds every file its kit.json says it captured (bounce-kit check: sizes,
#    frame and sample counts). A complete kit goes into $BOUNCE_PRIVATE/kits/<kitId>; an incomplete one into
#    kits-incomplete/ (not scored; it never replaces a complete copy). It prints a report per kit and one verdict line
#    per kit: "all parts verified: the owner can delete this kit from the phone", or what is missing.
# 4. Scores the complete kits with score-kits.sh (also the synthetic kit with --synthetic, 4-6 minutes more), which
#    saves the scores in $BOUNCE_PRIVATE/scores and compares them with the previous run, prints the scores (Markdown),
#    then the verdicts again.
#
# A first run builds the checker and the scorer and can take about 10 minutes: in a Claude session, run it in the
# background. With no Swift it installs one (install-swift.sh). Running it again is safe: it re-checks and re-scores
# every kit, a new upload included; a second run while one is going is refused. Kits are private: it prints kit ids,
# part numbers, branch names, shot ids and numbers, never paths or anything from the pictures. Needs git, unzip, and
# ffmpeg with ffprobe (to score). Exit status: 0 every kit complete (and scored); 1 setup or usage; 2 a kit is
# incomplete, damaged or unreadable by this checkout, or nothing was uploaded; 3 scoring failed; 10 the repository
# could not be fetched.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
repo_phys=$(cd "$repo" && pwd -P)
private=${BOUNCE_PRIVATE:-$HOME/bounce-private}
source_url=${BOUNCE_CAPTURES:-https://github.com/matthewrein/bounce-captures}
limit=24000000
upload_limit=26214400   # GitHub's web upload: 25 MiB a file
score=1
synthetic=0
score_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-score) score=0; shift ;;
    --synthetic) synthetic=1; shift ;;
    --no-synthetic) synthetic=0; shift ;;   # the default; still accepted
    --measured) score_args+=("$1"); shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1 (see --help)" >&2; exit 1 ;;
    *) source_url=$1; shift ;;
  esac
done
[ "$synthetic" = 1 ] || score_args+=(--no-synthetic)

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

# one run at a time: a second one would delete the first one's staging folder and share its clone
lock="${private:?}/.kit-uploaded.lock"
if ! mkdir "$lock" 2>/dev/null; then
  other=$(cat "$lock/pid" 2>/dev/null || true)
  # still running, and still this script (after a restart the number may belong to another process)
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null && ps -o args= -p "$other" 2>/dev/null | grep -q kit-uploaded; then
    echo "another kit-uploaded.sh is running (process $other): wait for it to finish, then run this again if needed" >&2
    exit 1
  fi
  rm -rf "$lock"   # left by a run that was killed
  mkdir "$lock" || { echo "could not take the lock in the private folder" >&2; exit 1; }
fi
echo $$ > "$lock/pid"
work="${private:?}/.kit-uploaded"
trap 'rm -rf "${work:?}" "${lock:?}"' EXIT
rm -rf "${work:?}"; mkdir -p "$work"

clone="$private/bounce-captures"
kits=$(private_dir "$private/kits" "the kits folder")
incomplete=$(private_dir "$private/kits-incomplete" "the incomplete kits folder")

need="git unzip"; [ "$score" = 1 ] && need="$need ffmpeg ffprobe"
for t in $need; do
  # ffmpeg and ffprobe are run, not only looked up: the scorer needs them to work
  case "$t" in ffmpeg|ffprobe) "$t" -version >/dev/null 2>&1 ;; *) command -v "$t" >/dev/null ;; esac || {
    echo "$t is not installed or does not run (Linux: apt-get install git unzip ffmpeg; Mac: brew install ffmpeg). --no-score needs only git and unzip." >&2
    exit 1
  }
done
# Swift: on PATH, under /opt or ~/.swift, else installed (install-swift.sh: Ubuntu 24.04 in Claude's sessions)
if ! command -v swift >/dev/null; then
  sbin=$("$here/install-swift.sh") || exit 1
  PATH="$sbin:$PATH"
fi
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
say "$(git -C "$clone" rev-list --count HEAD) commits on ${branch#origin/}."

# the checker (bounce-kit) and, later, the scorer: release builds of this checkout
pkg="$repo/ios/BounceCore"
say "Building the checker (release; a few minutes the first time) ..."
if ! swift build -c release --package-path "$pkg" --product bounce-kit > "$work/build.log" 2>&1; then
  echo "could not build bounce-kit:" >&2; tail -20 "$work/build.log" >&2; exit 1
fi
bk="$(swift build -c release --package-path "$pkg" --show-bin-path)/bounce-kit"

# --- 2. the parts ---------------------------------------------------------------------------------------------------
# every zip: on the default branch (its checkout), and on other branches (taken out of git) unless the default branch
# has the same file; one line each: file, branch ("-" for the default), commit time
zips="$work/zips.tsv"; : > "$zips"
while IFS= read -r rel; do
  case "$rel" in *$'\t'*) continue ;; esac
  when=$(git -C "$clone" log -1 --format=%ct -- "$rel" 2>/dev/null || true)
  printf '%s\t-\t%s\n' "$clone/$rel" "${when:-0}" >> "$zips"
done < <(cd "$clone" && find . -path ./.git -prune -o -type f -iname '*.zip' -print | sed 's|^\./||' | LC_ALL=C sort)
git -C "$clone" ls-tree -r HEAD | awk '{ print $3 }' | LC_ALL=C sort -u > "$work/default-blobs"
n_branch=0
while IFS=' ' read -r ref symref; do
  [ -z "$symref" ] && [ "$ref" != "$branch" ] || continue
  while IFS= read -r -d '' entry; do
    meta=${entry%%$'\t'*}; path=${entry#*$'\t'}
    set -- $meta   # mode, type, object
    [ "${2:-}" = blob ] || continue
    case "$path" in *.[zZ][iI][pP]) ;; *) continue ;; esac
    case "$path" in *$'\t'*|*$'\n'*) continue ;; esac
    grep -qxF "$3" "$work/default-blobs" && continue
    n_branch=$((n_branch + 1))
    mkdir -p "$work/branches/$n_branch"
    f="$work/branches/$n_branch/$(basename "$path")"
    git -C "$clone" cat-file blob "$3" > "$f"
    when=$(git -C "$clone" log -1 --format=%ct "$ref" -- "$path" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$f" "${ref#origin/}" "${when:-0}" >> "$zips"
  done < <(git -C "$clone" ls-tree -r -z "$ref")
done < <(git -C "$clone" for-each-ref --format='%(refname:short) %(symref)' refs/remotes/origin)

# one line per zip: kit, part, of, bytes, commit time, content hash, kit.json hash, CRCs ok (1/0), entries ok (1/0),
# branch, file
tsv="$work/parts.tsv"; : > "$tsv"
# a kit id is a plain folder name ("slab-kit-20261117-153000"): nothing that could reach outside the kits folder
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }
others=0
while IFS=$'\t' read -r f br when; do
  b=$(basename "$f")
  bytes=$(wc -c < "$f" | tr -d ' ')
  if ! unzip -Z1 "$f" > "$work/entries" 2>/dev/null; then
    # not even a zip directory (a part cut short, or empty): named by its file name if that names a kit part
    if [[ "$b" =~ ^(.+)-part([0-9]+)of([0-9]+) ]]; then
      id=${BASH_REMATCH[1]}; i=$((10#${BASH_REMATCH[2]})); m=$((10#${BASH_REMATCH[3]}))
      if valid_id "$id"; then
        printf '%s\t%s\t%s\t%s\t%s\t-\t-\t0\t1\t%s\t%s\n' "$id" "$i" "$m" "$bytes" "$when" "$br" "$f" >> "$tsv"
        continue
      fi
    fi
    others=$((others + 1)); continue
  fi
  kit=$(grep -E '^[^/]+/kit\.json$' "$work/entries" | head -1 | cut -d/ -f1 || true)
  if [ -z "$kit" ] || ! valid_id "$kit"; then others=$((others + 1)); continue; fi
  idx="?"; cnt="?"
  if [[ "$b" =~ -part([0-9]+)of([0-9]+) ]]; then idx=$((10#${BASH_REMATCH[1]})); cnt=$((10#${BASH_REMATCH[2]})); fi
  ok=0; unzip -tqq "$f" >/dev/null 2>&1 && ok=1
  # every entry inside the kit's folder, no ".." anywhere
  inside=1
  awk -v k="$kit/" 'index($0, k) != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ { bad = 1 } END { exit bad }' "$work/entries" || inside=0
  # a kit.json that does not unzip (damaged) still gives a hash; the CRC check above has marked the part damaged
  kj=$( { unzip -p "$f" "$kit/kit.json" 2>/dev/null || true; } | git hash-object --stdin)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kit" "$idx" "$cnt" "$bytes" "$when" \
    "$(git hash-object "$f")" "$kj" "$ok" "$inside" "$br" "$f" >> "$tsv"
done < "$zips"

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
default_name=${branch#origin/}

status=0
verdicts=()
reports=()
for kit in $kit_ids; do
  r="$work/report-$kit"; : > "$r"
  note() { printf '  %s\n' "$*" >> "$r"; }
  part_problems=0; content_problems=0; unreadable=0
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
        if [ "$bytes" -gt "$upload_limit" ]; then note "part $i of $best has $bytes bytes, over GitHub's 25 MiB upload limit"; part_problems=$((part_problems + 1))
        elif [ "$bytes" -gt "$limit" ]; then note "part $i of $best has $bytes bytes, over the bundle's $limit-byte limit (a file too large for a part)"; fi
      elif awk -F'\t' -v m="$best" -v i="$i" '$3 == m && $2 == i && $9 == 0 { f = 1 } END { exit !f }' "$work/rows"; then
        note "part $i of $best holds files outside the kit's folder: not used"; part_problems=$((part_problems + 1))
      elif awk -F'\t' -v m="$best" -v i="$i" '$3 == m && $2 == i { f = 1 } END { exit !f }' "$work/rows"; then
        note "part $i of $best is damaged (its CRC check failed, or it was cut short): ask the owner to upload $kit-part${i}of$best.zip again"
        part_problems=$((part_problems + 1))
      else
        note "part $i of $best is missing: ask the owner to upload $kit-part${i}of$best.zip"; part_problems=$((part_problems + 1))
      fi
      i=$((i + 1))
    done
  fi
  # parts whose names lost their number: used too (the contents check below says whether the kit is whole)
  unnumbered=$(awk -F'\t' '$2 == "?" && $8 == 1 && $9 == 1' "$work/rows")
  if [ -n "$unnumbered" ]; then
    printf '%s\n' "$unnumbered" | while IFS= read -r x; do
      h=$(printf '%s\n' "$x" | cut -f6)
      awk -F'\t' -v h="$h" '$6 == h { f = 1 } END { exit !f }' "$work/chosen" || printf '%s\n' "$x" >> "$work/chosen"
    done
    note "$(printf '%s\n' "$unnumbered" | wc -l | tr -d ' ') part(s) with no part number in their name: used as well"
  fi
  if [ -z "$best" ] && [ -z "$unnumbered" ]; then note "no readable part"; part_problems=$((part_problems + 1)); fi
  if [ -s "$work/chosen" ]; then
    n=$(cut -f7 "$work/chosen" | sort -u | wc -l | tr -d ' ')
    if [ "$n" -gt 1 ]; then
      note "the parts hold $n different kit.json files (parts from two builds of the bundle): ask the owner to upload every part again"
      part_problems=$((part_problems + 1))
    fi
    # parts used from another branch than the default: the upload page's "new branch ... pull request" choice
    awk -F'\t' '$10 != "-" { print $10 }' "$work/chosen" | LC_ALL=C sort -u | while IFS= read -r br; do
      which=$(awk -F'\t' -v b="$br" '$10 == b { print $2 }' "$work/chosen" | sort -n | paste -sd, - | sed 's/,/, /g')
      note "part(s) $which are on branch $br, not on $default_name (uploaded with \"Create a new branch\"): used; merging its pull request on GitHub puts them on $default_name"
    done
  fi
  have=$(wc -l < "$work/chosen" | tr -d ' ')
  if [ -n "$best" ] && [ "$part_problems" -eq 0 ]; then
    summary_line="parts: $best of $best, every zip's CRCs check out, the same kit.json in each, the largest $largest bytes (limit $limit)"
  elif [ -n "$best" ]; then
    summary_line="parts: $best_have of $best usable"
  else
    summary_line="parts: $have with no part numbers"
  fi

  # unzip afresh and check the contents
  stage="$work/stage-$kit"; rm -rf "$stage"; mkdir -p "$stage"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    unzip -o -qq "$(printf '%s\n' "$x" | cut -f11-)" -d "$stage" 2>/dev/null || { note "a part could not be unzipped"; part_problems=$((part_problems + 1)); }
  done < "$work/chosen"
  if [ -f "$stage/$kit/kit.json" ]; then
    cstatus=0; "$bk" check "$stage/$kit" > "$work/check" 2>&1 || cstatus=$?
    tail -n +2 "$work/check" >> "$r"
    if [ "$cstatus" -eq 1 ]; then
      unreadable=1
      note "kit.json does not read with this checkout of the checker: the phone probably runs a newer build. Update this"
      note "checkout (git pull) and run this again; it is not a missing upload"
    elif [ "$cstatus" -ne 0 ]; then
      content_problems=$(sed -n 's/^ *contents: \([0-9][0-9]*\) problem.*/\1/p' "$work/check" | head -1)
      [ -n "$content_problems" ] && [ "$content_problems" -gt 0 ] || content_problems=1
    fi
  else
    note "contents: no kit.json could be unzipped"
    content_problems=1
  fi
  problems=$((part_problems + content_problems + unreadable))
  # into place: a complete kit into the kits folder (scored); an incomplete one into kits-incomplete (not scored),
  # unless a complete copy unzipped earlier is there, which is kept
  if [ "$problems" -eq 0 ]; then
    rm -rf "${kits:?}/$kit" "${incomplete:?}/$kit"; mv "$stage/$kit" "$kits/$kit"
  elif [ -d "$kits/$kit" ] && "$bk" check "$kits/$kit" >/dev/null 2>&1; then
    note "the copy unzipped earlier is complete and is kept for scoring"
  else
    rm -rf "${kits:?}/$kit"
    if [ -d "$stage/$kit" ]; then
      rm -rf "${incomplete:?}/$kit"; mv "$stage/$kit" "$incomplete/$kit"
      [ "$unreadable" = 1 ] || note "not scored while it is incomplete (to score what arrived: score-kits.sh --kits <private folder>/kits-incomplete"
      note "--scores <private folder>/scores-incomplete --no-synthetic, so it never becomes the baseline of the complete kits)"
    fi
  fi
  rm -rf "$stage"
  { printf '%s\n' "== $kit ==" "  $summary_line"; cat "$r"; } > "$r.full"
  reports+=("$r.full")
  if [ "$problems" -eq 0 ]; then
    verdicts+=("$kit: all parts verified: the owner can delete this kit from the phone")
  elif [ "$unreadable" = 1 ] && [ "$part_problems" -eq 0 ]; then
    verdicts+=("$kit: NOT verified: this checkout cannot read its kit.json (update it and run this again): the owner keeps the kit on the phone until then")
    status=2
  else
    if [ "$part_problems" -gt 0 ]; then
      verdicts+=("$kit: NOT complete ($part_problems missing or damaged part(s), above): the owner must keep the kit on the phone until it is uploaded whole")
    else
      # every part arrived intact, yet files kit.json names are not in them: uploading again will not help
      verdicts+=("$kit: NOT complete (every part arrived, but the contents check found $content_problems problem(s), above): the owner keeps the kit on the phone until they are looked into")
    fi
    status=2
  fi
done

say ""
for f in "${reports[@]}"; do cat "$f"; say ""; done
# the verdicts now (scoring takes minutes), and again at the end
for v in "${verdicts[@]}"; do say "$v"; done

# --- 4. the scores ------------------------------------------------------------------------------------------------------
have_kit=0
for d in "$kits"/*/kit.json; do [ -f "$d" ] && { have_kit=1; break; }; done
if [ "$score" = 0 ]; then
  say ""; say "Not scored (--no-score)."
elif [ "$have_kit" = 0 ] && [ "$synthetic" = 0 ]; then
  say ""; say "Not scored: no complete kit yet."
else
  say ""
  say "Scoring the complete kits (score-kits.sh: a couple of minutes a kit$([ "$synthetic" = 1 ] && echo ", 4-6 more for the synthetic kit")) ..."
  sstatus=0
  "$here/score-kits.sh" --kits "$kits" --scores "$private/scores" ${score_args[@]+"${score_args[@]}"} \
    > "$work/scores.md" 2> "$work/scores.log" || sstatus=$?
  grep -E '^(comparing with|scores saved as|no kits)' "$work/scores.log" || true
  if [ "$sstatus" -eq 0 ]; then
    say ""; cat "$work/scores.md"
    # a kit none of whose video shots could be scored (ffmpeg could not decode its video, say) is a failed scoring
    saved=$(sed -n 's/^scores saved as \(.*\) in the scores folder$/\1/p' "$work/scores.log" | tail -1)
    for d in "$kits"/*/; do
      k=$(basename "$d"); [ -f "$d/kit.json" ] || continue
      if ! "$bk" expect "$private/scores/$saved" --kit "$k" --min-scored 1 > "$work/expect" 2>&1; then
        why=$(grep '^bounce-kit: ' "$work/expect" | tail -1 | sed 's/^bounce-kit: //' || true)
        say "Scoring failed for $k: ${why:-$(tail -1 "$work/expect")}"
        [ "$status" -eq 0 ] && status=3
      fi
    done
  else
    say "Scoring failed (status $sstatus); its last lines:"
    grep -v '^\[' "$work/scores.log" | tail -15 | sed "s|$private|the private folder|g"
    [ "$status" -eq 0 ] && status=3
  fi
fi

say ""
for v in "${verdicts[@]}"; do say "$v"; done
exit $status
