# Repository format 2 — signed indexes and automatic Source updates

**Date:** 2026-11-09  
**Status:** Design specification.  
**Slug:** `repository-format-2`

## Goal

Make repository indexes authenticatable and make safe, signed Source updates happen without
requiring the reader to open Settings.  Format 2 must preserve the installer-minted repository
identity and the format-1 repository population already on devices, while adding an explicit trust
decision, maintainer key rotation, and an all-or-nothing update transaction.

This is the bytes-and-operation contract for the app PR and the separately maintained
`proxy-link/mangacarta-sources` changes.  The decision record remains
[ADR-0003 Amendment 4](../../adr/0003-extension-substrate.md#amendment-4--repository-identity-is-installer-minted-attestation-is-the-maintainers-and-a-typed-declaration-is-a-validated-one-2026-09-11); this document specifies the implementation.

## Non-goals

- No central approval list, certificate authority, server-side repository API, or developer
  moderation status.
- No key-derived Source or repository identity.  `boundKey` is an attribute of the existing UUID.
- No code-signing of individual JavaScript functions or runtime changes to the Host API sandbox.
- No automatic uninstall, disablement, repository URL change, or adult-content preference change.
- No signature requirement for already-installed format-1 repositories in this slice; migration is
  explicit and format 1 remains supported indefinitely while the app supports it.

## Current code this builds on

The following files were opened for this specification:

- `MangaCarta/Models/RepositoryIndex.swift:127-148` defines the typed format-1 index and bundle,
  including `scriptSHA256`; `:152-260` parses only format 1 and rejects unknown keys before any
  declaration is executed.
- `MangaCarta/Services/RepositoryStore.swift:33-63` persists the installer-minted repository
  UUID, `format`, nullable `boundKey`, and installed bundle version/digest; `:90-99` makes the
  repository, bundle, and Source records one snapshot; `:158-189` provides atomic snapshot and
  script-file writes.
- `MangaCarta/Services/ExtensionInstaller.swift:264-319` adds and refreshes repositories under
  their existing UUID; `:463-533` updates an entire bundle all-or-nothing across installed
  Sources; `:767-773` verifies fetched script bytes against `scriptSHA256`.
- `MangaCarta/Services/SourceLifecycleRegistry.swift:61-75` owns registered/disabled/uninstalled
  state; `:129-156` revalidates an incoming declaration before `reinstall`.
- `MangaCarta/Services/RepositoryTransport.swift:38-55` separates index and script fetches;
  `:96-118` currently parses the index and fetches bounded script bytes, while `:121-154`
  enforces HTTPS/public-destination policy.
- `MangaCarta/Services/UpdateScheduler.swift:57-127` schedules the existing background refresh
  and provides a bounded async run; `MangaCarta/MangaCartaApp.swift:266-285` starts and stops the
  foreground refresh on `scenePhase`.
- `MangaCarta/Models/RepositorySettingsViewModel.swift:17-25,54-100` owns the existing adult and
  image-load-report acknowledgement sheet and its disclosure copy.  The format-2 update path
  must call this same acknowledgement seam.
- `MangaCarta/Views/SettingsView.swift:352-430` is the existing repository manager, including
  manual Refresh and Update actions.
- `DESIGN.md:1-64` owns the Ink & Seal tokens; new trust/update UI uses those existing tokens and
  native controls rather than inventing a second visual language.

The existing format-1 specification's deferred signing section says the expected detached
`<index URL>.sig`, CryptoKit Ed25519, exact served bytes, `publicKey`, `previousKeys`, and
`boundKey` seam.  This document resolves those details and adds the update policy.

## Design

### 1. Format-2 wire shape and signature

Format 2 is an additive index shape.  Its root is the format-1 object plus these required keys:

```json
{
  "format": 2,
  "name": "MangaCarta Sources",
  "publicKey": "<base64url, 32-byte Ed25519 public key>",
  "previousKeys": [
    {
      "publicKey": "<base64url old key>",
      "replacement": "<base64url new key>",
      "reason": "planned rotation"
    }
  ],
  "bundles": [ ... format-1 bundle objects ... ]
}
```

The detached signature is fetched from the exact URL formed by appending `.sig` to the index URL
(for example `index.json.sig`).  It is exactly 64 bytes, transported as base64url without
padding.  The signature is Ed25519 using CryptoKit `Curve25519.Signing.PrivateKey` and
`Curve25519.Signing.PublicKey`; no third-party dependency or platform-specific isolated
conformance is needed.  The app verifies the signature over the *raw index response bytes*,
including whitespace and key order, before JSON parsing.  There is no canonical-JSON step and no
signature field inside the signed object.  A missing, malformed, or invalid signature rejects the
whole index and leaves the last accepted listing untouched.

`publicKey` is the key that verifies this index.  It is not an identity and is not trusted merely
because the index names it.  It is decoded as exactly 32 bytes and encoded canonically as
base64url without padding.  `previousKeys` is optional and contains rotation statements.  Each
statement is signed by the currently bound key over the UTF-8 bytes of the statement's canonical
JSON object with keys in the fixed order `publicKey`, `replacement`, `reason`; `reason` is trimmed,
nonempty, and at most 200 Unicode scalars.  The statement's `replacement` must equal the index's
`publicKey`; its `publicKey` must equal the repository's bound key.  The app accepts one statement
for the bound key and refuses conflicting or ambiguous statements.  `previousKeys` is not a
general chain and cannot jump through two rotations in one refresh.

The signature covers every index field, including `format`, `name`, `publicKey`,
`previousKeys`, bundle versions, declaration bytes, script URLs, and `scriptSHA256`.  The detached
signature does not cover the separately fetched script, but the signed `scriptSHA256` transitively
authenticates those bytes when the installer compares the digest before staging them.

**Options considered:** sign canonical JSON (portable, but creates a second exact-serialization
  contract); put the signature in the index (self-referential or requires an exclusion rule); or
  use a detached signature over response bytes.  Choose the last option because the transport
  already has the response bytes, it avoids canonicalization bugs, and the existing deferred
  design explicitly chose it.

### 2. First-add trust and key pinning

On adding a format-2 URL, the app verifies the index and obtains its key before persisting a
repository record.  It shows a trust sheet containing the repository name, typed URL, and a
short, grouped fingerprint: lowercase hexadecimal SHA-256 of the raw public-key bytes (first and
last eight characters shown, with a “copy full fingerprint” action).  The sheet explains that
the key authenticates future indexes but does not mean MangaCarta has reviewed the repository.
The reader must choose **Trust this key**; cancellation or decline persists nothing.  The key is
then stored as `boundKey` (canonical base64url public key, not the display fingerprint).

This is trust-on-first-use (TOFU), constrained by the reader's explicit first-add gesture.  A key
in the repository URL was considered, but rejected: query/fragment material is easy to strip or
change, leaks into copied URLs, and would make a URL format rather than the signed index the
trust anchor.  A developer-maintained allow-list was also rejected because no approval authority
exists and it would make first-party status misleading.

For an existing format-1 repository, refresh continues to accept format 1 exactly as today and
keeps `boundKey == nil`.  If the URL begins serving format 2, the app verifies it but does not
silently bind the new key: it presents the same fingerprint sheet, labelled **Upgrade repository
security**, and only after confirmation stores the key and accepts the format-2 listing.  Declining
leaves the last format-1 listing, scripts, and UUID active; the user may retry from Settings.  A
format-2 repository that is moved by the existing confirmed Change URL flow must present the new
key if it is not already the bound key.  A key mismatch at an already-bound URL is a hard refusal,
not a new trust prompt.

### 3. Rotation and compromise recovery

Routine rotation is one signed `previousKeys` statement, served in an index signed by the new key:

1. The maintainer signs the statement with the old private key, publishes the new index and `.sig`,
   and keeps the old key available long enough for readers to receive the transition.
2. The app verifies the new index with the new key, verifies the statement with the stored old
   key, and atomically replaces `boundKey` with the new key.
3. Subsequent indexes must use the new key.  An old-key index after rotation is refused as stale;
   it cannot roll the pin backward.

If the old private key is compromised, it cannot silently rotate the repository to an arbitrary
key without a reader-visible event: the app accepts only the bound key or a new key named by a
statement signed by the bound key.  The maintainer must publish the emergency rotation while the
old key remains available.  If the old key is lost, there is no cryptographic recovery path; the
owner can use Change repository URL to add a replacement repository under a new UUID, or remove
and re-add it after the reader explicitly trusts a new key.  Existing Listings, pins, and stored
Source data are retained unless the reader chooses Erase data.

**Rotation options:** accept multiple future keys in a threshold set (more resilient, larger and
harder to explain); pin only the URL (no cryptographic move proof); or the one-step signed
statement above.  Choose one-step rotation because it is enough for planned key changes, keeps
verification deterministic, and fits the existing single `boundKey` field.

### 4. Format-1 compatibility and validation order

`RepositoryIndexValidator` becomes format-aware.  Format 1 keeps its current allowed keys,
unsigned transport, parser behavior, and reader-confirmed `updateBundle` flow.  Format 2 gets a
separate allowed root-key set and the same bundle/declaration validation rules.  Unknown keys,
malformed signature metadata, unsupported formats, invalid key statements, or a signature failure
reject the whole format-2 index before `RepositoryIndexValidator` returns a typed index.

The production transport fetches raw index bytes and the detached signature, verifies them, and
then invokes the parser.  Tests can inject a verifier and a transport; no Extension code runs
before verification.  The parsed index carries `format`, the verified key, and an update-trust
result so the installer does not repeat or bypass the decision.  Format-1 records never acquire a
synthetic key and a format-1 refresh never becomes eligible for automatic application.

### 5. Automatic Source-update policy

The app checks repositories using the existing `UpdateScheduler` background task and the existing
foreground activation cadence.  The scheduler's bounded background run invokes a new repository
refresh coordinator after (or within the same budget as) library refresh; foreground activation
does the same refresh once per cooldown window.  Manual Refresh remains available and bypasses the
cooldown.  A repository refresh is metadata-only until an update qualifies for application; it
does not download scripts for unchanged bundles.

Only a format-2 index signed by the currently bound key, with a strictly greater bundle version,
can be automatically applied.  The app stages the script, checks the signed `scriptSHA256`,
validates every affected raw declaration with `SourceDeclarationValidator` and
`validateUpdate`, and then applies the bundle transaction.  A bundle is the atomic unit because
installed Sources share one script.  These changes may auto-apply:

- engine bytes and ordinary declaration metadata/capabilities that pass the existing update rule;
- a declared adult class that stays exactly the same;
- an existing image-load-report declaration that remains present and unchanged.

These changes never auto-apply and instead create a pending Settings acknowledgement using the
existing `RepositorySettingsViewModel` sheet:

- adding `network.imageLoadReports` to any installed Source (ADR-0003 Amendment 10);
- changing the declared adult class, including `none → mixed`, `none → adultOnly`,
  `mixed → adultOnly`, or any reverse/reclassification change;
- any update that the existing adult acknowledgement path says requires confirmation.

The pending update is not partially applied.  A reader can accept or decline it from Settings;
declining leaves the old bundle active and retries on a later refresh only as a still-pending
consent item, not as repeated prompts during browsing.  A `mixed` or `adultOnly` update continues
to use the declared-age gate and existing copy.  A format-1 update, a key transition, a new
repository, a Source not currently installed, or a version that is not greater is never
auto-applied.  Missing Sources stay installed and runnable from their last local copy; automatic
update must never uninstall or disable.

**Cadence options:** add a separate background task (more scheduling budget and identifiers), run
only on foreground activation (misses unattended updates), or reuse `UpdateScheduler` with a
shared bounded coordinator.  Choose the shared coordinator: it reuses the app's existing lifecycle,
network budget, cancellation, and test seam without promising a new iOS background guarantee.

### 6. Transaction, rollback, and failure visibility

`ExtensionInstaller` stages new script bytes in a temporary file beside the installed script and
never exposes them to `ExtensionRuntime`.  It records the old bundle record, old declarations,
old script bytes, and old bound key before mutation.  The transaction is:

1. Verify signature/key policy and parse the complete index.
2. Fetch and hash the script once; reject size, transport, or digest failures.
3. Stage every affected declaration and consent requirement; if any fails, delete the temporary
   file and leave all existing state untouched.
4. Atomically replace the script file, commit bundle/source/repository records, and reinstall all
   affected declarations through `SourceLifecycleRegistry`.
5. If persistence or registry reinstallation fails, restore the prior script and snapshot, then
   reinstall the prior declarations.  If restoration itself fails, mark the bundle unavailable,
   retain the prior bytes and records where possible, and surface a recoverable repository error;
   never run the new script with old declarations.

The existing `RepositoryStore.commit` write-before-publish invariant remains the persistence seam.
A failed automatic update records a diagnostic (`repository`, `bundle`, offered version, and
reason) for Settings but does not modify the installed version or retry in a tight loop.  A later
manual refresh may retry after the repository changes.

### 7. The raw.githubusercontent / GitHub Pages timing window

The signed index does not remove the need for atomic publishing.  If raw.githubusercontent serves
the new `engine.js` before GitHub Pages serves the new index, the old signed index still carries
the old digest: the app either does not fetch the script or rejects the new bytes as a digest
mismatch.  If GitHub Pages serves the new signed index before raw.githubusercontent serves the new
engine, the signed index names the new digest but the fetched old bytes fail the same check.  Thus
signing does not worsen the window; it makes both orders fail closed rather than execute a
cross-version script.  The update is retried on a later cadence.

The engines repository must publish each bundle at an immutable versioned path and publish the
script first, then the signed index and detached signature, as one release commit.  Mutable URLs
remain valid but are less operationally safe because cache skew produces a visible delay.  The
app should use `Cache-Control: no-cache`/reload semantics already present in
`URLSessionRepositoryTransport`, but must trust neither cache headers nor publication order in
place of the signature and digest checks.

## Persistence and data changes

Extend `RepositoryRecord` with the canonical bound public key (the existing `boundKey` string is
used), the last verified format, and optionally the last accepted key fingerprint for display.
Do not store private keys.  Extend the in-memory/persisted index listing with verification state,
pending consent, and last automatic-update error; these are repository metadata, not Source
identity.  Extend installed bundle state with the last-known-good version/digest and retain the
previous script until the new transaction commits; cleanup of an older backup is safe only after
successful commit.  Existing `repositories.json` must decode with missing new fields as `nil` or
empty defaults and must continue to load format-1 records.

New app files are expected in synchronized `MangaCarta/Models` or `MangaCarta/Services` groups,
so no project-file edit is needed for them.  New tests belong in `MangaCartaTests/`, which is not
synchronized: each new test file requires `xcp add-file "$PWD/MangaCarta.xcodeproj" --file
"$PWD/MangaCartaTests/<NewTests.swift>" --targets MangaCartaTests` (or the equivalent four
project entries in Xcode).  Do not use Swift 6.2-only isolated conformances,
`nonisolated(nonsending)`, `@concurrent`, or `Task.immediate`; CI is Xcode 16.4 / Swift 6.0.

## Engines repository contract

The separate `proxy-link/mangacarta-sources` repository owns engine artifacts, release metadata,
and the signing workflow; the MangaCarta app repository owns verification, trust UI, persistence,
rollback, and scheduling.  Name the work separately:

### App PRs

1. Format-2 model/parser, detached-signature transport, CryptoKit verifier, fingerprint/trust and
   rotation policy, and migration from format 1.
2. Repository-store schema and installer transaction/rollback.
3. Automatic repository refresh integrated with `UpdateScheduler` and foreground activation.
4. Pending-consent UI/accessibility and repository error presentation.

### Engines-repo changes

1. Add `scripts/sign-repository-index.swift` (or a small Foundation/CryptoKit-compatible signing
   tool) that reads raw `index.json`, validates format-2 metadata, writes the detached `.sig`, and
   emits the public-key fingerprint for release review.  It must sign bytes without reformatting
   the index after signing.
2. Add `scripts/rotate-repository-key.swift` or documented rotation steps that produce the
   old-key-signed `previousKeys` statement and verify the new index before publication.
3. Publish immutable `bundles/<id>/<version>/engine.js` paths and signed `index.json` plus
   `index.json.sig` in a release-order workflow that avoids partial commits where possible.
4. Store the private Ed25519 key only in the engines repository's CI secret store (for example a
   GitHub Actions encrypted secret or external KMS/HSM); never commit it, put it in either Git
   repository, put it in the app bundle, or pass it as a URL/query parameter.  CI writes a
   temporary key file with restrictive permissions, signs, deletes it, and fails if the key is
   absent or the checked-in index is modified after signing.  Rotation requires updating the CI
   secret and publishing the signed transition; the old secret is retained only for the planned
   transition window.

