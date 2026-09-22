#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
out="$root/MangaCartaTests/Fixtures"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out" "$tmp/pages"
printf '\377\330\377' > "$tmp/pages/2.jpg"
printf '\377\330\377' > "$tmp/pages/10.jpg"
(cd "$tmp" && zip -q -r "$out/deflated.cbz" pages)
ditto -c -k --sequesterRsrc --keepParent "$tmp/pages" "$out/stored.zip"
