# App Store submission copy

**Status: DRAFT for owner editing (updated 2026-09-25).** This file owns the *text* submitted to App Store
Connect: review notes, age-rating answers and listing copy. The *decisions* behind that text belong
to the ADRs, which are linked here rather than repeated:

- [ADR-0003 Amendment 6](../adr/0003-extension-substrate.md): no built-in or bundled
  Source, and no default, suggested or linked repository.
- [ADR-0022](../adr/0022-no-adult-source-in-the-release-build.md) Amendment 2: the declared-age
  gate for `mixed` / `adultOnly` installs.
- [ADR-0025](../adr/0025-local-files-as-a-source.md) and the
  [local import spec](../superpowers/specs/2026-09-22-local-import-design.md): the first-run
  purpose is importing CBZ/ZIP/PDF.

**Supersedes** the "App Store answers" bullets in ADR-0022 Amendment 2. Those were written for a
build with two content sources; ADR-0022 Amendment 5 points here. Guideline text was checked on
2026-09-25 against
<https://developer.apple.com/app-store/review/guidelines/> and
<https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/>.

Placeholders are in `[[double brackets]]`.

---

## 1. App Review notes

> MangaCarta is a reader for comics and manga the user already has. It ships with no content. It
> does not host content, and it does not link to, suggest or preinstall any content service.
>
> **How to test (no account needed):**
> 1. Download the sample file from [[URL to sample CBZ, original/public-domain art supplied by the
>    owner]] and save it to Files. It is also attached to this submission as [[filename]].
> 2. Launch MangaCarta. The first screen explains that the app does not provide content and offers
>    **Import from Files**.
> 3. Choose the sample file. It appears in Library; tap it to read. Try paged and vertical modes,
>    right-to-left, pinch zoom, and read/unread marks. PDF and ZIP files work the same way.
>
> **Optional: repositories.** In Settings › Repositories, a user can add a repository by entering a
> URL they found themselves. A repository lists configuration-backed JavaScript plug-ins. They run
> in a sandboxed JavaScriptCore context with a fixed host API and cannot change the app's features.
> The app ships with no repository and no repository URL, and neither our App Store page nor our
> website lists one. Each plug-in declares a content class. Plug-ins declared as containing adult
> content are hidden by default. Installing one requires the user to confirm they are 18 or older
> (a declared-age gate); if they decline, nothing is installed.
>
> No account is needed to import and read local files. There are no purchases or ads. Contact:
> [[name, email, phone]].

Notes on the text:

- It does not volunteer guideline numbers. That instruction comes from ADR-0022 Amendment 2 and is
  kept.
- **No test repository is given to App Review (owner decision 3, 2026-09-24).** Handing Apple a
  URL cuts against "the app ships and suggests no repository", and local import is the path
  reviewers are meant to test. If a reviewer asks to see plug-ins working, create a repository with
  only owned sample content then — never the first-party engines repository (ADR-0003 A6).
- "Import from Files" and the "does not provide content" line match the current empty-state UI;
  recheck them against the release build after compiled and bundled Sources are removed.

## 2. Age-rating questionnaire

These are the current App Store Connect categories; the resulting tiers are 4+, 9+, 13+, 16+ and
18+. Recommended answers:

| Item | Answer | Reasoning |
|---|---|---|
| Parental Controls | No | The app has none. |
| Age Assurance | **Yes** | Apple defines it as a "mechanism to confirm an individual's age meets the age requirement for accessing specific content". The declared-age gate (ADR-0022 A2) is that mechanism, and 4.7.5 requires one for plug-ins rated above the app. |
| Unrestricted Web Access | No | Apple's definition: "users can navigate to any webpage within the app". The only web views are the off-screen extractor and the challenge sheet, which appears only for a site the user's own plug-in requested. Neither has an address bar or free navigation. Re-check this answer if the sheet ever gains outbound links. |
| User-Generated Content | No | Apple's definition: "broad distribution of content created by users". Users cannot post or share anything with each other, so guideline 1.2's moderation duties do not apply. |
| Social Media / Messaging and Chat / Advertising | No | The app has none of these. |
| Mature themes, Violence, Sexuality or Nudity (all sub-items) | **See decision 2** | The binary contains none. All content comes from the user's own files and from plug-ins the user installs. |
| Medical/Wellness, Chance-Based Activities | None / No | The app has none of these. |

**Decision 2 (owner, 2026-09-24): target 16+.** Answer each content question accurately for the
release build. If Apple's questionnaire assigns a lower rating, use App Store Connect's
**Override to Higher Age Rating** to select 16+; do not change content answers merely to reach
the target tier.

