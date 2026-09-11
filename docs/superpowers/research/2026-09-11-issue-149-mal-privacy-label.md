# Issue #149 — MAL sync privacy-label findings

**Checked:** 2026-09-11 (Pacific). **Owner:** this document owns the research conclusion and
submission checklist; #149 links here rather than duplicating it. This is product/regulatory
research, not legal advice.

## Conclusion

PR #128's conclusion does **not** survive the second pass. Apple defines collection as
transmitting data off-device so the developer or a third-party partner can access it longer than
the time needed to service the request in real time. MAL persists the authenticated user's
identity and reading-list progress, so the optional MAL feature is collection even though the
destination is the reader's own account and MangaCarta has no server of its own.

Apple's narrow non-disclosure exception requires all of these: the user supplies the data in the
app UI; the account name is prominently displayed alongside it; submission is optional; the user
affirmatively chooses it **each time**; and collection is infrequent and not part of the app's
primary functionality. The Settings screen makes MAL sign-in/sync optional and shows the MAL
name, but completion-driven queue delivery is automatic rather than an affirmative choice on
each chapter. Therefore the exception cannot safely be used for this implementation.

Sources (read 2026-09-11): [Apple, App Privacy Details on the App Store](https://developer.apple.com/go/?id=info-1)
(definition and exception); [Apple, Learn More About App Privacy](https://apps.apple.com/us/iphone/story/id1538632801)
(the exception's current wording); [Apple, Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
(developer responsibility to report app and third-party-partner practices).

## What the shipped code sends

This is based on the checked-in source, not an assumption about a future feature:

- `MALAuthenticatedClient.currentUser()` sends the bearer token to MAL's `GET /v2/users/@me`
  and retains MAL `id`, `name`, and an optional avatar URL for Settings. The bearer token and
  refresh token are device-only Keychain material; they are not App Store data-label categories
  by themselves.
- `MALProgressCoordinator` queues a completed chapter only when the user is signed in and sync
  is enabled. It keys the queue by MAL user ID and MAL manga ID, and stores desired chapter
  progress plus completion timestamps in `MALProgressOutbox`.
- The drain first reads one title's `my_list_status`, then sends an authenticated form update to
  `/v2/manga/{manga_id}/my_list_status` containing `num_chapters_read` and, only when needed to
  add a missing title, `status=reading`. MAL's response is retained only to confirm delivery.
- The UI calls this optional feature “Sync reading progress” and separately controls automatic
  title addition. Local library/history stay on-device, but MAL receives the account identity and
  progress when the feature is enabled.

The relevant first-party API contract is also recorded in [the repository's MAL API research](2026-08-21-mal-oauth-and-manga-progress-api.md), which links to MAL's official OAuth and API
references.

## Recommended App Store Connect answers

For the shipped app, answer **Yes, we collect data from this app**, because data is transmitted
to MAL and retained there. Declare the following conditional collection (users who never sign in
to MAL do not generate it):

| Apple data type | Linked to user | Used for tracking | Purpose | Why |
|---|---:|---:|---|---|
| **Name** | Yes | No | App Functionality | MAL profile name is fetched and associated with the signed-in MAL account in Settings. |
| **User ID** | Yes | No | App Functionality | MAL account ID identifies which account owns the queued/read progress. |
| **Product Interaction** | Yes | No | App Functionality | Completed reading progress (`num_chapters_read`) is sent to update the user's MAL list. Apple's category examples include saved place/progress in content. |

Do not declare tracking: there is no advertising, analytics, cross-app ad identity, or data-broker
use in the inspected code. Do not add email, contacts, location, photos, health, financial, or
diagnostic categories based on this feature. The avatar is an externally hosted profile image URL,
not the user's device Photos/Videos category.

The App Store answers are distinct from the manifest file, but they should agree with it. Apple's
[TN3184](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest?changes=latest_be_1)
(read 2026-09-11) says `NSPrivacyCollectedDataTypes` reports each data type collected by the app
or a third-party SDK and requires type, linked, tracking, and purpose keys. If the project elects
to encode app collection in its manifest, the corresponding entries are `Name`, `UserID`, and
`ProductInteraction`, linked `true`, tracking `false`, purpose `AppFunctionality`.

## Shipped mismatch and follow-up

`MangaCarta/PrivacyInfo.xcprivacy` currently has an empty `NSPrivacyCollectedDataTypes` array.
That matches the no-MAL/no-external-collection portion of the app, but not the MAL-enabled
behavior under Apple's current collection definition. The required follow-up is to update the
manifest and App Store Connect answers together; this research slice intentionally does not edit
the manifest or application code.

Apple also requires the privacy policy URL and says responses must include third-party partners
and remain accurate as practices change: [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy),
read 2026-09-11. The submission owner should ensure the policy names MAL, describes the fields
and retention/deletion path, and explains how to disable/revoke sync.

