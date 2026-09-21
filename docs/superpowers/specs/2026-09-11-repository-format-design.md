# Phase 4 repository format design

**Date:** 2026-09-11
**Status:** Design specification. The two product questions it was written around — installed
adult Sources and signing — were answered by the user on 2026-09-11 and are resolved in §7 and §9.
**Evidence baseline:** repository commit `86557d7`, after Phase 3 closed (#162).

## Purpose and ownership

This document specifies what a repository serves, what the installer does with it, and what the
installer persists. It is the "bytes" half of Phase 4. The decisions and their reasoning — why
identity is minted rather than derived, who attests adult classification, why `reinstall` takes
what it takes, why signing is where it is — belong to
[ADR-0003 Amendment 4](../../adr/0003-extension-substrate.md#amendment-4--repository-identity-is-installer-minted-attestation-is-the-maintainers-and-a-typed-declaration-is-a-validated-one-2026-09-11).
A reader asking "why is it this way" goes there; a reader asking "what exactly must the bytes look
like" stays here. Nothing is stated in both.

The [Host API design](2026-09-02-host-api-design.md) is the merged contract this builds on and is
**not modified** by this document. Where a rule already lives there — the declaration record, the
version grammar, URL policy, the identity lifecycle, storage semantics — this document links to it
by section name and does not restate it. Glossary terms **Source**, **Extension**, **Listing**,
**Work**, **Host API**, **Pin**, and the two this phase adds, **Repository** and **Bundle**, are
used without redefinition.

## 1. What a repository is

A repository is **one JSON document at an HTTPS URL, plus the engine scripts it points at**. It is
served from a static host; nothing about the format requires the host to run code, negotiate
content, or know which app is fetching. This is the shape Paperback (`versioning.json`) and Aidoku
(`index.json`) both use, and it is deliberately the least the installer can work from.

The URL the reader types is the URL of the index document itself — the installer fetches exactly
what was typed and nothing is appended or guessed. Relative references inside the index resolve
against that URL by ordinary RFC 3986 base resolution, the way a page resolves a relative
`<script src>`. A URL that does not return a well-formed index fails with a sentence saying so;
there is no second path to try.

### 1.1 The units, and what each one is for

| Unit | Identity | Version | What it is |
|---|---|---|---|
| Repository | installer-minted (§5) | — (the index states its `format`, §3) | The index document and the trust decision the reader made by adding it. |
| Bundle | `id`, unique within the index | `version` | One engine script plus the declarations that select it. The unit of **fetch** and of **update**. |
| Source | `localId`, unique within the index | — | One declaration record. The unit the reader **installs**. |

A bundle is the S6 shape and nothing more: `HTMLSelectorThemeEngine` is one script and three
differently configured declarations, and that was everything Phase 3 needed to run a Source. The
reader installs Sources; the installer fetches bundles; the maintainer versions bundles. A Source
that is installed pulls its bundle's script in with it, and two installed Sources from one bundle
share one copy of that script.

## 2. The index document

```json
{
  "format": 1,
  "name": "Example Repository",
  "bundles": [
    {
      "id": "html-selector-theme",
      "version": 3,
      "script": "bundles/html-selector-theme/3/engine.js",
      "scriptSHA256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "sources": [
        {
          "localId": "weebcentral",
          "name": "WeebCentral",
          "engine": "htmlSelectorTheme",
          "adult": "none",
          "capabilities": { "search": true, "popular": true, "newTitles": true,
                            "latestUpdates": true, "detail": true, "chapters": true,
                            "pages": true, "webURL": true },
          "languages": { "mode": "fixed", "values": ["en"] },
          "network": { "browserOrigins": ["https://weebcentral.com"],
                       "assetOrigins": ["https://temp.compsci88.com",
                                        "https://scans.lastation.us"] },
          "presentation": {
            "feeds": {
              "popular":       { "eyebrow": "By popularity" },
              "latestUpdates": { "eyebrow": "New chapters" },
              "newTitles":     { "eyebrow": "Just added" }
            }
          },
          "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" },
          "configuration": { "…": "the engine's own vocabulary, elided" }
        }
      ]
    }
  ]
}
```

Every object in `sources` is a **Source declaration exactly as the Host API design's "Source
declaration" section defines it**, validated by `SourceDeclarationValidator` with no rule added
or relaxed. The `presentation.feeds` eyebrows shown are the compiled `WeebCentralSource`'s
`homeRailEyebrows`, carried as declaration data; the design's "Source-authored presentation"
section owns their semantics. Declarations are **inline** in the index, not fetched separately:
the declaration *is* the listing metadata — name, adult class, languages, capabilities, Host API
range — and a separate listing summary would be a second copy of those facts.

### 2.1 Index-level fields

| Key | Rule |
|---|---|
| `format` | Required. A JSON integer ≥ 1. The installer accepts exactly the formats it knows; this document defines **format 1**. See §3. |
| `name` | Required. Display text, not identity: trimmed, nonempty, at most 80 Unicode scalar values — the same bound the declaration's `name` has. |
| `bundles` | Required. An array; **may be empty** (a repository with nothing to offer is valid, and is how a maintainer retires one without breaking readers who have it added). |

### 2.2 Bundle fields

| Key | Rule |
|---|---|
| `id` | Required. Same grammar as `localId` (lowercase ASCII letters, digits, `-`, `.`, 1–64). Unique within the index. Stable across versions — it is how the installer knows a later index carries *the same* bundle at a newer version. |
| `version` | Required. A JSON safe integer ≥ 1. Strictly increasing across releases of the same bundle. An integer, not semver — Amendment 4's "Alternatives rejected" says why. |
| `script` | Required. A URL reference resolved against the index URL. The result must satisfy the design's "URL policy" (absolute HTTPS, no private destinations, redirects revalidated per hop). It need not share the index's origin. |
| `scriptSHA256` | Required. Exactly 64 lowercase hexadecimal characters: the SHA-256 of the script bytes as served. |
| `sources` | Required. A nonempty array of declaration records. |

**Recommended, not required:** an immutable script path per version, as in the example. With a
mutable path, a CDN that has cached the previous release serves old bytes under a new `version`;
the hash catches that and the update is refused rather than silently stale, but the reader sees a
refusal until the cache turns over. An immutable path never has that problem.

### 2.3 Unknown keys

Refused at every level of the index outside `configuration`, exactly as the declaration already
does — one rule a reader already knows, rather than one rule per document. The consequence is that
**every addition to the format is a new format number** (§3); there is no "additive minor" for
the index. That is a deliberate trade: the app's list of accepted formats only ever grows, so an
old repository keeps installing into every future app, and a new repository is refused by an old
app with a sentence rather than half-understood.

### 2.4 Considered and left out of format 1

Each is absent because nothing in the app consumes it. Adding any of them is a format bump, and
the reason to add it should be a consumer, not a comparison with another reader's manifest.

- **Icons** (per Source or repository). Nothing renders one — `SourceStamp` is text — and an
  image is a fetch from an origin that would need its own policy.
- **`description`, `author`, `website`** on the repository or the bundle. Display-only, and the
  repositories screen has a name and a URL to show.
- **A bundle `name`.** The reader sees Sources; a bundle surfaces only as "engine updated".
- **`engines`** — a declarative list of what a bundle registers, cross-checked against each
  declaration's `engine`. It would convert one maintainer error (a declaration naming an engine
  the script does not register) from a first-use failure into an install-time refusal, but the
  runtime must verify it at invocation anyway, so the list could only ever add refusals, not
  remove a failure. Left out; the runtime's "the bundle registers no engine named X" is the check.
- **`movedTo`** — a forwarding pointer for repositories that move. See §5.3 for what a move is in
  format 1 and why an HTTP redirect covers it.
- **`buildTime` / `updatedAt`.** `version` is the only update trigger.
- **A version display string** (`"1.2.0"`) next to the integer. The app shows "version 3".

## 3. Three version numbers, and which is which

| Number | Where | Grammar | Versions | Bumped when |
|---|---|---|---|---|
| `format` | index root | integer | the **document** the installer reads | this specification changes shape |
| `version` | per bundle | integer | the **maintainer's release** of a bundle | the maintainer ships new bytes |
| `hostAPI` | per declaration | `MAJOR.MINOR` range | the **runtime contract** an engine is written against | the Host API design changes |

They are independent. A format-1 index may carry declarations for Host API 2.x once that exists; a
format-2 index may carry Host API 1.x engines. A bundle's `version` says nothing about either. The
grammars differ on purpose — an integer cannot be mistaken for `1.0` — because two axes that look
alike get confused for each other, and a reader who sees `"format": "1.0"` would be right to ask
which one it is.

The `hostAPI` range's grammar, comparison and refusal rules are owned by the design's "Versions
and feature negotiation" section and the inline amendment there that fixed the grammar (the
design's own Amendment 3, not ADR-0003's). Nothing here changes them; the installer's
only contribution is *when* it applies them (§6.2).

