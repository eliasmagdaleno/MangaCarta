# ADR-0012 — Reader failure states and chapter-advance commit

- **Status:** Accepted (2026-07-29); **amended by ADR-0013 (2026-07-29)** — the landing-page seam,
  settled in the view model's favour, plus the four protections load-then-commit removed by accident
- **Related:** ADR-0008 (transient vs permanent, in the upgrade queue), ADR-0013 (the view layer)

## Context

Opening a chapter whose pages cannot be fetched traps the user in the reader with no way out
except force-quitting the app. Reported from the field 2026-07-29 and reproduced against the code.

The trap needs three independently reasonable decisions to line up, and they do:

1. When `errorMessage` is non-nil the body renders **only** `errorState(...)`
   (`ReaderView.swift:104`) — an `InkNotice` and a Retry button (`ReaderView.swift:169-189`).
   Nothing else.
2. The dismiss control lives in `topBar`, gated behind `if showChrome` (`ReaderView.swift:113`),
   and `showChrome` initialises to `false` (`ReaderView.swift:78`). The only things that toggle it
   are tap handlers **inside** `content` — `ZoomablePage`'s `onTap` (`ReaderView.swift:408`) and the
   vertical reader's `.onTapGesture` (`ReaderView.swift:279`) — neither of which is rendered in the
   error branch.
3. `.toolbar(.hidden, for: .navigationBar)` (`ReaderView.swift:121`) removes the back button, and
   every call site pushes the reader with a plain `NavigationLink` (`ChapterListView.swift:33`,
   `MangaDetailView.swift:218`, `MangaDetailView.swift:410`, `HistoryView.swift:65`), so hiding the
   bar takes the interactive swipe-back with it.

The exit is reachable only through the view that failure prevents from rendering. No single one of
those three is wrong; nothing forced them to agree.

**Facts verified live 2026-07-29 (do not re-derive):**

- `GET /at-home/server/{chapterId}` answers **404 `not_found_http_exception`** for a chapter id that
  is not there (probed with a nil UUID and with a malformed id; both 404). Surfaced today as
  *"Request failed with HTTP status 404."* (`MangaDexAPI.swift:349`) — next to a Retry button that
  can never succeed.
- **Both sources can return an empty page list without throwing.** MangaDex `compactMap`s the
  at-home file arrays (`MangaDexAPI.swift:591`); WeebCentral `compactMap`s its extraction output
  (`WeebCentralSource.swift:87`). An empty array or uniformly malformed URLs yields `[]`, no error.
- **`ReaderView.swift:380` is the only production consumer of `pageURLs`.** All fourteen
  `MangaSource` test mocks stub it as `[]`.
- **The queue already has a policy for this.** `permanentStatus(of:)`
  (`MetadataUpgradeQueue.swift:259-267`) classifies `400..<500` except `429` as permanent and returns
  `nil` — transient — for unrecognised error types.

The reader is also the one screen that never got a view model: `HomeViewModel`,
`MangaDetailViewModel`, `SearchViewModel` and `MoreLikeThisViewModel` exist, and
`ReaderView.swift:128` / `ReaderView.swift:380` are the only places in `Views/` that await the
network directly. That is not a deliberate exception — it is the screen that predates the pattern,
and it is why none of the behaviour below is testable where it currently lives.

## Decisions

### The escape hatch belongs to the reader, not to any one state

Chrome visibility is **derived**, not assigned:

```swift
private var chromeVisible: Bool { showChrome || pages.isEmpty }
```

`showChrome` remains the user's toggle for the reading path; `pages.isEmpty` forces the bar visible
whenever there is nothing to read. Both overlays (`ReaderView.swift:113`, `ReaderView.swift:116`)
and `.statusBarHidden` (`ReaderView.swift:120`) read the derived value.

Adding a Close button to `errorState` was rejected because it fixes one instance of a class that
already has three members. The loading branch (`ReaderView.swift:106`) has no exit either — a hung
`pageURLs` strands the user for URLSession's 60s default. And a chapter that returns zero pages
*without* throwing falls through to `content` (`ReaderView.swift:109`), where `pageOrder`
(`ReaderView.swift:247`) computes `0..<0` with no adjacent chapters: an empty `TabView`, no error
text, no tap target, no chrome. Patching the error branch leaves both live.

