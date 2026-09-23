#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
out="$root/MangaCartaTests/Fixtures"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out" "$tmp/pages"
for page in 2 10; do
    printf '\377\330\377' > "$tmp/pages/$page.jpg"
    dd if=/dev/zero bs=64 count=1 >> "$tmp/pages/$page.jpg" 2>/dev/null
done
rm -f "$out/deflated.cbz" "$out/stored.zip"
(cd "$tmp" && zip -q -9 -r "$out/deflated.cbz" pages)
(cd "$tmp" && zip -q -0 -r "$out/stored.zip" pages)
