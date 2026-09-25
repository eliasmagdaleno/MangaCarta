# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

The primary user is an individual iPhone or iPad manga reader who wants to discover, organize, and read English-language manga across multiple sources. They also want to keep up with new chapter releases from their favorite manga.

## Product Purpose

MangaCarta provides a native reading loop for discovering manga, saving favorites, tracking reading progress, resuming where the reader stopped, and learning when saved titles receive new chapters. Success means readers can move from discovery to reading and return for new releases without manually reconciling titles and progress across sources.

## Positioning

The product unifies multiple chapter sources around source-independent Works while keeping source Listings available for fulfillment. Local reading history and library activity power personalized recommendations, and optional MyAnimeList integration can synchronize completed reading progress.

## Operating Context

- Readers browse personalized and source-specific feeds, search within a selected source, inspect a title, and read chapters in left-to-right, right-to-left, or continuous vertical modes.
- Readers save manga to an on-device library, use unread indicators to notice new chapters, and resume from reading history at the last recorded page.
- Readers may switch between registered content sources. Adult sources are hidden unless explicitly enabled in Settings.
- When more than one source carries the same manga, the product chooses one on the reader's behalf rather than asking, and explains which. Readers may name a primary source that settles otherwise-equal choices, or pin a single title to a single source, which holds until they change it. A source that cannot be counted is never treated as a source that carries nothing.
- MyAnimeList sign-in and reading-progress synchronization are optional.
- The Library refreshes in the background at a system-scheduled cadence and on foreground activation, and readers may opt in to notifications when saved manga receive new chapters. Newly discovered chapters are tracked separately from read state, so clearing the indication never marks anything read.
- Home is a deliberate blend: actionable personal updates take precedence when present, followed by personalized recommendations and then source-wide discovery feeds.

## Capabilities and Constraints

- Public-release native SwiftUI app targeting iOS 17.5 and later, with selected iOS 18 behavior.
- MangaDex and WeebCentral currently provide chapters through a shared, bridge-friendly source abstraction.
- Open question: App Store positioning now that the release ships no content Sources and local file import is its first-run purpose (ADR-0003 Amendment 6; local import spec forthcoming).
- Source-independent Work identity connects Listings, metadata, history signals, and recommendations without treating a provider identifier as the app's identity.
- Recommendations are derived from reading activity and metadata, with conservative entity resolution that prefers an omission over linking the wrong manga.
- Library state, reading history, and recommendation inputs are currently stored on-device. The intended public product may collect analytics by default to improve recommendations and understand feature usage, with a clear Settings toggle to opt out.
- The analytics provider, event schema, retention period, consent disclosure, regional compliance behavior, deletion/export controls, and whether historical events can train shared recommendation models remain open decisions. Future work must settle these before analytics ships.
- Adult sources and content remain opt-in.
- Release accessibility baseline: primary tasks must work with VoiceOver, text must support Dynamic Type and readable contrast, interactive targets must be at least 44 points, and meaningful motion must honor Reduce Motion. Deeper capabilities such as custom rotors, a dedicated Assistive Access layout, and comprehensive keyboard optimization may follow after the initial public release.
- No third-party runtime dependencies are currently used.

## Brand Commitments

- Product name: MangaCarta.
- Existing voice is concise, calm, and reader-focused.
- The established identity is called “Ink & Seal.” Its visual details belong in design-system documentation rather than this product record.
- MangaDex attribution is required, and the product must not claim affiliation with or endorsement by MangaDex.

## Evidence on Hand

- The working application implements Home, Library, History, Search, Settings, manga details, and the reader under `MangaCarta/`.
- Existing product and architecture documentation is in `README.md`, `CLAUDE.md`, `docs/glossary.md`, and numbered ADRs under `docs/adr/`.
- Shipped-feature specifications and implementation plans are under `docs/superpowers/`.
- Current light- and dark-mode screenshots are under `docs/screenshots/`.
- No testimonials, customer claims, adoption metrics, pricing, or App Store claims are established; future work must not fabricate them.

## Product Principles

1. Make the complete reading loop effortless: discover, save, read, resume, and notice new chapters.
2. Present one coherent manga identity even when chapters and metadata come from different services.
3. Personalize from real reading behavior while giving users clear control over data collection.
4. Prefer trustworthy omissions over incorrect title matches or misleading recommendations.
5. Keep optional integrations and adult content from disrupting the default reading experience.

## Accessibility & Inclusion

The initial public release requires readable contrast, Dynamic Type, 44-point interactive targets, VoiceOver-operable primary tasks, and respect for Reduce Motion. Custom rotors, a dedicated Assistive Access layout, and comprehensive keyboard optimization are desirable follow-up work rather than initial release gates.
