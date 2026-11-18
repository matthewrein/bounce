#!/usr/bin/env bash
# Finds the Swift toolchain the hand-off tools build with, and installs it when there is none (ios/CaptureKit.md,
# "When the kit is uploaded"). Prints the folder that holds `swift` (and nothing else on stdout).
#
#   ios/tools/install-swift.sh
#
# Looks on PATH, then under /opt/swift-*/usr/bin and $SWIFT_HOME/swift-*/usr/bin (default ~/.swift). With none, on
# Linux (Ubuntu 24.04, x86_64, as in Claude's cloud sessions) it downloads Swift 6.1.2 from download.swift.org (878 MB,
# under a minute there), checks it against the SHA-256 pinned below (the tarball whose signature by the Swift 6.x
# release key was checked when it was pinned), and unpacks it into $SWIFT_HOME, where later runs find it. Elsewhere it
# says how to install Swift. Progress goes to stderr. Needs curl, tar and sha256sum.
set -euo pipefail

version=6.1.2
name="swift-$version-RELEASE-ubuntu24.04"
url="https://download.swift.org/swift-$version-release/ubuntu2404/swift-$version-RELEASE/$name.tar.gz"
sha256=d749d5fe2d6709ee988e96b16f02bca7b53304d09925e31063fd5ec56019de9f
home=${SWIFT_HOME:-$HOME/.swift}
manual="Install Swift $version (https://www.swift.org/install; on a Mac it comes with Xcode), then run this again."

if command -v swift >/dev/null 2>&1; then dirname "$(command -v swift)"; exit 0; fi
found=$(ls -d /opt/swift-*/usr/bin "$home"/swift-*/usr/bin 2>/dev/null | sort -V -r || true)
while IFS= read -r d; do
  [ -n "$d" ] && [ -x "$d/swift" ] && { printf '%s\n' "$d"; exit 0; }
done <<< "$found"

os_id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' || true)
os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"' || true)
if [ "$(uname -s)" != Linux ] || [ "$os_id" != ubuntu ] || [ "$os_version" != 24.04 ] || [ "$(uname -m)" != x86_64 ]; then
  echo "Swift is not installed (it builds the checker and the scorer), and this is not Ubuntu 24.04 on x86_64. $manual" >&2
  exit 1
fi
for t in curl tar sha256sum; do
  command -v "$t" >/dev/null || { echo "Swift is not installed, and $t (to install it) is not either. $manual" >&2; exit 1; }
done

mkdir -p "$home"
tmp=$(mktemp -d "$home/.download.XXXXXX")
trap 'rm -rf "${tmp:?}"' EXIT
echo "Swift is not installed: downloading Swift $version for Ubuntu 24.04 (878 MB) from download.swift.org ..." >&2
if ! curl -fsSL --retry 3 -o "$tmp/swift.tar.gz" "$url"; then
  echo "The download failed (download.swift.org must be reachable). $manual" >&2; exit 1
fi
if ! echo "$sha256  $tmp/swift.tar.gz" | sha256sum -c --status; then
  echo "The download does not match the SHA-256 pinned in install-swift.sh: not installed. $manual" >&2; exit 1
fi
echo "Unpacking it ..." >&2
tar -xzf "$tmp/swift.tar.gz" -C "$tmp"
[ -x "$tmp/$name/usr/bin/swift" ] || { echo "The download holds no swift. $manual" >&2; exit 1; }
rm -rf "${home:?}/$name"
mv "$tmp/$name" "$home/$name"
if ! "$home/$name/usr/bin/swift" --version >&2; then
  echo "Swift $version was unpacked but does not run (system libraries missing?). $manual" >&2; exit 1
fi
echo "Swift $version installed; later runs find it." >&2
printf '%s\n' "$home/$name/usr/bin"
