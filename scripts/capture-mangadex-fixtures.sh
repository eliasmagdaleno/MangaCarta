#!/bin/sh
# Re-captures the MangaDex JSON the engine tests run against. Manual only — CI never
# touches the network. Trim `limit` so fixtures stay small; then hand-edit only where a
# test says it needs an edge case, and say so in that test.
set -eu
API=https://api.mangadex.org
OUT="$(dirname "$0")/../MangaCartaTests/__Fixtures__/mangadex/api"
UA="MangaCarta-iOS/1.0 (fixture capture)"
mkdir -p "$OUT"
get() { curl -sf -A "$UA" "$API$1" | jq . > "$OUT/$2"; sleep 1; }

get "/manga?title=Yotsuba&includes%5B%5D=cover_art&limit=5&offset=0" search-yotsuba.json
get "/manga?order%5Brating%5D=desc&includes%5B%5D=cover_art&limit=5&offset=0" popular.json
get "/manga?order%5BcreatedAt%5D=desc&includes%5B%5D=cover_art&limit=5&offset=0" new-titles.json

MANGA_ID="${MANGA_ID:-$(jq -r '[.data[] | select(.attributes.links.mal != null)][0].id' "$OUT/search-yotsuba.json")}"
echo "MANGA_ID=$MANGA_ID"
get "/manga/$MANGA_ID?includes%5B%5D=author&includes%5B%5D=artist" detail.json
get "/manga/$MANGA_ID?includes%5B%5D=cover_art" listing.json
get "/chapter?manga=$MANGA_ID&translatedLanguage%5B%5D=en&order%5Bchapter%5D=asc&includes%5B%5D=scanlation_group&limit=100&offset=0" chapters-0.json
CHAPTER_ID="${CHAPTER_ID:-$(jq -r '.data[0].id' "$OUT/chapters-0.json")}"
echo "CHAPTER_ID=$CHAPTER_ID"
get "/at-home/server/$CHAPTER_ID" at-home.json
get "/chapter?translatedLanguage%5B%5D=en&order%5BreadableAt%5D=desc&includes%5B%5D=manga&limit=40&offset=0" latest-chapters.json
get "/manga/tag" tags.json