Reasoning: first-party manga apps rate lower — Shonen Jump, VIZ Manga and MANGA Plus are all
**13+** (checked 2026-09-24), each listing sexual content or nudity as infrequent. But each of
those apps curates every title it carries and so knows its own worst case. MangaCarta cannot: a
plug-in the reader installs can bring in seinen with graphic violence or nudity without declaring
itself adult, and guideline 4.7 makes the app responsible for what plug-ins offer. 16+ matches
that reach, and matches Paperback. Plug-ins declared `mixed`/`adultOnly` are still behind the
declared-age gate (4.7.5), which covers content above 16+.

## 3. Listing copy

Constraints from ADR-0003 A6: no site names, no "free manga", no copyrighted titles or art.
Guideline 2.3.7 also bars trademarked terms and other apps' names from metadata and subtitles.

**Name:** MangaCarta (10 / 30)

**Subtitle** (owner decision 5, 2026-09-24): `CBZ, ZIP & PDF comic reader` (27 / 30). PDF import
shipped in #235. It states what the app does, which is the 4.2
argument. (Rejected: `Read your comics, your way` — friendly but says nothing a reviewer can test.)

**Keywords** (99 / 100, comma-separated, no spaces):
`cbz,comic,reader,pdf,zip,webtoon,manhwa,manhua,library,offline,import,files,panel,chapter,extension`

**Promotional text** (up to 170 characters):
> Import your CBZ, ZIP and PDF comics from Files and read them in a reader built for manga:
> right-to-left, vertical scroll and smooth zoom.

**Description:**

> MangaCarta is a reader for the comics and manga you already own.
>
> Import CBZ, ZIP and PDF files from the Files app. MangaCarta arranges them into a library with
> covers, chapters and your reading progress.
>
> READ THE WAY THE BOOK WAS MADE
> • Right-to-left, left-to-right and vertical scroll modes
> • Smooth pinch-to-zoom and panning on every page
> • Chapters detected from folders inside an archive
>
> KEEP TRACK
> • Remembers your page in every chapter
> • Mark chapters read or unread, one at a time or in bulk
> • Unread counts across your library
>
> EXTEND IT YOURSELF
> • Advanced users can add plug-in repositories by URL. MangaCarta does not provide, host or
>   recommend any repository or content.
>
> PRIVATE BY DESIGN
> • Imported files stay on your device. No account required to read them. No ads.
>
> MangaCarta does not provide or host content. You are responsible for having the rights to what
> you read.

Before submitting, check every bullet against the release build — **this is a checklist, not
copy to paste.** PDF import and the "Import from Files" empty state have shipped; ComicInfo
parsing has not, so the description does not claim it. The compiled MangaDex Source and bundled
WeebCentral package still need removal before the no-content claims become true. Check the privacy
line against the privacy label and #149's policy.

**Screenshots:** use only original or public-domain art [[owner-supplied — owner decision 4, open]]. Show no site UI and no
recognisable series.

## 4. Guideline risk checklist

| Guideline | Risk | Mitigation |
|---|---|---|
| **4.2 Minimum Functionality** ("not particularly useful … adequate utility"); **4.2.2** (not a "content aggregator") | An empty reader looks like a shell whose only use is loading third-party sites. | Local import is the first-run purpose and the path reviewers test. The review notes lead with it and ship a sample file. The description leads with files, not plug-ins. Empty states point to import (ADR-0003 A6 consequences). |
| **5.2.3** ("should not facilitate illegal file sharing or … download media from third-party sources … without explicit authorization") | Plug-ins that fetch and cache chapters from third-party sites can read as facilitating infringement. An offline-download feature would make this worse. | No bundled or built-in Source, and no default or linked repository (A6). No site names and no "free manga" anywhere. The first-run screen and description both state the app provides no content. No sharing or export of plug-in content. Takedown requests are honoured promptly. |
| **5.2.1** (no protected third-party material without permission) | Copyrighted art in screenshots, the sample file or metadata. | Only owner-supplied original or public-domain art. Keywords avoid series titles and trademarks (also required by 2.3.7). |
| **1.1.4** (overtly sexual or pornographic material) | Adult plug-ins can be reached from the app. | The declared-age gate hides adult Sources by default, and the app never lists or recommends them (ADR-0022 A2). This meets 4.7.5's "age restriction mechanism based on verified or declared age". |
| **1.2 User-Generated Content** | A reviewer classifies repositories as user-generated content and asks for filtering, reporting and blocking. | ADR-0022 A2 judged 1.2 a poor fit because users cannot post or share anything with each other. Answer UGC "No". If Review raises it anyway, the fallback is a report/contact link, and then having the installer refuse adult classes (ADR-0022 A2 consequences). |
| **4.7 / 2.5.2** (plug-ins; downloaded code must not change features) | Plug-ins read as downloaded code. | Plug-ins run in a JavaScriptCore sandbox with a fixed host API; they supply data, not features. 4.7.4's index requirement has nothing to apply to while the app offers no repository. |