## 4. Index validation

Validation of the index executes no Extension code, the same invariant the declaration validator
holds (acceptance criterion 2 of the Host API design). Every rejection carries the key path of the
offending value, in the style of `SourceDeclarationError`.

Two tiers, because they fail differently:

**Index-level failures reject the whole index.** Malformed JSON; a non-object root; a missing or
wrong-typed required key; an unknown key; an unknown `format`; a bundle `id` that fails its grammar
or repeats; a `version` that is not a safe positive integer; a `script` that does not resolve to a
policy-valid URL; a malformed `scriptSHA256`; an empty `sources`; and **a `localId` that appears
more than once anywhere in the index** — across bundles, not merely within one — because a
repository that lists one `localId` twice has made its own identity ambiguous. The rejection names
both occurrences.

**Declaration-level failures reject that declaration and nothing else.** Each record in `sources`
goes through `SourceDeclarationValidator.validate(json:qualifiedId:)` with the qualified id minted
per §5.2. A record it refuses is reported with the validator's own error, is shown in the
repository's listing as not installable with that reason, and does not affect its neighbours. The
case that forces this tier is `incompatibleHostAPI`: a repository that serves one Source built for
a newer app must not thereby hide every Source the current app can run.

An index that passes yields, per bundle, the typed bundle metadata plus, per declaration, either a
validated `SourceDeclaration` or a located rejection.

