# Issue #150 — MangaCarta name-clearance findings

**Checked:** 2026-09-11 (Pacific). **Owner:** this document owns the search record, risk analysis,
and options; #150 links here rather than duplicating it. This is a screening assessment, not a
legal clearance opinion.

## Search performed and limits

I repeated the exact and variant searches for `MangaCarta`, `Manga Carta`, `Magna Carta`, and
`MagnaCarta` across web-indexed App Store pages and the public iTunes Search API context from the
issue. No exact `MangaCarta` app listing surfaced. The App Store developer page for **Magna Carta
Technologies LLC** is still indexable, but the associated `Magna Carta AR` listing is now reported
as archived (last seen 2026-03-08): [archived listing](https://appshunter.io/ios/app/magna-carta-ar/id1502441974),
read 2026-09-11. This is not evidence that the name is clear; App Store search is not a trademark
search and third-party archives can lag removals.

I reached the current USPTO Trademark Search UI at [tmsearch.uspto.gov/search](https://tmsearch.uspto.gov/search/)
and verified its wordmark search interface on 2026-09-11. It is a JavaScript/AWS-WAF-backed UI;
there is no open query endpoint I could use unattended from this worktree, so I could not produce
a reproducible USPTO result set for the exact term in this pass.

I also checked the official TSDR routes/documentation. TSDR's browser shell is reachable, and its
FAQ gives the direct status/document form `https://tsdrapi.uspto.gov/ts/cd/casestatus/sn<SERIAL>/...`.
The actual TSDR API requires a registered API key, so no authenticated TSDR case query was made:
[USPTO TSDR FAQ](https://tsdr.uspto.gov/faqview), [USPTO trademark bulk data/TSDR API](https://www.uspto.gov/trademarks/apply/check-status-view-documents/trademark-bulk-data),
read 2026-09-11. The USPTO open-data/API documentation was reachable, but it did not provide an
unauthenticated name-search result or a substitute for the Trademark Search UI in this run.

One important correction to the first pass: the public record that ties **Magna Carta Technologies,
LLC** to mobile AR software is **TAGR**, serial **88319949**, filed 2019-02-28; its identified
goods are downloadable mobile augmented-reality software. The indexed record reports the filing
and goods, while a current third-party status index reports it dead (status date 2021-08-16):
[filing record](https://uspto.report/TM/88319949/RFA20190304083324/), read 2026-09-11.
That record is not a registration for the words “Magna Carta”; the owner name is the source of the
proximity noted in #150. The App Store archive describes `Magna Carta AR` as an AR social network,
not a manga reader: [archive details](https://appshunter.io/ios/app/magna-carta-ar/id1502441974).

## Magna Carta proximity

The marks are visually and aurally close enough to merit a human decision: **MangaCarta** and
**Magna Carta** share the same two-word cadence and differ principally by transposition of `ng`/
`gn` plus spacing. Their meanings diverge: “Manga” signals Japanese comics, while “Magna Carta”
is the historical charter. The goods and channels are materially different: MangaCarta is a
manga-reading app; the located Magna Carta AR product was augmented-reality/social location
software. That relatedness difference substantially lowers confusion risk, but it does not make
the risk zero—Apple itself advises choosing a distinctive name and avoiding names too similar to
existing apps: [Creating Your Product Page](https://developer.apple.com/app-store/product-page/),
read 2026-09-11.

There is no responsible “cleared” conclusion from this depth. The strongest evidence found is a
historical, apparently dead AR mark/app—not a live identical mark in the same goods. Absence of
evidence at this depth remains weak evidence of absence, especially for common-law use, state
registrations, pending applications, phonetic variants, and marks in related entertainment or
software classes.

## Options and recommendation

1. **Proceed as-is (lowest immediate cost).** Reasonable if launch value outweighs residual legal
   risk, with a written decision acknowledging that no professional clearance was obtained. Do
   not describe this as trademark-cleared.
2. **File/register now (roughly $350 USPTO fee per class, plus counsel).** USPTO's current base
   electronic application fee is $350 per class; custom/insufficient identifications can add fees:
   [USPTO fee information](https://www.uspto.gov/trademarks/trademark-fee-information), read
   2026-09-11. Filing does not eliminate refusal/opposition risk and should follow clearance.
3. **Commission a professional U.S. clearance search (recommended before investing heavily).**
   A practical budget is roughly **$1,000–$2,000** for a comprehensive search with written legal
   opinion, commonly about **one to two weeks**; quotes vary by scope and urgency. This estimate
   is a market range, not a USPTO fee; one current published range is [GleanMark's 2026 guide](https://gleanmark.com/insights/trademark-attorney-cost-complete-fee-guide),
   read 2026-09-11. Ask counsel to search federal/state databases, common-law web use, App Store
   and Google Play, domains, and related entertainment/software classes, with an explicit opinion
   on Magna Carta/MangaCarta.
4. **Change the name.** This removes the specific proximity question but costs the product/app
   identity already minted in ADR-0023 and creates migration/metadata work. It is the prudent
   option if counsel finds a live related mark or the owner wants near-zero naming risk.

My recommendation is **commission the professional search, then proceed if its written opinion
rates the risk acceptable**. If budget makes that impossible, proceeding as-is is defensible as a
conscious risk decision because the located AR mark appears historical/dead and the goods are
unrelated—but it should not be recorded as clearance or registration.

## App Store listing blockers separate from trademark clearance

Apple's current App Store rules say an app name is 2–30 characters and may be used for one app per
localization; if unavailable, a trademark owner can submit a claim: [Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app),
read 2026-09-11. `MangaCarta` is 10 characters, so it meets the length rule. The launch owner
still needs to verify availability while creating the App Store Connect record, hold the matching
bundle ID, provide a privacy-policy URL, support URL, age rating, content-rights declaration,
category, screenshots/description, and complete App Privacy. None of those metadata checks was
performed from this worker account, and name availability is not a trademark clearance.