## Error and edge cases

- No signature, bad base64, wrong key/signature length, invalid signature, malformed rotation,
  unexpected key change, or unsupported format: reject the index and retain the last good listing.
- A valid signature with a script digest mismatch: reject that bundle; do not install any Source
  from it and retain the prior bundle.
- A signed index with a lower/equal bundle version: no update; never roll back automatically.
- A declaration that adds reports or changes adult class: list as “Update needs your approval” and
  retain the prior version until the sheet is answered.
- User declines the trust or disclosure sheet: no writes, no registry transition, and a concise
  Settings status explaining how to retry.
- Network failure, HTTP error, redirect, non-public destination, timeout, cancellation, or a
  partial publication: retain the prior state and retry on the next cadence.
- App termination after script replacement but before commit: on launch, compare the journal/backup
  and restore the last complete snapshot before registering Sources.
- A repository is removed, a Source is disabled/uninstalled, or a URL is changed: automatic
  refresh does not reverse that reader action; retained data and qualified IDs remain governed by
  the existing lifecycle rules.

## Accessibility

The trust, rotation, disclosure, pending-update, and failure surfaces are native SwiftUI sheets or
alerts with Dynamic Type, VoiceOver-readable labels, and a logical focus order: repository name,
URL, key fingerprint, explanation, then the primary/secondary actions.  The fingerprint has a
copy button and a text label that speaks the full value when focused; color never communicates
trust or failure alone.  Automatic updates are announced in the repository row with text such as
“Update ready — approval required” or “Updated to version 4”; the reader can reach the same
message without opening a network log.  Respect Reduce Motion and do not use timing-only banners.