## 5. Repository identity

The reasoning is ADR-0003 Amendment 4's; this section is the mechanics.

### 5.1 Minting

When the reader adds a repository, the installer mints a **version 4 UUID** for it and persists it
in the repository record (§8) alongside the index URL. That UUID is the repository's identity for
as long as the record exists. It is never derived from the URL, the index contents, or anything a
maintainer controls.

### 5.2 The qualified Source id

`QualifiedSourceID.rawValue` is the repository UUID in lowercase hyphenated form, a single `:`,
then the declaration's `localId`:

```text
6f1d9c2e-4b7a-4c1e-9e3d-2a8b5c7d1f00:weebcentral
```

This is the encoding the Host API design's "Identity lifecycle" section left private to the host,
and it stays private in the sense that matters: **the installer's minting function is the only
producer, and nothing anywhere may split one.** It is written down here so that S3's tests are
deterministic and so that the WebKit store identifier derived from it (ADR-0003 Amendment 3's
version-5 UUID over the qualified id) is stable forever — which it must be, because changing the
encoding orphans every reader's browser clearance. A built-in source id (`mangadex`,
`weebcentral`) contains no UUID and no colon, so the two id spaces cannot collide.

### 5.3 What keeps an identity, and what makes a new one

| The reader does | Identity | Why |
|---|---|---|
| Adds a URL | new UUID | It is a repository the app has not seen. |
| Changes the URL of an existing repository ("Change repository URL") | **same** UUID | A move. The reader said so by choosing this gesture over "Add". |
| Follows a permanent redirect (301/308) on an index fetch | same UUID, **after confirmation** | The host said it moved; the reader confirms the new URL is theirs to trust. Until confirmed, the stored URL is unchanged and the redirected index is not applied. |
| Adds a second URL that serves the same `localId`s | new UUID | A fork, until the reader says otherwise by using "Change repository URL" instead. |
| Re-adds a URL matching a **removed** repository's record | same UUID, by default | Almost always a change of mind, not a replacement. The alternative, "add as new", is offered. |
| Removes a repository *and erases its data* | record gone; a later add is new | The reader asked for the identity to end. |

