# App Attest for analytics

Date: 2026-11-25. Status: **draft, not rechecked against code.** Owner decision 2026-11-25: add App Attest before the
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
8. **No fraud metric in this version.** Apple's per-device key count over 30 days needs an Apple private key on the Worker
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
