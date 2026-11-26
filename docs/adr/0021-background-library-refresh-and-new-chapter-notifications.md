# ADR-0021 — Background Library refresh and new-chapter notifications

- **Status:** Accepted (2026-08-24)
- **Amends:** none
- **Related:** ADR-0001 (Work vs Listing identity), ADR-0004 (fulfillment routing), ADR-0006
  (Library collections), ADR-0007 (Work shape and Listing keys), ADR-0010 (foreground/background
  lifecycle)

## Context

Keeping up with favorite manga is a primary product job, but the shipped path is manual. A saved
item persists one Listing id, its `sourceId`, and the chapter-number set from its last refresh
(`LibraryStore.swift:12-18`). `LibraryStore.refresh()` then ignores that `sourceId`, resolves
`SourceRegistry.shared.active` once, and asks that one Source for **every** saved id
(`LibraryStore.swift:270-289`). In a multi-source Library, the active browse filter can therefore be
asked for ids belonging to another Source. This is not a sound basis for background updates.

The identity model already has the seam the feature needs. A Work is source-independent and owns
all known Listing keys (`Work.swift:111-126`); a Listing key is the persisted `(sourceId, mangaId)`
pair (`Work.swift:21-35`); and every Source exposes its readable chapter list through
`chapters(mangaId:)` (`MangaSource.swift:17-24`, `:46-51`). Notification discovery therefore belongs
at the Work boundary, while each network query remains Listing-specific.

**Facts verified live 2026-08-24 (do not re-derive):** the target declares iPhone and iPad support,
but the repository contains no BackgroundTasks registration/permitted-identifier configuration, no
background-fetch or remote-notification mode, no notification entitlement, and no
`UNUserNotificationCenter`/`BGTaskScheduler` implementation. The app's existing scene lifecycle
starts foreground services on `.active` and stops or flushes them on `.background`
(`Manga_ReaderApp.swift:132-159`); it does not refresh the Library on either transition.

Apple documents `BGAppRefreshTask` as a short content-refresh opportunity whose launch time the
system chooses, with up to roughly 30 seconds of runtime. A requested earliest date is not a
schedule or a delivery guarantee. Notification authorization can change outside the app and must be
read before scheduling. These constraints make “twice every day” an intention, not an honest
promise.

## Decisions

### Phase one is device-only, best-effort refresh plus local notifications

The first release requests `BGAppRefreshTask` opportunities up to a few times per day, refreshes on
app activation, and retains manual pull-to-refresh. A successful background discovery schedules a
local notification. The UI and product copy make no exact cadence or delivery-time promise.

A server that polls Sources and sends APNs notifications was rejected for phase one. It is the route
to timely, dependable delivery, but it adds hosted infrastructure, operating cost, source-abuse and
rate-limit responsibility, account/device-token lifecycle, and a materially larger privacy surface
before usage has established that immediacy pays for them. Repeated timers or attempts to force two
daily executions were rejected because iOS does not grant that contract.

**Accepted cost:** a release may be discovered many hours late, or only when the app next becomes
active. A user who force-quits the app, disables Background App Refresh, rarely launches it, or is
consistently denied runtime may receive no background notification.

### Refresh and event identity are Work-level; network checks remain Listing-specific

For each saved Work, refresh checks eligible linked Listings through the Source named in each
`ListingKey`. One successful trusted Listing can advance the Work's observed chapter frontier even
when another Listing fails. A failed or Cloudflare-blocked Listing is **unknown**, never evidence of
no change. If every Listing fails, no event is emitted; the app records a stale/error state for a
foreground retry, where an interactive challenge can be shown.

Emitting per Listing was rejected because the same release could produce duplicate notifications
and would make the globally active browse Source accidentally define personal update truth. Checking
only a preferred Listing was rejected because another trusted Listing may publish first and the
Work model already exists to join that availability.

**Accepted cost:** the exact cross-source chapter-equivalence algorithm remains an implementation
decision. It must preserve the Work-level rule and must not treat one Source's relabeling or
late-arriving older chapter as multiple releases.

### The first successful observation establishes a baseline and emits nothing

The first successful refresh after a Work is saved persists its notification baseline. Only a later
frontier advance emits a new-chapter event. Removing the Work from Library deletes that notification
state and cancels its pending notifications; re-adding it establishes a fresh baseline. Muting keeps
the baseline and background/in-app update state while suppressing notification delivery; unmuting
alerts only for later events.

Treating every chapter observed on first refresh as new was rejected because saving an established
100-chapter manga would immediately produce a false alert. Keeping notification state after removal
was rejected because removal is the clearest available withdrawal of interest and stale state would
make re-adding behavior surprising.

### One Work produces one notification per refresh, and opening it never skips chapters

When one refresh discovers several chapters for a Work, it schedules one title-level notification
such as “3 new chapters of Dandadan.” Notifications for several Works use one iOS grouping
identifier. Opening a notification routes to the Work's chapter list with newly discovered chapters
emphasized; it never opens the newest chapter directly.