## Acceptance criteria and test mapping

1. A valid format-2 raw index and detached Ed25519 signature verify before parsing, while a
   changed byte, malformed signature, or wrong key is rejected without executing code.
   **Test:** `RepositoryIndexSignatureTests` (new unit file in `MangaCartaTests/`).
2. Format-1 indexes, records with `boundKey == nil`, manual refresh, and reader-confirmed updates
   behave exactly as before; format 1 never auto-applies.
   **Test:** `RepositoryFormat1CompatibilityTests` (new unit file in `MangaCartaTests/`).
3. First add shows the key fingerprint and persists only after explicit trust; an existing format-1
   repository requires explicit consent before binding its first format-2 key.
   **Test:** `RepositoryTrustTests` (new unit file in `MangaCartaTests/`).
4. A one-step `previousKeys` statement rotates the bound key atomically; an unsigned, conflicting,
   backward, or two-hop rotation is rejected and does not change the pin.
   **Test:** `RepositoryKeyRotationTests` (new unit file in `MangaCartaTests/`).
5. A signed higher-version bundle with unchanged adult/report declarations auto-applies through
   the shared scheduler path; no update occurs for an untrusted key, format 1, equal version, or
   a missing Source.
   **Test:** `AutomaticSourceUpdateTests` (new unit file in `MangaCartaTests/`).
