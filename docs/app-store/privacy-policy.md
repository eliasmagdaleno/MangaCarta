<!--
Published at https://eliasmagdaleno.github.io/MangaCarta/privacy/ by .github/workflows/pages.yml
(this comment is stripped). Sources: the analytics design §2, §3, §4, §6, §7 and §10.3
(docs/superpowers/specs/2026-11-09-analytics-design.md, Amendment 2), the MAL label research
(docs/superpowers/research/2026-09-11-issue-149-mal-privacy-label.md) and submission-copy.md §5.
Published 2026-11-15, before analytics slice 2's server exists. When slice 2 deploys it: add the
D1 region to "Where it goes", recheck every claim against that build (in particular Cloudflare
request logging, Workers Logs and Logpush are OFF), and update the effective date.
-->

# MangaCarta Privacy Policy

**Effective:** 15 November 2026

MangaCarta is a manga reader for iPhone. This policy explains what leaves your device, who receives it,
and how to stop it. Most of what you do in MangaCarta never leaves your device at all.

## Who is responsible

MangaCarta is made by **Elias Magdaleno**, who is the controller of the data described in the
"Usage analytics" section. Contact: **eliasrmagdaleno@gmail.com**.

## What stays on your device

Your library, reading history, collections, settings, and any files you import (CBZ, ZIP, PDF) are stored
only on your iPhone. MangaCarta has no account system of its own and does not copy these to any server.
Deleting the app deletes them.

## Usage analytics (only if you agree)

MangaCarta can share a small amount of usage information to improve its recommendations. **Nothing is
recorded or sent until you agree.** The first time you open a version with analytics, a card at the top of
Home asks you:

- In the European Union, the EEA and the United Kingdom, or if your region can't be determined, it asks
  "Help improve recommendations?" with **Share** and **Not now**.
- Everywhere else, it explains what is shared and offers **OK** and **Turn off**. Tapping **OK** is your
  agreement.

Until you tap one of these buttons, nothing is collected. You can turn analytics off at any time in
**Settings › Privacy**, which withdraws your agreement.

### What is sent

Each event contains only:

- a random analytics ID created on your device when you agree (not your Apple ID, not an advertising
  identifier, and not your MyAnimeList account);
- the day it happened (in UTC, with no time of day);
- the app version;
- what happened, from a fixed list:
  - **titles you save, remove, or finish a chapter of**, identified only by their public MyAnimeList and
    AniList numbers, with the chapter number when you finish one;
  - **your responses to recommendations** ("Not interested", "More like this") and which recommendation you
    opened and its position in the list, by those same numbers;
  - **which features you use**: that the app was opened that day, that the reader was opened and in which
    reading direction, that a search was run (never what you searched for), that a local import finished (as a
    rough count of files: 1, 2–9, or 10+), that a source was installed (only whether it is general, mixed or
    adult — never which source), and when certain settings are switched on or off.

You can see the events waiting to be sent, and your analytics ID, in **Settings › Privacy › What is sent**.

### What is never sent

Titles or any other text, search queries, file or folder names, anything about files you imported, which
sources you use, chapter or page details beyond the chapter number above, image addresses, repository
addresses, exact times, your MyAnimeList username or ID, advertising identifiers, contacts, location, or
photos. **Nothing about adult-classified titles is ever sent**, whatever your adult-content setting, and
**nothing about a title you also have as an imported file is ever sent.**

### Why

To improve MangaCarta's recommendations — by tuning how the app weighs what you've read, and by counting
which titles readers tend to save together — and to understand which features are used.

Analytics is **not used for advertising, not sold, and not shared with data brokers.** It is not combined
with data from other companies' apps or websites.

Shared recommendations are built only from counts across at least 20 different analytics IDs. These counts
contain no analytics IDs and say nothing about any one person.

### Where it goes

Events are sent in batches to a server run for MangaCarta on **Cloudflare** (Cloudflare, Inc., a US company).
**Your IP address is not stored.** The server reads only the event contents, and
Cloudflare's request logging for this service is switched off.

### How long it is kept

Events are kept for **12 months** and then deleted automatically. The recommendation counts described above
are kept for as long as they are useful; they contain no identifiers.

### Deleting your data

- **Turning analytics off** stops recording immediately, deletes the events waiting on your device, deletes
  your analytics ID, and asks the server to delete every event stored under that ID. If you're offline, the
  app keeps trying on later launches for up to 30 days.
- **Settings › Privacy › Reset analytics ID** does the same deletion and starts a new ID, without turning
  analytics off.
- **Settings › Privacy › Delete my analytics data** deletes everything as above.
- **Deleting the app does not reach the server.** Events already sent then expire after 12 months. To have
  them deleted sooner, email **eliasrmagdaleno@gmail.com** with your analytics ID (copy it from
  **Settings › Privacy › What is sent** before deleting the app).

Removing one person's events does not change the recommendation counts already calculated, since those
counts are not about any one person.

To ask what is stored under your analytics ID, email **eliasrmagdaleno@gmail.com** with the ID.

### Legal basis

Your consent, in every region. You can withdraw it at any time by turning analytics off.

## MyAnimeList sync (optional)

If you sign in to MyAnimeList in Settings and turn on **Sync reading progress**, MangaCarta sends your
reading progress to your MyAnimeList account: when you finish a chapter, it updates the number of chapters
read for that title, and can add a title to your list as "Reading". To do this, MangaCarta reads your
MyAnimeList username, user ID and avatar to show them in Settings.

This information goes to MyAnimeList, not to the developer, and is handled under
[MyAnimeList's privacy policy](https://myanimelist.net/about/privacy_policy). Your sign-in tokens are stored
only in your device's Keychain. You can turn sync off or sign out at any time in Settings.

## Sources you install

MangaCarta comes with no manga content. You add sources from repositories you choose, and the app then
fetches titles, chapters and pages directly from those sites. Those sites receive the requests your device
makes to them, under their own policies.

Some sources ask the app to send them a **page-loading report**: for each page image downloaded from that
source, the image address, whether it loaded, whether it came from the cache, its size, and how long it took.
These reports go only to that source's own operator, never to the developer. They are sent without cookies
and without any account or device identifier. The app tells you when a source you install, or an update to
one, sends these reports.

## Public catalogue data

To show genres and recommendations, MangaCarta downloads public information from MyAnimeList and AniList.
These requests do not include your library, your history, or any account.

## Children

MangaCarta is rated 16+ on the App Store and is not directed to children.

## Changes

If this policy changes, the new version will be posted at this address with a new effective date.

## Contact

**Elias Magdaleno** — **eliasrmagdaleno@gmail.com**
