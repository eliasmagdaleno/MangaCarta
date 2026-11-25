# App Attest for analytics

Date: 2026-11-25. Status: **approved by the owner 2026-11-25, without the fraud metric (item 8); not rechecked against code.** Owner decision 2026-11-25: add App Attest before the
analytics Worker is deployed. It addresses the residual risk in Amendment 5 item 4 of the analytics design (in #422).

Sources (Apple, read 2026-11-25 through the documentation JSON endpoints): "Validating apps that connect to your server",
"Establishing your app's integrity", "Preparing to use the App Attest service", "Assessing fraud risk".

## What it does and doesn't prove

It proves a request came from a genuine, unmodified MangaCarta on genuine Apple hardware. It does **not** prove that two
installs are two people: keys don't survive a reinstall, so one iPhone can make a new one each time, and Apple states no
cap. Together with Amendment 5's maturity rule (3 days over 7), one device yields about one countable install a week,
instead of any number for free. Nineteen devices, or nineteen patient weeks, still work, as may a compromised device. **The residual risk is smaller, not gone.**

## Design

1. **Attested events count; others are still accepted.** A batch with a valid assertion is stored with `attested = 1`.
   The recommendation aggregate reads only those rows, and counts maturity on those rows. Without this, an
   unsupported device would lose analytics altogether. Feature counts use every row.
2. **One key per analytics id.** The key is made when the id is, and discarded on reset, opt-out and delete. A key that
   outlived a reset would link the two ids, which the reset promises not to do.
3. **Challenge, then attest, once per id.** `POST /v1/challenges {install}` returns 32 random bytes, valid once and for 10
   minutes; unused ones are purged, and at most one is live per install. `POST /v1/attestations` carries the install,
   key id and attestation. `clientDataHash = SHA256(challenge || lower-case install id)`, so an attestation can't be moved to another id.
4. **Each batch is signed.** `clientData` is the exact body bytes. Headers are not read today (Amendment 3 item 9), so the
   key id and assertion travel in a wrapper: `{"v":2,"install","key","assertion","body":"<v1 JSON string>"}`. Every event
   in the body must carry that install. The counter must rise; it is updated conditionally in the same batch as the
   inserts, so two concurrent replays can't both pass.
5. **A failed assertion must not lose events or block uploads.** The Worker answers 409 and the app discards the key and
   sends v1 unattested. `serverUnavailable` keeps the key and retries later; any other error makes a new key (Apple's rule).
6. **The Worker verifies by hand, with WebCrypto and no npm dependency:** CBOR and DER parsing; the x5c chain to a pinned
   Apple App Attest root, with validity dates and CA constraints; nonce OID 1.2.840.113635.100.8.2; key id = SHA256 of
   the public key = credentialId; RP ID hash of `<TeamID>.<bundle id>`; counter 0; the **production** AAGUID only. Every parser is bounds-checked, depth-limited and fails closed.
7. **Stored:** `attested_keys(install, key_id, public_key, counter)`. The receipt is not stored. DELETE removes the key row
   and challenges with the events, and the 12-month purge covers both.
8. **No fraud metric in this version (owner decision, 2026-11-25).** Apple's per-device key count over 30 days needs an Apple private key on the Worker
   and daily calls. Revisit if the counts look forged.
9. **Off by default:** no host, `-uitest-`, Debug without the flag, or `isSupported == false` → v1 batches, as now.
10. **Amendment 5's aggregate changes in the same PR.** Until the Worker is deployed there is no migration to write;
    if it has been deployed by then, `events.attested` needs an `ALTER TABLE`.

## Owner steps

Register the App ID's App Attest capability in the developer account, and confirm the team id. The entitlement
`com.apple.developer.devicecheck.appattest-environment` goes in a new entitlements file; TestFlight and the App Store always use production.

## Privacy

Apple receives attestation requests, which the policy must say. The key id is another random per-install id and is deleted
with it. Apple's pages say nothing about its privacy label; Device ID is already declared, linked. The policy must
still not claim the counts "say nothing about any one person".

## Not answered by Apple's pages

Simulator behaviour, the assertion's signature algorithm, any per-device key cap. Confirm each on a device before building on it.

## Slices

1. Worker verification with recorded fixtures: a real device attestation, plus one tampered case per check in item 6.
   **Needs one attestation captured on the owner's iPhone first.**
2. App: key lifecycle, wrapper, fallback. Then device verification, then deploy.

## Amendment 1 (2026-11-25): rechecked against `main` and Apple's pages, before slice 1

Re-read on `main` at `5f1bd15` (slices 1–3 of analytics as built: `server/analytics-worker/src/index.js`, `schema.sql`,
`MangaCarta/Services/AnalyticsTransport.swift`) and against Apple's pages read again on 2026-11-25, now including the
"Attestation Object Validation Guide" and "Defining launch environment and library constraints". Every decision above
stands, and so does the owner's decision to leave out the fraud metric. These findings change *how* slice 1 is built.

### Apple

1. **Apple publishes a genuine attestation.** The validation guide carries a production attestation for the App ID
   `1234567890.com.example.myapp`, challenge `example_server_challenge` (passed raw as `clientDataHash`), whose x5c
   chains to the pinned root (`openssl verify` at 2026-04-21: OK; leaf valid 2026-04-20 to 2026-04-23). Slice 1's
   attestation tests run on it, with the App ID and the clock as parameters. Every tampered case is this object with one
   field changed. It does **not** replace the owner's capture (item 9): it has another App ID and no assertion.
2. **Two checks the design lacked.** Apple now says to verify `apple_validation_category_01` and
   `apple_bundle_version_01` in an `extensions` CBOR map in the authenticator data, for attestations **and**
   assertions. In Apple's sample:
   - the map follows the COSE key although flag bit `0x80` (ED) is **clear** (flags are `0x40`), so the parser reads
     trailing bytes as the map whatever the flag says, and refuses any other trailing bytes;
   - the category is a **4-byte little-endian byte string** (`01 00 00 00`), not a CBOR integer;
   - the version is `"1"`, though the guide's text says `"1.0"`.
   The categories are launch-constraint values: 2 TestFlight, 3 development, 4 App Store (1 is the OS, 5 enterprise or
   ad hoc, 6 Developer ID, 10 unrecognised). **Accepted: 2, 3 and 4.** 3 is needed for the owner's development-signed
   capture; only this team can sign one. Anything else, or a missing map, fails closed: that device sends unattested
   events, which still count for features. The bundle version must be a non-empty string of at most 32 printable
   characters; it isn't compared with anything (the app sends `app` already, unverified).
3. **Apple also tells the server to put a challenge in each assertion.** The design doesn't (item 4 above): a batch is
   kept from replay by the counter alone. A per-batch challenge would add a round trip to every upload and stop only
   one more thing, a genuine device signing bodies in advance, which it could as well sign and send at once. Kept as
   designed; recorded as a deliberate departure.
4. **A key must not belong to two installs** (Apple: "the public key doesn't already have an association with another
   user"). `key_id` is unique; an attestation whose key id is held by another install is refused.
5. **The receipt is not stored or verified,** as item 7 says. Apple says to verify and store it immediately; it is
   needed only for the fraud metric the owner left out.
6. **Simulator, signature algorithm and per-device cap** are still not stated by Apple. The assertion signature is
   expected to be ECDSA P-256 with SHA-256 over `nonce` (DER-encoded, as in WebAuthn's packed format), so WebCrypto
   hashes `nonce` once more; **only a real assertion can confirm this** (item 9).

### Worker, as the code stands

7. **Wire and storage details the design left open.**
   - The v2 wrapper's `body` is a JSON string, so its escaping makes the request longer than the batch. The request cap
     becomes 128 KB; the decoded `body` keeps the 64 KB cap and every v1 rule. Each event in it must carry the
     wrapper's `install` (compared lower-cased).
   - `key`, `assertion` and `attestation` are standard base64. The key id is base64 of 32 bytes; the attestation is
     at most 16 KB decoded (Apple's sample is 5,906 bytes), an assertion at most 1 KB.
   - **Answers.** A malformed request is 400, as for v1. A well-formed attestation that fails verification is 400 too
     (the app makes a new key: Apple's rule for an error that is not `serverUnavailable`). A well-formed v2 batch whose
     assertion fails (unknown key, bad signature, counter not rising, wrong RP ID, category or extensions) is **409**,
     so the app discards the key and resends v1. A challenge or attestation request while no App ID is configured is
     404, so a Worker deployed without App Attest behaves as now.
   - **The App ID** (`<team id>.<bundle id>`) is a `wrangler.toml` var, `APP_ATTEST_APP_ID =
     "V2BG9SHQYS.Elias-Magdaleno.Manga-Reader"`, from the project file. The owner confirms the team id is the App ID
     prefix (owner step above).
   - **The root** is pinned as the DER of "Apple App Attestation Root CA" (SHA-256 fingerprint
     `1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32`), embedded in the
     source. x5c must be exactly leaf then intermediate. Each issuer name must equal the next subject, byte for byte.
     Each signature is verified with the issuer's key (the intermediate is P-384, and signs the leaf with SHA-256).
     Validity is checked at the request's time. The intermediate must be a CA and the leaf must not.
8. **Replay protection without a read-then-write race.** D1 runs a `batch` as one transaction and rolls it back if any
   statement fails, which the test stand-in reproduces. A trigger on `attested_keys` aborts any update that doesn't
   raise `counter`. The batch is therefore the counter update first, then the inserts, so a replayed or reordered
   assertion rolls back its own inserts, however many race. The inserts carry `attested = 1`; the 409 is returned when
   the transaction aborts on that trigger.
   - **Challenges** hold an expiry time to the second. It is the only time of day the Worker stores. It lives at most
     10 minutes and is not an event: the policy's "no time of day" sentence is about events, and stays true.
   - **An install that attests again replaces its key and counter.** A backup restore brings back the analytics id
     without its key (Apple: keys don't survive restore), and only a genuine app can produce a fresh attestation.
   - **DELETE** removes the install's key and challenge with its events. **The nightly job** deletes expired challenges,
     and keys whose `last_used` (a UTC day, set on attestation and each accepted batch) is over 12 months old.
   - **The aggregate** reads `attested = 1` for both the pair rows and the maturity rule.
     `events.attested INTEGER NOT NULL DEFAULT 0`. Nothing is deployed, so no migration is needed (item 10 above).

### The owner's capture (slice 1 needs it)

9. **What it is.** After the owner enables the capability, a device-only unit test
   (`AppAttestCaptureTests`) runs once on their iPhone from Xcode. It is skipped wherever `isSupported` is false, which
   includes the simulator and CI. Its steps:
   - generate a key;
   - attest it with `SHA256(challenge ‖ install)`, using a fixed challenge and install id written into the test;
   - make two assertions over two fixed v1 bodies;
   - print one JSON line: key id, attestation, assertions, the bundle version and the date.

   The new `MangaCarta/MangaCarta.entitlements` sets `appattest-environment = production`, so a development build
   yields the production AAGUID that the Worker requires. The capture is committed as
   `server/analytics-worker/test/fixtures/device-capture.json`. It holds no personal data: a throwaway key and the
   fixed test ids.

   The capture proves our RP ID, the category a development build reports, the extension encoding on a current iOS,
   and the assertion signature format. **Until it exists, the assertion tests run on a key the test makes itself.**
   Those prove the logic but not Apple's format, and the PR says so.

### Acceptance → tests → mutations (slice 1)

Every row's mutations are run; the PR records each result.

| Test | Mutations it must catch |
|---|---|
| Apple's sample attestation verifies, with its App ID and a clock inside the leaf's validity | — (the positive case) |
| one tampered case per check, each refused: x5c order, a foreign root, a broken chain signature, a leaf outside its validity, an intermediate without CA, nonce OID value, key id ≠ SHA256(public key), credentialId ≠ key id, RP ID hash, counter ≠ 0, development AAGUID, category 1 / 5 / missing, extensions malformed, trailing bytes | each check removed in turn |
| CBOR and DER parsers: truncated input, length past the end, nesting deeper than the limit, indefinite lengths, a duplicate map key, a non-minimal length | bounds check removed; depth limit removed |
| challenges: 32 bytes; single use; expire after 10 minutes; one live per install (a new one replaces it); wrong install refused; 404 with no App ID | expiry removed; reuse allowed; `clientDataHash` without the install |
| attestation stores the key; a key id held by another install is refused; re-attesting replaces the key and counter | uniqueness removed |
| v2 batch: valid assertion → rows with `attested = 1`; each refused case answers 409 and writes nothing: unknown key, bad signature, counter equal, counter lower, RP ID, category, an event with another install, body not the signed bytes | each check removed; trigger removed; counter compared `>=` |
| two concurrent replays of one assertion: exactly one batch is stored | trigger removed |
| v1 still accepted with `attested = 0`; request and body caps (128 KB / 64 KB) | v1 path removed; body cap applied to the wrapper only |
| DELETE removes key and challenge; nightly purge removes expired challenges and keys idle over 12 months | either left behind |
| aggregate: 20 unattested installs publish nothing; 20 attested do; maturity counts only attested rows | `attested` filter removed from pairs; from maturity |
| device capture (once committed): attestation and both assertions verify with `APP_ATTEST_APP_ID` | — |