6. Adding image-load reports or changing declared adult class creates exactly one pending
   acknowledgement and applies only after acceptance; declining leaves the old bundle active.
   **Test:** `AutomaticSourceUpdateConsentTests` (new unit file in `MangaCartaTests/`).
7. Digest mismatch, declaration refusal, persistence failure, registry failure, and simulated
   termination restore the last-known-good script, records, declarations, and lifecycle state.
   **Test:** `ExtensionInstallerRollbackTests` (new unit file in `MangaCartaTests/`).
8. The publication-order fixtures (new script/old index and new index/old script) fail closed and
   retry without data loss; immutable versioned paths pass.
   **Test:** `RepositoryPublicationWindowTests` (new unit file in `MangaCartaTests/`).
9. Trust, rotation, consent, pending-update, and failure UI expose accessible labels, full
   fingerprint copy, Dynamic Type-safe text, and no color-only state.
   **Test:** `RepositoryTrustUITests` (new hermetic UI test file in `MangaCartaUITests/`).
10. The engines-repo signing script signs exact bytes, rejects post-sign mutation, emits a detached
    signature accepted by the app verifier, and never reads a key from tracked files.
    **Test:** engines-repo CI script test; no MangaCarta app test target change.

## Implementation slices

1. Add CryptoKit verification, format-2 parsing, transport seam, and unit fixtures; keep format 1.
2. Add trust-on-first-use, `boundKey` migration, one-step rotation, and Settings disclosure.
3. Add transactional update staging/rollback and the automatic-update coordinator using existing
   scheduler budgets; keep manual Update as a fallback.
4. Add accessibility/UI tests and engines-repo signing/publish workflow; exercise both publication
   order failures against a hermetic transport.

Each slice can merge independently behind the existing format-1 behavior, with automatic apply
   enabled only once slices 1–3 are present.

## Open questions for the owner

1. **Should TOFU trust be required at first add, or should format-2 repositories be trusted after
   a verified signature with the fingerprint shown informationally?** Recommended: require the
   explicit **Trust this key** action; it makes the security boundary legible and matches the
   existing reader-confirmed repository identity model.
2. **Should automatic updates be enabled by default, or exposed as a Settings switch?** Recommended:
   enabled by default for signed, low-risk updates, with a per-device “Automatically update
   Sources” switch to disable; this preserves unattended fixes while respecting reader control.
3. **What is the owner’s operational key-retention window after rotation?** Recommended: retain the
   old CI secret until the new key has been served successfully for at least one normal background
   refresh interval plus seven days, then revoke it; the app itself accepts the old key only for
   the single signed transition.