Deriving rather than assigning is the load-bearing half. Setting `showChrome = true` inside the
`catch` would work today and would impose bookkeeping forever: unset it on successful retry, and
remember to set it in every state added to that branch later. The derived form makes the invariant
*unrepresentable to violate* rather than merely satisfied.

**Accepted cost: the top bar flashes on every normal chapter open,** because `pages` is empty until
the fetch returns. Gating on `errorMessage != nil || (!isLoading && pages.isEmpty)` would avoid the
flash and was rejected: it re-strands a hung load, which is the case with the longest exposure and
the least feedback.

### Failures classify transient vs permanent; unknown is transient

Permanent failures offer Close and no Retry. Transient failures keep Retry as the primary action.
Classification lives behind a small protocol both `MangaDexError` and `SourceError` conform to,
because the reader sees errors through `MangaSource` and cannot switch on one source's error type.

This is the second subsystem to adopt the rule, and it adopts it for the same reason the first did.
ADR-0008 recorded transient failures as nothing so an outage could not poison the memory; PR #29
then found the converse — treating a *permanent* answer as transient livelocked the queue, replaying
three over-long titles every 60s forever. Retry-on-a-404 is that bug with a human holding the timer.
Leaving the reader alone would leave the codebase holding two contradictory beliefs about what a 4xx
means.

**Unknown errors default to transient**, matching `permanentStatus`'s `default: return nil`. The
asymmetry decides it: wrongly offering Retry on a permanent failure costs a wasted tap, while
wrongly withholding it from a transient one strands a user whose wifi blipped. A bridged
dynamic-extension source (ADR-0003) cannot conform to a Swift protocol and therefore lands in this
bucket by construction, which is the correct default for a source we know nothing about.

**This diverges from `permanentStatus` on one code: 408 is treated as transient here.** The queue
excludes only 429. HTTP 408 is a timeout and genuinely transient; the queue's omission has never
mattered because neither MAL nor AniList emits it, whereas the reader talks to an image CDN. The
divergence is deliberate and small, and the queue should probably adopt it — see revisit triggers.

**Accepted cost: the reader now holds an opinion about HTTP semantics that must stay in step with
each source's error type.** A source returning 404 to mean "rate limited, come back later" would be
misclassified as permanent. No such source exists here.

### Zero pages is a permanent failure, decided in the model rather than thrown by the sources

A load that succeeds and yields no pages sets an error message and classifies permanent.

Throwing `SourceError.extractionFailed` from each source on an empty list is the better domain
modelling — "a chapter with no pages" is a fact about the source, not about the reader — and it lost
on blast radius. `ReaderView.swift:380` is the only consumer, so pushing it down buys no other caller
anything today, costs an edit to both sources and their tests, and changes the meaning of fourteen
mocks that return `[]` as an inert stub.

Permanent is right for both reachable causes: MangaDex registering a chapter with no images, and a
WeebCentral extraction script that stopped matching after a site redesign (which CLAUDE.md names as
the volatile part of that source). Neither is fixed by pressing a button.

> **Amended 2026-07-29, while hand-checking the fix.** There is a third cause and it is the dominant
> one: **every externally hosted MangaDex chapter takes this path.** They answer `/at-home/server`
> with 200 and an empty file list, so `compactMap` yields `[]` and this decision is what catches them.
> That makes the empty-page case routine rather than the edge case argued above — which strengthens
> the decision to handle it at all, and makes the "blast radius" argument for keeping it in the model
> rather than throwing from the sources the *only* remaining reason it lives here.

After the chrome decision above this is no longer a trap — an empty page list already forces the bar
visible. It is an honesty fix. A blank black screen tells the user their app is broken; a sentence
tells them the chapter is.

**Accepted cost: the message cannot distinguish "MangaDex has no images for this chapter" from "our
scraper broke."** To the user those read identically and only the second is our defect. Separating
them requires the sources to throw distinctly, which is the change rejected above.