A URL cannot distinguish a move from a replacement. The reader's gesture can, and in format 1 the
gesture is the only thing that does. This is the whole of the mechanism; there is no key.

### 5.4 Reserved for key-based identity

The repository record reserves a `boundKey` slot, unset in format 1. When a signed format
exists (§9), binding happens on the first verified index seen for that UUID; thereafter the
identity accepts an index only under the bound key or under a rotation statement signed by it. A
key seen under a *different* URL lets the installer recognise a move without a redirect — "this is
the repository you already have at <URL>; re-point it?". Nothing keyed by the UUID migrates at any
of these points; Amendment 4's decision 2 owns the reasoning.

## 6. Operations

Every operation is atomic at the granularity stated: on any failure, nothing the reader can
observe changes, and the failure reaches them as a sentence (Phase 4 acceptance criterion 10).
All lifecycle transitions go through the merged `SourceLifecycleRegistry`; the installer wraps it
and never duplicates its state.

### 6.1 Add repository

1. Fetch the index at the typed URL, bounded in size by an installer tunable (§10).
2. Validate per §4 under a *provisional* UUID. A whole-index rejection ends the operation; the
   provisional UUID is discarded.
3. Persist the repository record with that UUID, the URL, the index's `name`, and the fetched-at
   time. Nothing is installed yet: adding a repository installs nothing.

### 6.2 Refresh index

Re-fetches and re-validates a repository's index under its existing UUID. Runs on explicit reader
action and when the repositories screen appears. **It does not run in the background** — the
library's `LibraryRefreshCoordinator` polls for chapters, not for engines, and adding engine polling
to it is a separate decision. A refresh that fails leaves the previous listing in place and says
when it was last successful.

A refresh is also where **available updates** are computed: for each installed Source whose
`localId` the fresh index lists, the listing bundle's `version` is compared to the installed
bundle's. Greater means an update is available. Equal or lower means nothing — a lower version is
not a downgrade offer, and an equal version with a different `scriptSHA256` is a maintainer who
republished without bumping, which is logged as a diagnostic and otherwise ignored. `version` is
the only trigger.

An installed Source that the fresh index **no longer lists** stays installed, runnable from its
local copy, and is shown as no longer offered by its repository. It is never uninstalled on the
maintainer's behalf (Amendment 4, decision 7).

### 6.3 Install Source

Precondition: the Source's declaration validated in the most recent refresh.

1. Fetch the bundle's script (bounded, §10). Compute SHA-256; a mismatch with the index's
   `scriptSHA256` refuses the install and names both digests.
2. Re-validate the declaration **from the raw JSON as served**, minting the qualified id per §5.2.
   The typed value the registry receives exists only as this validator's output (ADR-0003
   Amendment 4, "the `reinstall` boundary").
3. If no installed-Source record exists for the qualified id: `register`. If one does (a Source
   the reader uninstalled earlier, or one from a removed repository that was re-added):
   `reinstall`, which reconnects Listings, pins and storage through `validateUpdate`.
4. Persist the installed-Source record and, if not already present, the installed-bundle record
   and script file. Two installed Sources from one bundle share one script file.