One alert per chapter was rejected as noisy, especially after a source catches up in a batch.
Opening the newest chapter was rejected because notification interaction is not evidence that the
reader wants to skip earlier unread chapters.

**`newly discovered` and `unread` are separate state.** Viewing the chapter list may clear the
former. Only completing or manually marking a chapter clears the latter. Reusing `isRead` for
notification acknowledgement was rejected because `isRead` has the stricter meaning pinned in the
repository: read to the end or manually marked.

### Notification permission is contextual, and Updates work without it

After the first save, the app explains the benefit before requesting notification authorization.
It does not repeatedly prompt after denial. Settings displays both the in-app Updates state and the
current system authorization; when authorization is unavailable it offers an Open System Settings
action. Saving follows a title by default once authorization exists, with a global notification
toggle and per-Work mute.

Requesting at first launch was rejected because the user has not yet created anything worth
following. Treating denial as disabling refresh was rejected because in-app Updates are valuable
without lock-screen delivery and authorization may change outside the app.

Adult titles use generic lock-screen copy — “A followed title has new chapters” — unless the user
separately enables adult-title details. Suppressing adult notifications entirely was rejected
because privacy can be preserved without silently disabling the feature. Showing title or cover by
default was rejected because the lock screen is a shared surface.

### Background work is bounded, resumable, and fair to the whole Library

The scheduler persists a cursor and processes a bounded priority queue:

1. ongoing Works overdue for a check;
2. recently read or favorited Works;
3. every remaining saved Work in round-robin order.

Each run installs cancellation for the system expiration signal, persists progress before
completion, and resumes later rather than restarting at the first title. App activation uses the
same source-aware refresh pipeline and heals skipped or failed work.

Refreshing the entire Library on every opportunity was rejected because the background window is
short and a large Library would be terminated mid-pass. Always sorting by engagement without a
round-robin tail was rejected because low-engagement saved Works could starve forever. Pure
round-robin was rejected because an actively read ongoing series is more likely to provide value
than a dormant completed one.

**Accepted cost:** low-priority Works may be checked less often than the requested cadence, and the
queue requires its own small persisted scheduling record. Fair eventual coverage wins over a false
uniform-frequency promise.

## Hazards

- Chapter numbers are strings today (`LibraryItem.chapterNumbers`), and sources can publish
  decimals, specials, renumberings, removals, or late translations. A set growing is not by itself
  proof that the publication frontier advanced; the implementation needs explicit fixtures for
  these cases before it can notify.
- `Work.listings` may be incomplete until entity resolution succeeds. A saved Listing remains the
  minimum refreshable unit; adding a newly linked Listing must not replay its entire catalog as new.
- A background WebView cannot complete an interactive Cloudflare challenge. Repeatedly attempting a
  blocked source would waste the limited window, so failure state needs backoff as well as the
  foreground recovery path.
- Local notifications are device-local. Without sync, two devices can hold different baselines and
  alert at different times.
- “Recently read or favorited” must reuse existing engagement and Library facts; it must not create
  a second conflicting definition of engagement solely for scheduling.

## Revisit triggers

- Users demonstrate that best-effort delivery is too late or unreliable, or product requirements
  introduce a concrete freshness SLA: evaluate a server poller plus APNs and write a new ADR for its
  privacy, abuse, and operations model.
- Background runs regularly expire before meaningful coverage, or source rate limits reject the
  planned cadence: revisit queue size, per-source backoff, and freshness targets using measured
  device data.
- Cross-source chapter fixtures show that one scalar frontier cannot distinguish releases from
  relabeling or backfill: replace the frontier representation without changing Work-level event
  identity.
- Cross-device sync ships: decide which device or service owns the notification baseline and how to
  deduplicate delivery across devices.

## Amendment 1 — a notification opens Updates, focused on its Work (2026-11-26)

The original text above stands in full except for where opening a notification lands. Where
"One Work produces one notification per refresh" says opening a notification "routes to the Work's
chapter list", read: **opening a notification opens the Updates screen, focused on that Work.** It
still never opens a chapter, newest or otherwise.

### What prompted it

The Updates screen ([spec](../superpowers/specs/2026-11-09-updates-screen-design.md)) became the
Library's inbox for newly discovered chapters, grouped by day and Work, with per-Work and
screen-level "Mark seen". The owner decided where a notification should land (spec, "Owner
decisions", 2026-11-09, decision 2): on Updates, focused on the Work, and the reader then chooses
the detail page or a chapter. That keeps this ADR's reason for never opening the newest chapter
(tapping a notification is not evidence the reader wants to skip earlier unread chapters) and
gives every update surface one destination.

### What it changes

- A tap selects the Library tab and pushes Updates with the notified Work scrolled into view,
  outlined, labelled "From your notification", and given VoiceOver focus. If the Work is no longer
  in the inbox, Updates opens at the top as usual.
- Arriving on Updates does not clear `newly discovered`; only "Mark seen", "Mark all seen" or the
  chapter list's existing clearing hooks do (spec owner decision 1). `newly discovered` and
  `unread` stay separate state, as above.