> **Amended 2026-07-29.** Make that three cases, the third being "this chapter is published on the
> publisher's own site" — see above. That one is not a failure at all, and telling the user their
> chapter has no pages is actively misleading about it. It is also the only one of the three the
> *chapter list* could rule out before the reader is ever opened; see revisit triggers.

### Chapter advance is load-then-commit

`loadNextChapter` and `loadPreviousChapter` fetch into a local and assign `currentChapter`, `pages`
and the progress counters **only on success**. A failure mutates nothing.

Today they mutate first and load second — `currentChapter = next`, `pages = []`, counters reset,
then `await loadAndBegin()` (`ReaderView.swift:147-156`). One 404 chapter in the middle of a series
therefore destroys the chapter the user was reading, and with the fixes above their only remaining
action is Close, which ejects them from the series entirely. The damage is purely navigational —
`loadAndBegin` guards `!pages.isEmpty` (`ReaderView.swift:135`), so `advanceProgress` never fires and
history keeps the real position — but the user has to re-enter through the detail view.

Offering a "Back to Chapter N" button instead was rejected. It is cheaper, and it needs no new state
to find the target (after `currentChapter = next`, the existing computed `previousChapter` at
`ReaderView.swift:91` *is* the chapter just left), but it recovers from a state that should not be
entered rather than not entering it. The general rule — never tear down valid state for a replacement
that may not arrive — is the one worth writing down, because `assign then load` reads perfectly
natural and will be "simplified" back without a record.

### A full-screen error only when there is nothing to read

The body condition becomes "error takes the screen only if the screen is otherwise empty":

```swift
if let errorMessage, pages.isEmpty { errorState(errorMessage) }
else if isLoading, pages.isEmpty   { loadingState }
else                               { content }   // with a banner when errorMessage != nil
```

This is forced by load-then-commit. `if let errorMessage` currently wins over `content`
unconditionally (`ReaderView.swift:104`), so an error raised while the previous chapter is still
loaded would blank out a perfectly readable chapter — the precise opposite of the intent. The failed
advance surfaces as a dismissible banner over the content the user keeps.

**Accepted cost: a new transient error affordance.** `InkNotice` is a block element, not an overlay,
so the banner is new UI rather than a reuse.

### `ReaderPresentation` is a pure value type, and the reader gets a view model

The state→presentation decision moves into an `Equatable` value type constructed from
`(errorMessage, isTransient, isLoading, pageCount)`, exposing a body case and a `chromeForced` flag.
`ReaderView` renders it and holds no branching logic. Chapter loading moves into a `@MainActor`
`ReaderViewModel` with an injected `MangaSource`; `showChrome`, `currentPage`, `mode` and history
progress stay in the view, since they are UI state driven by the pager.

The seam is chosen to make the violated invariant statable in one line:

> for every input where `pageCount == 0`, `chromeForced` is true.

That holds for states nobody has thought of yet, which is what the shipped code lacked — "which body
do we show" and "can the user leave" were independent decisions scattered across
`ReaderView.swift:104-119` with nothing forcing agreement.

A UI test as the primary gate was rejected. The UI tests hit live MangaDex, are not in CI, and a
single red one is explicitly no signal; reproducing a 404 through the real UI also means depending
on some chapter id staying permanently dead, where the pure type takes the 404 as an argument.
The view model is what makes load-then-commit assertable at all — its whole value is "on failure,
nothing was mutated", and that can only be checked by driving a failing source and inspecting state
afterwards.

**Accepted cost: the landing-page calculation straddles the split.** `loadAndBegin` reads
`initialPage` / `startPageRequest` and writes `currentPage` (`ReaderView.swift:137-144`). The
decision depends on `pages.count` so it belongs in the view model, but the value it produces is UI
state — a seam judgement that may need a second pass.

> **Amended by ADR-0013.** That second pass happened the same day, and the seam lands in the view
> model: `landingPage` becomes `pagerTarget`, meaning *where the pager belongs* rather than where a
> successful load landed, and it is written on the failure path too. The view keeps `currentPage`
> because the pager mutates it on every swipe. ADR-0013 also records that this decision removed four
> protections that were holding only because `pages` was cleared before the await — the pager index
> could not be stranded, re-entry was impossible, the loading spinner appeared for free, and the
> progress counters were reset by whoever changed the chapter.

