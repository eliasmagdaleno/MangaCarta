# ADR-0025 — The user's own files are a compiled Source, `local`

- **Status:** Accepted (2026-09-22)
- **Related:** ADR-0001, ADR-0003 (Amendment 6, [#215](https://github.com/eliasmagdaleno/MangaCarta/pull/215)), ADR-0021
- **Design:** [`docs/superpowers/specs/2026-09-22-local-import-design.md`](../superpowers/specs/2026-09-22-local-import-design.md)

## Context

ADR-0003 Amendment 6 ships the release build with no built-in or bundled content Source, which
leaves an App Store reviewer, and a first-time user, looking at an empty reader. The app needs a
purpose it has on install: reading the user's own CBZ, ZIP and PDF files imported through Files.

Everything the app does with a title — Library, History, read marks, the unread badge, Work
minting — is keyed on a Listing key `(sourceId, mangaId)`. The question was whether imported files
join that model as a Source or get a parallel path.

## Decision

Imported files are served by **`LocalSource`**: a compiled `MangaSource` with the stable id
**`local`**, always registered by `AppComposition` whatever else is installed. Each imported item
is a Listing of `local` whose `mangaId` is minted at import; importing mints a Work exactly as
opening a remote title does (ADR-0001).

- `local` is **not** a browse Source: it appears in Library only, never in the Home source picker.
- `local` Listings **never take part in update polling** (ADR-0021). The Source declares this; the
  refresh coordinator does not string-match the id.
- In v1 a local Work is **not matched** to MangaDex, AniList or MAL.

**Compatibility with ADR-0003 Amendment 6 (#215).** Amendment 6 forbids built-in *content*
Sources. `LocalSource` is not one: it has no catalog, reaches no network, and serves only files the
user chose to import. It carries no third-party content, so it is host functionality in the same
sense as the reader, not an exception to the amendment.

## Consequences

- Library, History, read state and the reader work for local items without a parallel path.
- `LocalSource` is compiled host code, not an Extension: it reads the app container, which the
  Host API deliberately cannot.
- `MangaSource` gains a declared "participates in updates" capability, defaulting to true.
- Matching local Works to external metadata, and a Komga/OPDS client, are future decisions.
