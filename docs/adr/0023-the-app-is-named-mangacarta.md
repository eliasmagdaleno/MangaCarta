# ADR-0023 — The app is named MangaCarta, and the bundle identifier is not renamed with it

- **Status:** Accepted (2026-09-03)
- **Related:** ADR-0003, ADR-0021

## Context

`Manga-Reader` was a placeholder. It was the Xcode template's name, and it survived 782 tests,
22 ADRs, a shipped background-refresh subsystem, and a finished Host API contract without anyone
deciding it was the name. The product name is now **MangaCarta**.

The timing is the substantive part of this decision. Phases 3–5 mint the app's first *durable
external artifacts*: a JavaScript Host API that third-party extension authors write against, an
extension bundle format, and a repository manifest schema. Those are published interfaces. They
acquire a name at birth and keep it, and renaming them afterwards is a migration imposed on
people outside this repository rather than an afternoon inside it. Renaming before the runtime
exists costs one pull request; renaming after Phase 4 costs a compatibility story.

The rename is therefore sequenced *ahead* of Phase 3 rather than into launch prep, where a
bundle-identifier change would otherwise collide with App Store submission — the single worst
moment to alter an app's identity.

## Decision

**The product, target, scheme, Swift module, on-disk directories, and GitHub repository are all
named `MangaCarta`.** The Swift module loses its underscore (`Manga_Reader` → `MangaCarta`),
because the new name contains no hyphen for Xcode to substitute.

**The bundle identifier stays `Elias-Magdaleno.Manga-Reader`, and so does everything derived from
it.** Specifically frozen:

- `PRODUCT_BUNDLE_IDENTIFIER` on all three targets.
- The background-refresh task identifier `Elias-Magdaleno.Manga-Reader.libraryRefresh`, which
  appears in both `UpdateScheduler` and `Info.plist`'s `BGTaskSchedulerPermittedIdentifiers`.
- The `mangareader://oauth/mal` URL scheme.
- `MALCredentialStore`'s Keychain service, which derives from `Bundle.main.bundleIdentifier` and
  so follows the frozen identifier without a literal of its own.

## Consequences

The bundle identifier is the key to the app's data container, and the store filenames beneath it
(`works.json`, `updates.json`, `mal-progress-outbox.json`, `upgrade-attempts.json`, every cache)
carry no app name of their own. Changing the identifier would therefore not *rename* the library —
it would orphan it, iOS treating the result as a different app. It would also make existing
MyAnimeList OAuth tokens unreadable in the Keychain, silently signing the reader out with no
migration path, and it would break the `mangareader://` redirect that is registered server-side
with MyAnimeList and cannot be changed by shipping a binary.

Freezing it costs nothing a reader can observe. **A bundle identifier is never user-visible** —
not on the home screen, not in the App Store listing, not in Settings. The inconsistency lives
only in code, and this document is what keeps it from reading as an oversight to whoever finds it
next.

The BGTask identifier deserves separate emphasis because its failure mode is not cosmetic: the
string in `UpdateScheduler` and the one in `Info.plist` must match exactly, or
`BGTaskScheduler.register` throws at launch. That is a startup crash, not a degraded feature.
Freezing both together is what keeps them in lockstep.

Two things follow that are worth stating so they are not rediscovered:

- **`docs/adr/` and `docs/superpowers/handoff/archive/` were not rewritten.** ADRs are dated
  decision records that freeze by convention — amended, never corrected — and archived handoffs
  are historical records explicitly never to be worked from. Rewriting either would be editing
  history to say something it did not say. Old documents naming `Manga-Reader` are correct about
  the moment they describe; this ADR is the pointer that explains them.
- **The SwiftLint `type_name` rule was re-enabled.** It had been disabled with the comment that
  "Xcode's target names are forced to underscores… unavoidable" — true of `Manga_ReaderApp` and
  false the moment the hyphen left the product name. It now passes across all 150 linted files.

The GitHub repository was renamed too; GitHub redirects the old URL, so existing clones and links
continue to resolve.

## Amendment 1 — the name is kept knowing registration 3418240 exists (2026-09-30)

The decision above stands. This records the decision #150 asked for.

A direct USPTO search on 2026-09-30 found no mark containing `MangaCarta`, but a **live
MAGNACARTA registration, 3418240, owned by Bandai Namco Entertainment**, whose surviving classes
(009 and 041) cover game software and electronic books and publications about games and animated
stories. The search record and its risk analysis are owned by
`docs/superpowers/research/2026-09-11-issue-150-mangacarta-name-clearance.md` (2026-09-30 addendum).

**The owner keeps the name.** They judge the confusion risk low — different meaning, a content-free
reader rather than a game or publication, and no conflicting mark on `MangaCarta` itself — and chose
not to commission a professional clearance opinion. This is a conscious risk decision, not a
clearance or a registration, and should not be described as either.

What would reopen it: an objection from the registrant, an App Store name dispute, or a decision to
register MangaCarta as a mark (which would put the examiner's view of 3418240 on record).