**Verification of dismissal itself stays manual.** `chromeForced == true` proves the top bar renders;
it does not prove `dismiss()` escapes a `NavigationLink` push with a hidden navigation bar. That is
hand-checked on the iPhone 17 simulator.

## Hazards

- **The 404 the user hit may not mean what we assume.** MangaDex returns 404 from `/at-home/server`
  for a chapter that is externally hosted as well as for one that does not exist, and `Chapter`
  decodes neither `externalUrl` nor a page count (`MangaDexAPI.swift:125-131`, `:156-167`). So the
  reader cannot tell "read this elsewhere" from "this is gone", and tells the user the same thing for
  both.

  > **Corrected 2026-07-29, while hand-checking the fix.** The 404 claim is wrong. An externally
  > hosted chapter answers **HTTP 200 with an empty file list** — real `baseUrl`, `data: []`,
  > `dataSaver: []` (probed against four of them). Only a chapter id that genuinely is not there
  > 404s, which is the pinned fact above and still holds.
  >
  > The hazard survives, by a different route: external chapters reach the user through the
  > **zero-pages** decision below rather than through the HTTP path, so they read *"This chapter has
  > no pages to read."* Both classify permanent, so behaviour is unaffected — but "read this
  > elsewhere" is now conflated with "this is broken" rather than with "this is gone".
- **Nothing prevents *entering* the reader for an unreadable chapter.** This ADR makes the failure
  escapable and honest; it does not make the chapter list know which rows are dead.
- **`.task { await loadAndBegin() }` still has no cancellation story.** Moving the await behind an
  object makes that addressable rather than structurally absent, but it is not addressed here.

## Revisit triggers

- If a second consumer of `pageURLs` appears, revisit throwing on an empty page list from the
  sources — the argument for deciding it in the model rests entirely on there being one caller.
- **Externally hosted chapters are already common enough to matter** (corrected 2026-07-29 — they are
  routine, not rare). Route those rows away from the reader instead of into a permanent failure. This
  is cheaper than this ADR assumed: `externalUrl` need not be decoded at all, because such chapters
  report `pages: 0` in the chapter list and `ChapterAttributes` (`MangaDexAPI.swift:125-131`) simply
  does not decode `pages` yet. One field is enough to mark the row before anyone opens it.
- If the queue ever sees a 408, fold the carve-out above back into `permanentStatus` so the two
  subsystems share one definition rather than two that differ by a single code.

## Amendment 1 — extension Source failures classify too (2026-09-30, #315)

**Decision:** `ExtensionSourceError` conforms to `ClassifiedFailure`. Since ADR-0003 Amendment 6
every content Source is an installed extension, and its errors fell through to the
unknown-is-transient default, so the reader offered Retry for failures retrying cannot fix. The
"bridged extension lands in the default bucket by construction" premise above no longer holds: the
bridge ends in one Swift error type, which can classify.

The rule follows the Host API design's §6 retry guidance, per code:

- **Permanent** — `invalid_request`, `invalid_response`, `invalid_result`, `unsupported`,
  `unsupported_language`, `policy_denied`, `incompatible_version`, `script`. §6 says each clears
  only after a fix or a changed selection. `script` is "after Source fix/transient retry"; it is
  called permanent so Retry stays for failures that can clear on their own.
- **Transient** — `cancelled`, `network`, `navigation`, `timeout`, `rate_limited`,
  `interaction_required`, `interaction_declined`, `interaction_timed_out` (Retry re-presents the
  challenge, as for `SourceError.cloudflareUnsolved`), `storage`, `resource_limit`, plus a Source
  that is unavailable or a feed page out of sequence. `cancelled` reaching the reader is a host
  cancellation; the caller's own already becomes `CancellationError`.
- **`http`** — by status, which travels in `details.status` (Host API design, Amendment 7): 408,
  429 and 5xx transient, other 4xx permanent, no status transient. This is the rule above, which
  the deleted in-app MangaDex client had applied and no extension path had since.

Unknown errors still default to transient.