A `mixed` or `adultOnly` declaration takes the path §7 decides.

### 6.4 Update bundle

Precondition: a refresh computed an available update. Updates are **offered, not applied**: the
reader taps "Update". Automatic application is deferred with signing (§9); Amendment 4's decision
5 says why.

The unit is the bundle, and the operation is all-or-nothing across every installed Source the
bundle supplies (Amendment 4, decision 7):

1. Fetch and hash-check the new script as in §6.3.
2. For each installed Source the new bundle lists, validate the served declaration from raw JSON
   under the Source's existing qualified id, then check `SourceDeclarationValidator.validateUpdate`
   from the currently installed declaration. Any refusal ends the update with the registry
   untouched (Phase 4 acceptance criterion 5).
3. Only then, `reinstall` each, replace the stored script and declarations, and record the new
   `version` and digest.

An installed Source the new bundle no longer lists is not updated and stays as §6.2 describes.
Updating one Source from a bundle while leaving a sibling on the old script is not possible by
construction: they share the file.

### 6.5 Disable / enable, uninstall, reinstall

These are the registry's transitions and keep its guarantees: Listings, pins and bounded storage
are untouched by all three. The installer adds only persistence of the resulting state and, for
uninstall, **retention** (§8.2). "Reinstall" from the reader's point of view is §6.3 against a
Source whose record still exists; the registry's `reinstall` is what reconnects it.

### 6.6 Change repository URL

Fetches the index at the new URL and validates it under the **existing** UUID. If accepted, the
stored URL changes and a refresh (§6.2) follows, so installed Sources see the new index as an
ordinary update source. If refused, nothing changes. This is the reader asserting "same
repository, new address"; §5.3 says why the gesture is the decision.

### 6.7 Remove repository

Uninstalls every Source the repository supplied (§6.5 semantics, so their data is retained), and
marks the repository record removed — **the record and its UUID persist**, which is what lets a
later re-add reconnect (§5.3). The script files are deleted; they are re-fetchable and are not the
reader's data.

### 6.8 Erase data

The explicit user data-removal action the design's "Storage" section names. Available per Source
and per removed repository. Erases the `host.storage` namespace, the WebKit data store
(`removeDataStoreForIdentifier:`, per ADR-0003 Amendment 3), and the installed-Source record
including its qualified-id binding. For a repository, additionally deletes the repository record,
so a later add of the same URL is a new identity.

It does **not** rewrite the reader's library: a Work's `[ListingKey]` and any pin keyed by the
erased qualified id stay where they are. They now name a Source that will never resolve, which
fulfillment already handles as unavailable.

### 6.9 Treat as adult

Sets the local adult elevation on an installed Source's record (§7.2). Reversible only by the same
reader; never lowered by an update.

## 7. Adult Sources

