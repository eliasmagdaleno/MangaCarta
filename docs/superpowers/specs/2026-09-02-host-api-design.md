# Phase 2 Host API design

**Date:** 2026-09-02
**Status:** Design specification
**Evidence baseline:** repository commit `77b08f3`; source-code claims inherited from the
[surface inventory](2026-09-01-host-api-surface-inventory.md) were rechecked against that commit.

## Purpose and ownership

This document specifies the versioned contract between the app and JavaScript Extensions. The
architectural choices and their reasons belong to
[ADR-0003 Amendment 2](../../adr/0003-extension-substrate.md#amendment-2--the-host-api-is-declarative-capability-based-and-configuration-first-2026-09-02).
This document owns wire shapes, validation rules, operation semantics, and the answers at contract
detail to the inventory's 18 questions. It uses the glossary terms **Source**, **Extension**,
**Listing**, **Work**, **Host API**, and **Pin** without redefining them.

This is not a JavaScriptCore implementation plan or a repository-format specification. Package
signing, repository transport, update installation, and UI are out of scope except where the Host
API must reserve a boundary for them.

## 1. Contract model

### 1.1 Configuration-first Sources

An installed bundle contains one executable Extension and one or more Source declarations. Each
declaration selects an exported engine and supplies immutable JSON configuration. Many declarations
may select the same engine. This is the essential generic-theme shape: a Madara engine is written
once, while base URL, selectors, path templates, language policy, and presentation strings vary by
configuration.

The runtime invokes the engine as if it exposed this conceptual function:

```text
invoke(operation, request, context) -> Promise<result>

context = {
  source: { id, configuration, languages },
  host: { http, browser, storage, log },
  signal
}
```

The actual JavaScriptCore bridge may use callbacks or promises, but those mechanics must preserve
this message contract. Configuration is deep-frozen before invocation. An engine cannot enumerate
other installed Source configurations or invoke another Source.

### 1.2 Source declaration

The later repository-format spec may choose filenames and packaging, but it must encode this
logical record:

```json
{
  "localId": "example-madara-site",
  "name": "Example Manga",
  "engine": "madara",
  "configuration": {},
  "adult": "none",
  "externalIds": ["mal"],
  "capabilities": {
    "search": true,
    "popular": true,
    "newTitles": false,
    "latestUpdates": true,
    "detail": true,
    "chapters": true,
    "pages": true,
    "tagBrowse": false,
    "webURL": true
  },
  "languages": { "mode": "fixed", "values": ["en"] },
  "network": {
    "httpOrigins": ["https://example.test"],
    "browserOrigins": ["https://example.test"],
    "assetOrigins": ["https://cdn.example.test"]
  },
  "presentation": {
    "feeds": {
      "popular": { "title": "Popular" },
      "latestUpdates": { "title": "Recently Updated", "badge": "new" }
    },
    "imagePrefetchConcurrency": 4
  },
  "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" }
}
```

> **Amendment 1 (2026-09-04, contract gap 1).** `hostAPI` was absent from this example while
> Section 7 required it, and unknown keys outside `configuration` fail installation — so the
> example above was not itself a valid declaration. It is now shown.

Unknown keys are ignored only inside `configuration`, which belongs to the engine. Unknown keys in
the Host API-owned declaration fail installation so a misspelling cannot silently disable policy.
The host validates declarations without evaluating Extension code.

`externalIds` is an optional array of unique namespaces the Source publishes; `mal` is the only
known namespace. Unknown namespaces and duplicates reject installation. (added 2026-09-24,
removal slice 4)

A non-empty `externalIds` declaration must also declare the optional `capabilities.listing`
operation so the host can resolve a published id. (added 2026-09-24, removal slice 4)

`localId` is lowercase ASCII letters, digits, `-`, and `.`, 1–64 characters, and cannot change in
an update. The installed Source id is an opaque repository-qualified id derived by the installer;
Extension code receives it but never constructs it. `name` is nonempty, trimmed, at most 80 Unicode
scalar values, and is display text rather than identity.

### 1.3 Envelope and value rules

Every operation result crosses in one envelope:

```json
{ "ok": true, "value": {} }
```

or:

```json
{
  "ok": false,
  "error": {
    "code": "invalid_response",
    "message": "optional author-facing detail",
    "retryAfterSeconds": 30,
    "details": {}
  }
}
```

Only JSON-compatible values cross. `undefined`, functions, symbols, cyclic objects, non-finite
numbers, dates, typed arrays, and host objects are invalid. Strings are UTF-8; integers must be safe
JSON integers. Unknown result fields are ignored for forward compatibility. Missing required
fields, wrong types, invalid enum cases, and policy-invalid URLs reject the whole operation unless
a collection rule below explicitly permits item-level omission.

The host, not Extension code, stamps every returned Listing with the invoked Source id.

> **Amendment 2 (2026-09-04, contract gap 3).** **Every validated operation result carries
> warnings, not only paged ones.** Sections 2.3 and 2.4 instruct `detail` and `chapters` to emit
> warnings — invalid tags dropped, an invalid date made absent — but only `Page<T>` had a
> `warnings` slot, which left acceptance criterion 3 untestable for three of the five result
> types. The host-side shape is a value paired with its warnings for every operation
> (`ExtensionValidatedResult<Value>`), and the paged shape keeps items, cursor, exhausted and
> warnings together (`ExtensionValidatedPage<Item>`). Warnings are host-side observations about
> an Extension's output; they are not a wire field an Extension sends, and they never change
> whether an operation succeeded.

## 2. Domain wire schemas

### 2.1 Listing

```json
{
  "id": "source-local-id",
  "title": "Display title",
  "description": "optional summary",
  "coverURL": "https://cdn.example.test/cover.jpg",
  "status": "ongoing",
  "year": 2026,
  "externalIds": { "mal": "123" },
  "alternateTitles": ["Other title"],
  "contentRating": "safe"
}
```

Required: `id`, `title`. Both are trimmed, nonempty strings; `id` is at most 512 UTF-8 bytes and
`title` at most 512 Unicode scalar values. Optional: every other field. Missing description becomes
the empty string at the Swift adapter; no other missing value is fabricated.

`status` is one of `ongoing`, `completed`, `hiatus`, `cancelled`, or `unknown`; missing becomes
`unknown`. `year` is an integer from 1000 through the current calendar year plus one. Unknown
external-id namespaces are preserved in the wire value but ignored by a host that does not support
them. Empty alternate titles are dropped and duplicates are removed with exact matching.
`contentRating` is `safe`, `suggestive`, `erotica`, or `pornographic`; missing means unknown, not
safe. The host may elevate but never reduce the Source-level adult classification.

When present, `externalIds.mal` must be a positive decimal integer string. An invalid value is
dropped and recorded as a validation warning; the Listing remains usable. (added 2026-09-24,
removal slice 4)

In Listing arrays, an item missing `id` or `title` is dropped and recorded as a validation warning;
an item with a structurally wrong top-level type rejects the operation. This narrow partial-success
rule prevents one damaged card from erasing an otherwise usable feed while keeping schema drift
visible. If every item is dropped, the result is success with an empty list plus warnings.

### 2.2 Update

```json
{ "chapterId": "chapter-42", "listing": { "id": "manga-1", "title": "Title" } }
```

Both fields are required. `chapterId` follows the Listing-id size and nonempty rules. Invalid
updates are dropped item-by-item with warnings. The host stamps the embedded Listing.

### 2.3 Detail

```json
{
  "description": "Summary",
  "authors": ["Author"],
  "tags": [{ "id": "tag-id", "name": "Action", "group": "genre" }],
  "contentRating": "safe"
}
```

All fields are optional. Missing arrays become empty arrays and missing description becomes an
empty string. Each tag requires a nonempty `name`; invalid tags are dropped with warnings. `id` and
`group` remain optional because HTML Sources may not have stable values. Adult evidence is handled
as for Listings. A non-object detail result rejects the operation.

### 2.4 Chapter

```json
{
  "id": "chapter-id",
  "number": "12.5",
  "title": "Optional title",
  "publishedAt": "2026-09-01T12:34:56Z",
  "language": "en",
  "groups": ["Example Scanlation"]
}
```

Required: nonempty `id`. `number`, `title`, `publishedAt`, and `language` are optional. Missing
`number` becomes `?` in the Swift adapter. Dates must be RFC 3339 instants; invalid dates become
absent with a warning rather than losing the chapter. Invalid chapter items are dropped with
warnings. `groups` is an optional Host API 1.2 field: when present it is an array of at most ten
nonempty strings, each at most 200 Unicode scalars; names are trimmed. A malformed `groups` value
is dropped, recorded as a warning, and leaves the chapter usable with groups unknown. An absent
field likewise means the group is unknown. Ordering and duplicate policy belong to the operation
result; the host does not reorder or merge chapters because source-specific chapter identity and
split releases make that unsafe.

### 2.5 Page

```json
{ "url": "https://cdn.example.test/page-001.jpg", "headers": {} }
```

`url` is required. `headers` is reserved and must be absent or empty in Host API v1; nonempty
per-image headers need privacy and cache-key design and therefore are not smuggled into v1. Invalid
page items reject the entire result: silently shortening a chapter can make the reader record false
completion. A successful empty page list is permitted but is surfaced as an empty-content state,
not a completed chapter.

## 3. Entry points

The operation names and request/result values are:

| Operation | Request | Result |
|---|---|---|
| `search` | `{query, page}` | `Page<Listing>` |
| `popular` | `{page}` | `Page<Listing>` |
| `newTitles` | `{page}` | `Page<Listing>` |
| `latestUpdates` | `{page, language?}` | `Page<Update>` |
| `tagBrowse` | `{tag, page}` | `Page<Listing>` |
| `detail` | `{listingId}` | `Detail` |
| `chapters` | `{listingId, language?}` | `{items: [Chapter]}` |
| `pages` | `{chapterId, quality}` | `{items: [Page]}` |
| `webURL` | `{listingId}` | `{url}` |
| `listing` | `{listingId}` | `Listing` or `null` when not found |

`quality` is `dataSaver` or `original`. The runtime calls only declared capabilities. `search`,
`detail`, `chapters`, and `pages` are required for a browsable/readable Source; at least one of
`popular`, `newTitles`, or `latestUpdates` is required for Home discovery. A configuration that
does not meet these invariants is not registered.

`listing` is optional and is not part of the reading or discovery requirements. Its declaration
is opt-in; the host sends one `listingId` and validates one Listing, with JSON `null` meaning not
found. (added 2026-09-24, removal slice 4)

### 3.1 Pagination

```json
{
  "cursor": null,
  "limit": 20
}
```

`Page<T>` is:

```json
{ "items": [], "nextCursor": "opaque-token", "exhausted": false, "warnings": [] }
```

The host validates `limit` against its supported range before invocation. The initial cursor is
`null`; later cursors are opaque Extension-produced strings, at most 2 KiB. Exactly one of a
non-null `nextCursor` or `exhausted: true` must be present. This replaces offset semantics at the
Extension boundary. Theme engines may encode an offset, page number, or upstream cursor inside the
token, but callers no longer infer exhaustion from a short page. An empty non-exhausted page is
valid, allowing filtering or upstream deduplication, but three consecutive empty pages end host
auto-pagination to prevent loops and emit a diagnostic.

## 4. Host capabilities

### 4.1 Plain HTTP

```text
host.http.request({
  url, method = "GET", headers = {}, body = null,
  timeoutClass = "interactive", responseType = "text"
})
```

V1 methods are `GET`, `HEAD`, and `POST`. Bodies are absent, UTF-8 text, or base64 bytes and are
bounded by the host. The host strips hop-by-hop headers and rejects `Host`, `Cookie`,
`Authorization`, `Proxy-Authorization`, and `User-Agent`; a later credential capability must add
authenticated requests deliberately. Safe content headers and site-required `Referer`/`Origin`
may be requested, subject to host validation. Cookies use a host-owned HTTP cookie jar partitioned
by Source and origin.

Only HTTPS URLs to declared HTTP origins are accepted. Redirects are followed by the host up to a
bounded count and every hop is revalidated against the declaration. The result contains status,
final URL, selected safe response headers, and text or base64 body. Statuses are returned rather
than automatically thrown so engines can implement site semantics; transport, policy, timeout,
size, and cancellation failures use the Host API error taxonomy. JSON parsing is Extension logic.

The host does not automatically retry. It exposes parsed `Retry-After` when present and schedules
any retry requested by a later invocation; this avoids hidden duplicate POSTs and puts global rate
policy in one place. Exact timeout, redirect, body, and response-size limits remain host tuning
constants pending device profiling and representative API/HTML corpus measurements.

### 4.2 Browser extraction

```text
host.browser.extract({ url, script, interaction = "allowForeground" })
  -> { value, finalURL, warnings }
```

The host loads a declared HTTPS browser origin, resolves redirects under the same per-hop policy,
runs `script` in the page context, structured-clones its JSON-compatible return value, and returns
that parsed value to JavaScriptCore. Authors do not call `JSON.stringify`; Swift metatypes and
decoding do not cross the boundary. The operation-specific result validator runs only after the
engine maps this raw extraction into its return envelope.

Browser scripts cannot call Host API objects. Navigation, challenge handling, and script execution
are host-controlled. V1 allows one browser extraction at a time globally, preserving the actual
single-browser constraint while leaving room for a future host version to advertise a wider
budget. The UA is host-owned and stable for the lifetime of its cookie partition.

### 4.3 Storage

```text
host.storage.get(key) -> JSON value | null
host.storage.set(key, JSON value)
host.storage.remove(key)
host.storage.keys(prefix) -> [key]
```

Keys and total encoded bytes are bounded. Storage is namespaced by qualified Source id, survives
updates and disablement, is retained on ordinary uninstall so reinstall can reconnect state, and
is erased only by an explicit user data-removal action. A repository replacement gets a different
namespace. Cache data belongs in memory or must wait for a separately bounded cache capability;
credentials and secrets are prohibited.

The exact quota and uninstall-retention UI cannot be fixed without representative theme caches and
the installer design. Evidence that settles them: measured serialized state from the Madara engine,
the WeebCentral port, and at least two bespoke Sources, plus an installer data-removal flow.

### 4.4 Logging

```text
host.log(level, event, fields = {})
```

Levels are `debug`, `info`, `warning`, and `error`; `event` is a stable author-chosen token. The
host attaches qualified Source id, operation, invocation id, duration, and Host API version.
Fields accept bounded JSON scalars only. URLs are reduced to origin plus redacted path shape;
queries, bodies, cookies, headers, storage values, search text, Listing titles, chapter ids, and
reader identifiers are rejected or redacted. Logs are locally retained in a bounded diagnostic
buffer and exported only by explicit reader action.

## 5. Scheduling, budgets, and cancellation

Every invocation has one host cancellation signal. Once cancelled, no new host-capability call is
accepted, queued calls are removed, active URLSession work is cancelled, and eventual JavaScript or
WebKit callbacks are discarded. The runtime waits a short host-defined grace period, then destroys
an uncooperative JavaScript context. Extensions cannot create timers or detached work that outlive
the invocation.

HTTP requests may overlap within per-Source, per-origin, and global host limits. Browser extraction
is globally single-flight in v1. The host enforces wall-clock invocation time, JavaScript execution
time, request count, bytes sent/received, response size, storage quota, log volume, and requested
image prefetch concurrency. Exceeding a budget returns `resource_limit` and records which budget,
without exposing activity of other Sources.

Manifest concurrency values are hints clamped by the host. Numeric limits are deliberately not
part of Host API v1 compatibility: freezing the current WebView deadlines or image width without
runtime measurements would turn implementation accidents into a forever contract. Before runtime
implementation, profiling must cover the WeebCentral port, a configured Madara engine across at
least three sites, one JSON API Source, low-memory device conditions, slow networks, Cloudflare,
and background expiration. The implementation plan may choose conservative tunables and tests,
but this specification does not pretend those values are evidence-backed.

## 6. Errors and partial success

Stable error codes are:

| Code | Meaning | Retry guidance |
|---|---|---|
| `cancelled` | caller or host cancelled | no automatic retry |
| `invalid_request` | host/runtime contract bug before invocation | never |
| `invalid_response` | Extension output violates schema | after Extension fix |
| `invalid_result` | host detected a well-formed result with an invalid meaning (for example, a Listing id that does not match the requested id); engines must not send this code | after Source fix |
| `unsupported` | declared/implemented contract mismatch | after Extension fix |
| `unsupported_language` | requested declared language is currently unavailable | after selection changes |
| `network` | transport failed | caller policy |
| `http` | engine chose to surface an HTTP status | status-dependent |
| `rate_limited` | host or upstream rate limit | after supplied delay |
| `timeout` | bounded operation expired | caller policy |
| `resource_limit` | host budget exceeded | after reducing work/update |
| `policy_denied` | origin/header/scheme/capability denied | after manifest/update |
| `interaction_required` | background browser call needs user | retry in foreground |
| `interaction_declined` | reader dismissed challenge | only by reader action |
| `interaction_timed_out` | foreground challenge expired | explicit retry |
| `navigation` | browser navigation failed | caller policy |
| `script` | page-context or engine script failed | after Source fix/transient retry |
| `storage` | storage unavailable/quota exceeded | after reducing data |
| `incompatible_version` | no Host API range intersection | after host/Extension update |

The host maps these to user-facing copy; Extension `message` is diagnostic and never shown
verbatim. Each error carries a unique invocation id available to logs. `retryAfterSeconds` is only
advisory and the host scheduler remains authoritative.

Partial success exists only through validated collection items plus `warnings`. It is not an error
with a half-value. Warnings have stable codes, item indexes, and safe field paths; they never carry
raw reader or response data.

## 7. Versions and feature negotiation

The Source declaration contains a required range such as:

```json
{ "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" } }
```

The host selects the highest installed version in the intersection. Major versions may remove or
change behavior; minor versions are additive.

> **Amendment 3 (2026-09-04, contract gap 2).** The version *grammar* was never stated — patch
> components, comparison, and invalid strings were all undefined. It is exactly
> `MAJOR "." MINOR`: two components, ASCII decimal digits only, each nonempty, no leading zero
> unless the component is exactly `0`. Comparison is `(major, minor)` lexicographic. A third
> component is **refused, not truncated**, because this section only ever assigns meaning to two
> — accepting `1.0.3` would mean inventing comparison semantics the contract does not have. Any
> string outside the grammar fails installation rather than being guessed at, and a range whose
> `minimum` is not strictly below its `maximumExclusive` is refused at construction, since it can
> intersect nothing. Implemented in `HostAPIVersion` / `HostAPIVersionRange`. An Extension may also declare optional named Host API
features with minimum versions. Missing required features prevent registration with an actionable
compatibility error; missing optional features are absent from `context.host` and the engine must
use its declared fallback. The host never invokes an older Extension under guessed semantics.

Operation result readers ignore unknown fields, while required fields and enum cases retain the
rules of the selected version. A new operation or capability is opt-in through declaration and
feature negotiation, not inferred from an export.

The optional `listing` operation and `externalIds` declaration key are additive opt-in features
introduced by Host API 1.1; declarations selecting 1.0 must not use them. (added 2026-09-24,
removal slice 4)

A Source using `listing` or `externalIds` should declare `hostAPI.minimum` as `1.1`, so a host
older than 1.1 reports a version error rather than an unknown key. (added 2026-09-24, removal
slice 4)

## 8. Language contract

Language tags are canonicalized BCP 47 strings. A declaration chooses one mode:

- `fixed`: the Source serves the listed language set and per-call language is omitted;
- `selectable`: the listed languages are supported and the host passes one reader-selected value;
- `mixed`: the Source cannot reliably filter; the host passes a preference and results label each
  Chapter where known.

The host never passes a language outside the declaration. If a selected language becomes
unavailable, the Source returns an exhausted page or `unsupported_language`; it must not silently
substitute another language. `latestUpdates` and `chapters` use the same language mode. A fixed
English Source therefore does not need to ignore a meaningless argument, and MangaDex-like Sources
can receive the preference consistently.

## 9. Browser identity and interaction

Cookie and website data are partitioned by qualified Source id and origin. Different configured
Sources using the same theme do not share cookies. HTTP and browser jars are separate in v1; an
explicit future capability would be needed to synchronize them. Authors cannot change the UA,
inspect cookies, navigate outside declared browser origins, open windows, or persist arbitrary
WebKit data into another partition.

When a foreground extraction needs interaction, the host presents a sheet naming the Source and
origin and explaining that the site requested browser verification. The Extension cannot supply
this copy. In a background invocation, no sheet is presented: the call returns
`interaction_required`, the refresh records that Listing as unknown, and foreground activity may
retry. This differs from `interaction_declined`, `interaction_timed_out`, and `cancelled`.

The precise WebKit mechanism for strong per-Source persistent data-store partitioning must be
prototyped before implementation. If the deployment target cannot provide durable isolated stores,
the fallback is separate nonpersistent stores plus explicit loss of cross-launch clearance—not a
shared global store. Evidence that settles the mechanism is an iOS 17.5 prototype proving cookie
isolation and persistence across process relaunch for two Sources on one origin.

## 10. URL policy

All network, cover, page, and browser URLs must be absolute HTTPS URLs. `http`, `file`, `data`,
`blob`, `javascript`, custom schemes, user-info components, and non-network URLs are rejected.
Loopback, link-local, multicast, and private-address destinations are rejected after DNS resolution;
redirects are rechecked to prevent rebinding and cross-origin escape.

HTTP and browser calls must match their respective declared origin lists. Covers and pages must
match `assetOrigins`; cross-origin CDN delivery is allowed only when declared. `webURL` must match a
declared browser origin and is revalidated immediately before opening. Malformed optional cover
URLs drop that field with a warning; policy-invalid URLs and all invalid page or browser URLs reject
the operation. This distinction keeps cosmetic damage recoverable without silently weakening the
reader or navigation boundary.

> **Amendment 4 (2026-09-04, contract gap 4).** The sentence above is superseded for the optional
> cover field alone. A **policy-invalid optional cover URL now also drops the field with a
> warning** and keeps the item, carrying the distinct warning code `policy_invalid_url`. As
> written, one `http://` cover rejected the whole operation and erased an otherwise usable feed,
> defeating Section 2.1's partial-success rule; the host never loads the rejected URL under either
> reading, so nothing is weakened by keeping the rest of the feed. **Unchanged:** every page URL,
> every browser `webURL`, and every network request URL still reject the operation. See
> [ADR-0024](../../adr/0024-a-bad-cover-costs-the-cover-not-the-feed.md).

## 11. Identity lifecycle

The installer owns repository identity. It combines that identity with immutable `localId` to
produce the qualified Source id and rejects duplicate declarations inside a repository. A second
repository using the same `localId` does not collide because it receives a different qualified id.
The exact encoding is private to the host and must not be parsed by Extensions or UI.

An update may change name, engine, configuration, and capabilities, but not repository identity or
`localId`. A rename requires a future explicit migration format; v1 refuses it. Disablement and
uninstall unregister the Source but preserve Listings, pins, and bounded Source storage. Calls fail
as unavailable and existing fallback behavior may choose another registered Source. Reinstalling
the same repository identity and `localId` reconnects the stored references. An unrelated
repository cannot claim them by copying a local id.

How repository identity survives URL moves, forks, and signing-key rotation cannot be finalized
before the repository-format and trust design. That design must supply a stable cryptographic or
installer-minted repository identity plus an explicit migration proof. Until then, URL replacement
is a new identity. Evidence needed: the chosen signing/update model and recovery requirements for a
lost repository domain.

## 12. Adult classification

`adult` is required and is one of `none`, `mixed`, or `adultOnly`. `mixed` means the Source may
return both adult and non-adult Listings; each Listing should supply `contentRating` when known.
Missing or invalid Source classification prevents registration. The host gates `mixed` and
`adultOnly` under the adult-source setting; it does not execute code to infer classification.

An approved repository index may override a declaration only toward a more restrictive class. The
host may similarly elevate individual output based on `contentRating`; neither Extension output nor
an update may lower previously trusted classification without repository re-review. Inaccurate
under-classification is a repository policy violation and the Source is disabled pending corrected
metadata; it is never silently treated as safe.

The authority that marks a repository “approved,” the review cadence, and whether signatures carry
classification attestations remain deliberately open for the repository-format phase. They cannot
be answered from the app code or inventory. Evidence needed: distribution model, maintainer threat
model, signing scheme, and moderation capacity.

## 13. Source-authored presentation

V1 supports presentation metadata per declared feed, keyed by semantic operation rather than by
three positional arrays. A feed may provide a title, optional eyebrow, and a badge enum of `none`
or `new`. Missing text uses host-localized defaults. Extension-authored text is display content in
the Source's declared locale; it is not a host localization key and cannot select arbitrary app
copy. Values are trimmed and length-bounded.

The host chooses layout, rail count, order, typography, color, accessibility wording, and fallback
behavior. A capability absent from the declaration has no presentation record. This keeps feed
meaning extensible without freezing Home's current three-rail layout into the Host API.

## 14. The 18 inventory questions, resolved

This index makes the Phase 2 agenda auditable. Architectural rationale is linked to ADR-0003
Amendment 2 rather than duplicated here.

### Q1 — domain wire representation and validation

**Decision:** JSON-compatible schemas and host validation defined in Sections 1.3 and 2; narrow
item-level omission for Listings, Updates, Chapters, and Tags; page corruption rejects the result.
**Rejected contract shapes:** exporting Swift `Codable`, accepting arbitrary DTOs, and silently
defaulting required identity fields. The first two are not language-neutral; the last makes source
breakage indistinguishable from valid sparse data.

### Q2 — capability declaration

**Decision:** capability flags are mandatory declaration data and checked against runtime exports
at registration. **Rejected:** export inference and unsupported-as-discovery, because the host must
schedule and present capabilities before invocation.

### Q3 — declaration versus executable behavior

**Decision:** identity, adult class, capabilities, language mode, allowed origins, resource hints,
and presentation are declarative; fetch/parse/map behavior is executable. Browser URL support is
declared, while the Listing-specific URL is computed. **Rejected:** executing an Extension during
discovery and placing dynamic network results in a manifest.

### Q4 — plain HTTP

**Decision:** Section 4.1's bounded, origin-scoped request capability; the host owns cookies,
redirect validation, cancellation, limits, and retry scheduling, while the engine chooses safe
request details and response decoding. **Rejected:** raw `URLSession` equivalence, automatic retry,
and a GET-only helper. They respectively evade policy, risk duplicate effects, and cannot serve
common APIs/forms.

### Q5 — WebView primitive

**Decision:** Section 4.2 returns a structured-cloned JSON-compatible value; engine mapping and
operation validation happen afterward. **Rejected:** Swift metatypes, mandatory JSON strings, and a
remote DOM proxy. They leak implementation, burden authors, or create an excessively broad API.

### Q6 — concurrency and cancellation

**Decision:** Section 5 makes scheduling host-owned, browser work single-flight in v1, HTTP bounded,
and cancellation terminal for an invocation. **Rejected:** contractual global serialization for
all work and detached Extension tasks. Exact deadlines remain evidence-gated as Section 5 states.

### Q7 — errors and observability

**Decision:** Section 6's stable taxonomy, host-authored user copy, explicit partial-success
warnings, and Section 4.4's redacted local logs. **Rejected:** raw Swift errors, raw Extension
messages in UI, silent omission without warnings, and logs containing reader/request data.

### Q8 — rate and resource budgets

**Decision:** per-Source, per-origin, and global host budgets cover concurrency, rates, bytes,
browser occupancy, script/invocation time, logs, storage, and image width. Authors receive typed
`resource_limit`/`rate_limited` outcomes. **Rejected:** author-enforced limits and freezing current
magic numbers. Numeric values remain open pending the profiling evidence in Section 5.

### Q9 — storage scope and lifecycle

**Decision:** Source-qualified bounded JSON key/value storage; retained across update, disablement,
and ordinary uninstall, removed by explicit user action; no credentials or arbitrary cache files in
v1. Browser/HTTP cookies are separate host-owned origin partitions. **Rejected:** shared Extension
storage, filesystem paths, and treating preferences as Extension data. Quota and removal UX await
the evidence in Section 4.3.

### Q10 — versions

**Decision:** Section 7's intersecting major/minor range plus named feature negotiation; incompatible
Sources do not register. **Rejected:** host-only versioning, duck typing, and best-effort execution.

### Q11 — pagination and input validity

**Decision:** host-validated positive bounded limits plus opaque cursor pages with explicit
`exhausted`; short pages have no special meaning. **Rejected:** universal offsets, source page
numbers, and inferring exhaustion from item count.

### Q12 — presentation

**Decision:** Section 13's semantic per-feed metadata with host-localized defaults; the host owns
layout and accessibility. **Rejected:** positional arrays, arbitrary host localization keys, and
removing all Source-authored meaning.

### Q13 — browser identity, cookies, and challenges

**Decision:** Section 9 partitions state by Source and origin, keeps UA host-owned, and identifies
the Source/origin in host-authored challenge UI. **Rejected:** one shared store, author-controlled
UA, and silent interaction. The precise persistent WebKit mechanism remains open pending the stated
iOS 17.5 prototype.

### Q14 — URL schemes and destinations

**Decision:** Section 10 permits only absolute HTTPS URLs within declared role-specific origins,
revalidates redirects/DNS, and permits declared cross-origin CDNs. **Rejected:** Foundation-parsable
as sufficient, unrestricted redirects, and same-origin-only assets.

### Q15 — language

**Decision:** Section 8 declares fixed/selectable/mixed BCP 47 semantics and applies them uniformly
to feeds and chapters. Ignored language arguments disappear; unavailable selections are explicit.
**Rejected:** global English hardcoding, always passing a preference, and silent substitution.

### Q16 — background challenges

**Decision:** background work never presents UI and returns `interaction_required`; foreground may
retry. Decline, timeout, and cancellation are distinct. **Rejected:** waiting for a sheet in the
background and treating every unsolved challenge as one error.

### Q17 — Source-id lifecycle and collisions

**Decision:** Section 11's immutable repository-qualified identity, collision rejection, preserved
references on disable/uninstall, and reconnection on same-identity reinstall. **Rejected:** globally
author-chosen ids, mutable ids, and deleting pins/Listings on temporary absence. Repository moves
and signing rotation await the repository trust evidence named in Section 11.

### Q18 — adult declaration and trust

**Decision:** Section 12 requires fail-closed declarative classification, supports per-Listing
elevation, and allows review metadata only to strengthen classification. **Rejected:** default-safe,
runtime inference as the primary declaration, and unrestricted author downgrades. Review authority
and attestation remain open pending the repository threat model and signing design.

## 15. Acceptance criteria for the later runtime

A JavaScriptCore implementation conforms to this design only if tests demonstrate:

1. one theme engine serves at least three differently configured Sources without code duplication;
2. manifest validation and Source registration execute no Extension code;
3. every operation schema accepts valid sparse values and rejects or warns exactly as specified;
4. Source-id stamping cannot be overridden by Extension output;
5. HTTP and browser redirects cannot escape declared HTTPS origins;
6. two configured Sources cannot read each other's storage or cookie state;
7. cancellation prevents every late callback from changing invocation state;
8. background challenges return `interaction_required` without UI;
9. incompatible Host API ranges prevent registration with an actionable error;
10. disable/uninstall/reinstall preserves and reconnects Listings and pins for the same qualified
    Source id;
11. logs redact all prohibited reader and request data; and
12. the compiled WeebCentral Source can be replaced by a configuration-backed Extension with
    equivalent browse/detail/chapter/page behavior, modulo intentional validation improvements.

## 16. Deliberately open evidence gates

The 18 questions all have a structural answer. Four implementation choices remain deliberately
open because the available evidence cannot settle them honestly:

1. exact request, response, CPU, wall-clock, storage, log, and concurrency limits (profiling corpus
   in Section 5);
2. the WebKit mechanism that provides both persistent clearance and strong per-Source isolation on
   iOS 17.5 (prototype in Section 9);
3. stable repository identity across URL moves, forks, and signing-key rotation (repository-format
   and signing design in Section 11); and
4. who may attest adult classification and how review is maintained (distribution threat model and
   moderation capacity in Section 12).

None changes the v1 semantic boundary. Each must be resolved before its dependent runtime or
installer slice is called complete.

## Amendment 5 — paged requests use a nested page value (2026-09-22)

*Renumbered from "Amendment 3" on 2026-09-24: that number was already used by the Q10
version-grammar amendment above, and 4 by the optional-operations one. "Flat" and "nested"
describe engine request shapes, not Host API versions.*

**Decision:** Option B from GitHub issue #186 is adopted. Every paged entry point sends its
request with the designed nested shape: `{query, page: {cursor, limit}}` for `search`, and
`{page: {cursor, limit}}` for `popular`, `newTitles`, and `latestUpdates` (with the additional
fields shown in the Entry points table where applicable). A paged result continues to return
`Page<T>` with its opaque `nextCursor` field.

The repository system exists so third parties can write engines, and the request shape is
cheapest to settle before any third-party engines exist. Nesting keeps paging opaque and uniform
across feeds and leaves room for other paging styles without colliding with query fields. The
host passes a returned cursor back unchanged; engines own the token's meaning.

The shipped WeebCentral engine was migrated to read `request.page.cursor` and
`request.page.limit` in the implementation accompanying this amendment. During the
transition, the host also sends the same values as legacy top-level `request.cursor` and
`request.limit`, allowing pre-#186 (flat-shape) engines to continue paging while nested-shape engines read
only the nested value and still reject requests without a `page` object. Remove this compatibility
shim once all published engines use the nested shape, and no later than no-built-in-sources
slice 6 removes the bundled package.

## Amendment 6 — chapter scanlation-group credits (2026-09-24)

**Decision:** Chapter results may carry an optional `groups` array beginning with Host API 1.2.
The host trims each name, limits the array to ten names and each name to 200 Unicode scalars.
A non-array, non-string element, empty name, or over-limit value drops only `groups`, records a
warning, and keeps the chapter with groups unknown. Missing `groups` likewise remains unknown
rather than an empty claim. The app preserves valid names in chapter values and shows them joined
by `, ` in the chapter list, including the credit in the row's accessibility label. The Host API
version gate is evaluated at result time: groups returned under a selected version below 1.2 are
a real `invalid_result`, unlike #234's declaration-time `externalIds` gate, because groups is an
optional field in an otherwise valid chapter result and can be safely degraded when malformed.

This makes the scanlation-group credit required by MangaDex's acceptable-use policy available to
configuration-backed Sources without inventing source-specific selection or deduplication policy.
