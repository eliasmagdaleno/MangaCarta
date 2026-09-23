# App Store submission copy

**Status: DRAFT for owner editing (2026-09-22).** This file owns the *text* submitted to App Store
Connect: review notes, age-rating answers and listing copy. The *decisions* behind that text belong
to the ADRs, which are linked here rather than repeated:

- [ADR-0003 Amendment 6](../adr/0003-extension-substrate.md) (PR #215): no built-in or bundled
  Source, and no default, suggested or linked repository.
- [ADR-0022](../adr/0022-no-adult-source-in-the-release-build.md) Amendment 2: the declared-age
  gate for `mixed` / `adultOnly` installs.
- ADR-0025 and the local import spec (PR #216): the first-run purpose is importing CBZ/ZIP/PDF.

**Supersedes** the "App Store answers" bullets in ADR-0022 Amendment 2. Those were written for a
build with two content sources. ADRs are amended, never corrected, so ADR-0022 needs an amendment
that points here (owner decision 1). Guideline quotes were read on 2026-09-22 from
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
> (a declared-age gate); if they decline, nothing is installed. To try this flow, use the test
> repository at [[test repository URL containing only our own sample content, or delete this
> sentence]].
>
> No login, no purchases, no ads. Contact: [[name, email, phone]].

Notes on the text:

- It does not volunteer guideline numbers. That instruction comes from ADR-0022 Amendment 2 and is
  kept.
- The test-repository sentence is optional (decision 3). A test repository makes the plug-in flow
  testable, but it is a URL the team hands out. It must contain only owned sample content and must
  not be the first-party engines repository (ADR-0003 A6, decision 2).
- "Import from Files" and the "does not provide content" line must match the first-run UI as
  shipped. Recheck them once #216's UI lands.

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

**Recommendation for decision 2:** answer Mature or Suggestive Themes and Cartoon or Fantasy
Violence as **Infrequent/Mild**, and sexual content as None. That lands around **13+**. Reasoning:
guideline 4.7 says "you are responsible for all such software offered in your app". The app offers
no plug-ins itself, but typical manga includes mild violence and suggestive themes, so a 4+ rating
invites a reviewer to test that claim. Adult-class plug-ins are rated above the app, and 4.7.5's
age gate covers them without raising the app's own rating. The conservative alternative is
**16+ or 18+** (Paperback is rated 16+). It costs reach but leaves nothing to dispute.

## 3. Listing copy

Constraints from ADR-0003 A6: no site names, no "free manga", no copyrighted titles or art.
Guideline 2.3.7 also bars trademarked terms and other apps' names from metadata and subtitles.

**Name:** MangaCarta (10 / 30)

**Subtitle** (26 / 30): `Read your comics, your way`
Alternative: `CBZ, ZIP & PDF comic reader` (27).

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
> • Chapters detected from folders inside an archive, with series details read from ComicInfo.xml
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
> • Your library and history stay on your device. No account, no ads.
>
> MangaCarta does not provide or host content. You are responsible for having the rights to what
> you read.

Before submitting, check every bullet against the shipped build. ComicInfo parsing is in #216's v1
scope but not yet built. "No ads" and the privacy line must match the privacy label and #149's
policy.

**Screenshots:** use only original or public-domain art [[owner-supplied]]. Show no site UI and no
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