ADR-0022 decides what ships *in* the build. A reader-installed Source is not in the build, so
whether one may be installed was a product call with App Review consequences; the user decided it
on 2026-09-11 and [ADR-0022 Amendment 1](../../adr/0022-no-adult-source-in-the-release-build.md#amendment-1--a-reader-installed-adult-source-is-reachable-behind-the-existing-gate-2026-09-11)
records the decision and its reasoning. This section is the mechanics.

### 7.1 Install-time handling

A `mixed` or `adultOnly` declaration installs like any other and registers under the existing
adult gate (`SourceRegistry.visibleSources(includeAdult:)`). Before step 3 of §6.3 the install
presents a **one-time sheet** naming the Source, its repository, and its class, and asking the
reader to confirm they are 18 or over — the **declared-age gate** (ADR-0022 Amendment 2, decided
2026-09-16; before that date this was a plain acknowledgement). The confirmation is stored once per
device, beside the "Show adult sources" preference and cleared with it; a reader who has already
confirmed sees the sheet name the Source and its class but is not asked again. Declining ends the
install with nothing persisted — no record, no script, no registry entry. The "Show adult sources"
toggle appears by ADR-0022's existing rule the moment such a Source is registered *and* the age is
confirmed, and is hidden again by the same rule when none is.

### 7.2 Classification enforcement

The declared class is what the maintainer attests by serving the declaration (Amendment 4, Gate 4).
The host's mechanical enforcement is the Host API design's own: `mixed` and `adultOnly` Sources sit
behind the gate as a whole, and **any Listing carrying an adult `contentRating` from a `none`
Source is elevated at the Listing level** — it is treated as adult regardless of what its Source
declared. This is what makes per-Listing labelling the thing that actually matters in a
declaration, and it needs no reviewer.

**Effective class = max(declared class, local elevation).** The local elevation is a per-Source
value in the installed-Source record, set only by the reader ("Treat as adult", §6.9), and only to
`mixed`. An update whose declaration is at least as restrictive makes the elevation redundant; an
update that is less restrictive does not lower the effective class. The reader who set the
elevation may clear it. Why elevation rather than disablement is Amendment 4's decision 3.

## 8. What the installer persists

Logical records; S3 chooses the file layout under Application Support following the existing store
conventions (`UpdateStateStore`, `SourcePreferenceStore`).

### 8.1 Records

**Repository record** — `id` (UUID), `indexURL`, `name` (as last seen), `addedAt`,
`lastRefreshedAt`, `state` (`active` | `removed`), `format` (of the last accepted index),
`boundKey` (reserved, unset in format 1).

**Installed bundle record** — `repositoryID`, `bundleId`, `version`, `scriptSHA256`, and the
script bytes as a file.

**Installed Source record** — `qualifiedId`, `repositoryID`, `localId`, `bundleId`, the
**declaration JSON as served** (raw, not typed), the registry `State`, `localAdultElevation`,
`installedAt`, `updatedAt`.

The declaration is stored raw and **re-validated at every launch** before the Source is registered
(Amendment 4, decision 4). A Source refused at launch — by a tightened validator or a retired Host
API version — is shown as such in the repositories screen with the validator's sentence; it is not
uninstalled.

### 8.2 Retention on uninstall and removal

Ordinary uninstall (§6.5) and repository removal (§6.7) retain: the installed-Source record
(so the qualified-id binding survives), the `host.storage` namespace, the WebKit data store, and
every Listing and pin. Retention is **indefinite, bounded by quota rather than by time**
(Amendment 4, decision 6). The repositories screen lists retained data for uninstalled Sources and
removed repositories with "Erase data" (§6.8) beside each, which is the uninstall-retention UI the
design's "Storage" section said could not be fixed before the installer existed.

## 9. Signing

Deferred to format 2 by the user's decision of 2026-09-11; ADR-0003 Amendment 4's decision 5 owns
the reasoning and records the answer. Format 1 is as written above. What the reader trusts in
format 1 is HTTPS, the host operator, the maintainer, and the domain staying in the maintainer's
hands; what bounds the damage from misplaced trust is the Host API's own sandbox — declared
origins, bounded storage, no credentials — and §6.4's rule that updates are reader-confirmed.

Two seams exist in format 1 so that format 2 adds a signature without moving anything else:
`scriptSHA256` (§2.2) is what a signature over the index transitively covers, and `boundKey`
(§5.4, §8.1) is where the key binds to the repository's UUID.

For the record, what format 2 is expected to add, so the seams are not later reinvented: a
detached signature at `<index URL>.sig` — Ed25519 (CryptoKit `Curve25519.Signing`, no
dependency) over the index bytes exactly as served, so no canonical-JSON step exists to get
wrong; a required `publicKey` and an optional `previousKeys` list of new-key statements each
signed by the previous key; verification before parsing; key binding on the first verified index
per §5.4; refusal of an index whose key is neither bound nor provably rotated, with "trust the new
key" as an explicit reader action that is the signed equivalent of §5.3's fork-or-move choice;
automatic update application offered as a setting; and a maintainer signing script under
`scripts/`. None of that is format 1, and none of it is decided until format 2's own design.

## 10. Bounds

Installer bounds are tunables in the same place and under the same open evidence gate as the
existing `HostCapabilityLimits`: the maximum index size, the maximum script size, and the
`host.storage` quota. **None of the numbers is decided here.**

The storage quota's provisional value is the one already in `HostCapabilityLimits
.storageTotalBytes`, marked there as provisional; this document does not restate it. What settles
it is the measurement the Host API design's "Storage" section already names, applied by the slices
that produce the corpus: **serialized `host.storage` bytes per Source after a representative
browse-and-read session**, recorded by Phase 4 S6 for the installed WeebCentral, by Phase 5 for a
Madara engine across at least three sites, and by whichever slice ships the first JSON-API Source.
The decision rule, so that the number is not chosen by feel when the corpus lands: the quota is the
smallest power of two that is at least four times the largest measured working set. A corpus that
makes that rule look wrong is the evidence to change the rule, in an amendment.

Index and script size bounds have no corpus yet either. S2 sets them conservatively, marks them
with the same gate, and S6 records the actual sizes it installs.

## 11. Acceptance mapping

Phase 4's acceptance criteria are owned by its plan. The sections here that each one is tested
against: criterion 1 — §2, §4; criterion 2 — §6.3 step 2, §8.1; criterion 3 — §5.1–5.3;
criterion 4 — §4 (index-level `localId` uniqueness) and §5.2; criterion 5 — §6.4; criterion 6 —
§6.5, §8.2; criterion 10 — §6 throughout; criterion 11 — §1.1, §2.

## 12. Bundled repositories (added 2026-09-21, per ADR-0003 Amendment 5)

A **bundled repository** is a format-1 index (§2) and its scripts shipped as resources in the app
bundle. Everything above applies unchanged except where this section says otherwise; the decision
and its reasons are ADR-0003 Amendment 5's, and this section is only the shape.

- **Identity.** A fixed version-4 UUID compiled into the app, one per bundled repository, never
  minted (§5.1 does not apply). Qualified ids are `<that-uuid>:<localId>` as in §5.2. The
  WeebCentral package's UUID is declared once in code beside the installer and nowhere else.
- **Index and scripts.** The index document is validated by §4 exactly as a fetched one; its
  `script` references resolve against the index resource's URL inside the bundle, so they are
  bundle-relative. `scriptSHA256` is still checked against the resource bytes — the digest is a
  tamper and packaging check here, not a trust one.
- **Transport.** A transport that reads the bundle. `fetchIndex` never returns
  `.movedPermanently`; `fetchScript` reads the resource. The size bounds in §10 apply.
- **Operations.** §6.1 (add) runs once, at the first launch that finds no repository record for the
  fixed UUID, and never from a reader gesture. §6.2 (refresh) reads the bundle; it is what surfaces
  an update after an app update, by the ordinary `version` comparison, offered per §6.4. §6.3, §6.5,
  §6.8 and §6.9 apply to its Sources unchanged. **§6.6 (change URL) and §6.7 (remove) are not
  offered** for a bundled repository. An uninstalled Source of a bundled repository is re-offered
  on the repositories screen and is not reinstalled automatically.
- **Records (§8).** The repository record's URL is the bundle resource URL; on every launch the
  installer re-resolves it (bundle paths change between installs) rather than trusting the stored
  one. Otherwise the three records are as §8.1.
- **Adult Sources (§7).** A bundled repository may declare only `none`-class Sources; a `mixed` or
  `adultOnly` declaration in a bundled index is refused at validation. This is ADR-0022
  Amendment 3's condition, enforced.
- **Migration from a compiled Source.** When a bundled Source replaces a compiled one whose id was
  bare, a one-time rewrite of every persisted reference from the bare id to the qualified id runs
  before the Source registers, idempotently. ADR-0003 Amendment 5 part 5 is the decision; the
  cutover PR lists the stores.
