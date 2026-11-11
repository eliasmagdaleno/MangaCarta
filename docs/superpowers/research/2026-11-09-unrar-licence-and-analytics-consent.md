# UnRAR licence and default-on analytics consent

> **Research, not legal advice. A qualified lawyer must review before analytics slice 2 ships.**

**Checked:** 2026-11-10 (Pacific). Every source below was read that day unless a row says
otherwise. **Owner:** this document owns the research findings on the UnRAR licence and on consent
for product analytics. The local-formats spec
(`docs/superpowers/specs/2026-11-09-local-formats-cbr-epub-folders-design.md` §2) and the analytics
spec (`docs/superpowers/specs/2026-11-09-analytics-design.md`, on branch
`eliasmagdaleno/spec-analytics`) should link here, not restate it.

**How to read the marks.** **Verified** means the quoted or summarised text was read in the
primary source in this session. **Unverified** means it was not, and the reason is given.
**Inference** marks a conclusion drawn from verified text. An inference is not a quote and not a
legal opinion. Quotes are kept under 30 words each.

## Summary

- **UnRAR may ship in a closed-source App Store binary.** It allows decompression in any software,
  free of charge. It forbids building a RAR-compatible archiver or re-creating RAR compression.
  The copy in `Unrar.swift` 0.5.4 is **modified**, which brings in an attribution condition. Put
  the full paragraph 2 of `license.txt` into the in-app acknowledgements.
- **Apple's App Review Guideline 5.1.1(ii) is the largest finding, and it applies everywhere.** It
  says apps that collect usage data "must secure user consent for the collection". It does not
  depend on region. A default-on design that sends before the reader acts needs a lawyer's or
  App Review's reading of what counts as "consent". The analytics spec does not mention this.
- **EU/EEA: opt-in is confirmed.** Storing the install id and sending events derived from on-device
  activity both fall within ePrivacy Art. 5(3). No "strictly necessary" route fits. CNIL's
  exemption is unavailable for at least three separate reasons.
- **UK: opt-in is confirmed for the recommendation stream.** The new statistical-purposes exception
  permits default-on toggles. However, it does not allow keeping individual-level records after
  aggregation, and the spec keeps raw events for 12 months.
- **Switzerland: correction.** Neither the FADP nor TCA Art. 45c requires opt-in for this. Swiss law
  requires information plus a right to refuse. Explicit consent is required only for sensitive
  data or "high-risk profiling". Whether reading histories amount to that needs a lawyer.
- **US: the spec is confirmed in substance.** First-party analytics is not "sale" or "sharing". A
  small developer is very unlikely to meet any CCPA threshold. CalOPPA's privacy-policy duty may
  still apply, and Apple requires a policy regardless.
- **Apple label: correction.** Apple treats anything that is "Personal Data" under privacy law as
  linked to the user. A persistent install id with a usage history is very likely personal data
  under the GDPR, so Device ID should be declared **Linked: Yes**, not No.

---

## A. UnRAR

### A1. What the UnRAR licence permits and forbids

**Source:** `Sources/Cunrar/license.txt` and `Sources/Cunrar/readme.txt` at tag 0.5.4 (revision
`7216007a38ac122dbdeae26cfdaf7f10775c868f`), fetched raw from
<https://raw.githubusercontent.com/mtgto/Unrar.swift/0.5.4/Sources/Cunrar/license.txt> and
`…/readme.txt`, read 2026-11-10. To confirm that this is RARLAB's own text, I downloaded RARLAB's
current source, <https://www.rarlab.com/rar/unrarsrc-7.3.1.tar.gz> (UnRAR 7.30 beta 1), on
2026-11-10. Its `license.txt` and `readme.txt` are **byte-identical** to the vendored copies
(`diff` exit 0). **Verified.**

What it says (**verified**):

- §1: all copyrights are owned by Alexander Roshal.
- §2, permitted use: UnRAR source "may be used in any software to handle RAR archives without
  limitations free of charge".
- §2, forbidden use: it "cannot be used to develop RAR (WinRAR) compatible archiver and to
  re-create RAR compression algorithm, which is proprietary."
- §2, condition on **modified** source: distributing modified source "in separate form or as a
  part of other software is permitted", provided that the "full text of this paragraph" is
  included "in license, or in documentation if license is not available, and in source code
  comments of resulting package."
- §3: "It is allowed to distribute UnRAR inside of other software packages."
- §4: no warranty. §5: installing and using signifies acceptance. §6: anyone who disagrees must
  remove UnRAR and stop using it.
- `readme.txt` §4 states the modified-source condition differently. The documentation and source
  comments must say "that the code may not be used to develop a RAR (WinRAR) compatible archiver."

**Can it be used to create RAR archives?** **No.** §2 forbids developing a RAR-compatible archiver
and re-creating the compression algorithm. MangaCarta only reads archives, which is the permitted
use. **Verified** (licence). Whether the app only reads is a fact about the local-formats spec,
whose §2 says so.

**Can it ship in a closed-source binary?** **Yes**, on the licence's own terms. §2 allows use "in
any software" and §3 allows distribution "inside of other software packages". Nothing in either
file requires releasing the app's own source. **Verified** (licence). That the licence imposes no
copyleft obligation is an **inference** from the absence of any such term.

**Is the vendored copy modified? Yes, so the §2 condition applies.** I read the package's history
with `gh api` on 2026-11-10 (**verified**):

- Commit `006a2c03` ("HACK: use utf for Linux", 2021-01-30) edits `unicode.cpp`, adding
  `// mtgto: Use WideToUtf for Linux` and `#elif defined(_APPLE) || 1`. That line is still present
  at 0.5.4.
- `Sources/Cunrar/include/unrar.h` is a variant of RARLAB's `dll.hpp`. It adds
  `#include <wchar.h>`, and it differs in `RAR_DLL_VERSION` and in `ERAR_LARGE_DICT` (from
  `diff`).
- No vendored `.cpp` or `.hpp` file carries the §2 paragraph or the readme's sentence in a source
  comment. A `grep` for "UnRAR source code" and "may not be used to develop" found nothing.

**Inference:** `Unrar.swift` itself may not fully meet the "source code comments" part of the
condition. That is the package author's distribution, not MangaCarta's. MangaCarta distributes a
compiled binary, not source. Whether §2's condition on modified source reaches a compiled binary
is ambiguous in the text ("as a part of other software"). The conservative reading, which is cheap
to follow, is that it does. **Needs a lawyer** only if the owner wants to rely on the narrower
reading.

**Other notices in the same directory.** `acknow.txt` (read 2026-11-10, **verified**) says the CRC32
code is based on Intel's Slicing-by-8 under a BSD licence. The bundled BSD text requires that
binary redistributions "must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation". **Inference:** the app's acknowledgements should also
carry that Intel BSD notice, which the local-formats spec does not mention. Whether the
Slicing-by-8 code is actually compiled into the RAR5 decoder path was **not checked**
(unverified), so including the notice is the safe default.

### A2. App Store compatibility and attribution

**Apple's terms.** Apple Developer Program License Agreement, web version, page date March 15, 2026,
<https://developer.apple.com/support/terms/apple-developer-program-license-agreement/>, read
2026-11-10 (**verified**):

- Apple defines FOSS as software whose terms, among other things, require it "to be redistributed
  free of charge", for example the GPL or LGPL.
- §3.3 (the "(v)" item in the application requirements): "If Your Application … includes any FOSS,
  You agree to comply with all applicable FOSS licensing terms." It also forbids FOSS use that
  "would cause the non-FOSS portions of the Apple Software to be subject to any FOSS licensing
  terms".
- The agreement also requires that licensing terms of third-party code included in the app "will
  be consistent with and not conflict with the digital signing or content protection aspects of
  the Program".

**Inference:** UnRAR's terms impose no copyleft, no source-disclosure duty and no condition that
conflicts with code signing or DRM. Its "free of charge" is a grant ("may be used … free of
charge"), not a requirement that the work be redistributed free. So UnRAR is probably not "FOSS"
in Apple's defined sense. Even if it were, the only duty is to comply with its terms, which a read-only
decoder plus attribution does. I found no Apple term that UnRAR conflicts with. The App Review
Guidelines (read 2026-11-10) have no section on third-party code licences. **Needs a lawyer** only
for a formal opinion. Nothing found points to a conflict.

**Attribution: required, and where.**

- The UnRAR §2 paragraph, in full, starting from "UnRAR source code", goes "in license, or in
  documentation if license is not available". **Verified** (licence). MangaCarta has no licence
  file for end users. **Inference:** the in-app acknowledgements screen, and any public
  acknowledgements page, is the "documentation". Ship the paragraph verbatim. Also add the
  readme's sentence that the code "may not be used to develop a RAR (WinRAR) compatible archiver".
  That costs one line and satisfies both wordings.
- The "source code comments of resulting package" part: **inference**. MangaCarta does not
  distribute source, so there is no resulting source package to comment. If the adapter file is
  ever public, as the main repository is, add the paragraph as a comment in
  `RARArchiveReader.swift`. It costs nothing and covers the case.
- The MIT notice for `Unrar.swift` (A3) and the Intel BSD notice (A1).

The local-formats spec's statement that acknowledgements must include "the complete UnRAR legal
paragraph/licence text" is **confirmed**. It should name paragraph 2 explicitly, add the Intel BSD
notice, and note that the vendored source is modified.

### A3. Licence of `mtgto/Unrar.swift`

**Source:** <https://raw.githubusercontent.com/mtgto/Unrar.swift/0.5.4/LICENSE.txt>, the README's
"License" section at 0.5.4, and GitHub's licence API (`gh api repos/mtgto/Unrar.swift`, which
returns `spdx_id: MIT`). All read 2026-11-10. **Verified.**

- The Swift part is the **MIT License**, "Copyright (c) 2021 mtgto". The README says the "Swift
  parts of this software is released under the MIT License" and the "C++ library has different
  license".
- MIT's single obligation: "The above copyright notice and this permission notice shall be included
  in all copies or substantial portions of the Software."
- **No additional obligations** beyond MIT and the bundled UnRAR terms were found in the repository
  files at 0.5.4. The tree has no other licence or NOTICE file (tree listing via `gh api`,
  **verified**). The package's test fixtures, such as `sfx.exe` and the `.rar` files, are not
  linked into a client app. That is an **inference** from SPM's handling of test targets, which I
  did not check.

---

## B. Consent for default-on product analytics

The design under review stores a random per-install UUID on the device. It sends events naming the
public MAL and AniList ids of titles saved and finished, plus feature counts, to a first-party
server. The purpose is to improve recommendations, never ads. Raw events are kept 12 months, and
the id is never rotated (analytics spec §2, §6, §7.1).

### B1. EU/EEA — ePrivacy Art. 5(3), EDPB Guidelines 2/2023, CNIL

**Art. 5(3) text.** Directive 2002/58/EC as amended by 2009/136/EC, consolidated version of
2009-12-19, <https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:02002L0058-20091219>,
read 2026-11-10 (**verified**). Storing information, or gaining access to information already
stored, in a user's terminal equipment "is only allowed on condition that the subscriber or user
concerned has given his or her consent". There are two exceptions. One is "the sole purpose of
carrying out the transmission of a communication". The other is "as strictly necessary in order
for the provider of an information society service explicitly requested by the subscriber or user
to provide the service".

**EDPB Guidelines 2/2023, Version 2.0, adopted 7 October 2024.**
<https://www.edpb.europa.eu/system/files/2024-10/edpb_guidelines_202302_technical_scope_art_53_eprivacydirective_v2_en_0.pdf>,
downloaded and text-extracted with `pypdf` on 2026-11-10. It has 15 pages, and its cover reads
"Version 2.0 / Adopted on 7 October 2024". **Verified.** This corrects the analytics spec's
statement that the text "could not be extracted".

- ¶12: "information" includes "both non-personal data and personal data". A random UUID counts
  even if it were not personal data.
- ¶33: when an entity "distributes software on the terminal equipment of the user that is stored
  and will then proactively call an … ('API') endpoint", "Such access clearly falls within the
  scope of Article 5(3) ePD".
- ¶36: storage includes "instructing software on the terminal equipment to generate specific
  information", including customised software.
- ¶44: an app using information "strictly inside the terminal" is not access "as long as the
  information does not leave the device". However, "when this information or any derivation of
  this information is accessed, Article 5(3) ePD would apply."
- ¶63: for "'unique identifier' collection on websites or mobile applications … a 'gaining of
  access' is taking place and Article 5(3) ePD applies."
- ¶4 and ¶40: the Guidelines "do not address" the exemptions, which "should be analysed on a
  case-by-case basis" under national transposition and authority guidance.

**Does this design fall within 5(3)? Yes.** Three acts each fall within it (**inference** from ¶33,
¶36, ¶44 and ¶63, all verified). The app writes `install.json`, which is storage. It reads the id
back and sends it, which is access. It sends events derived from on-device Library and History
state, which is "any derivation of this information" leaving the device.

**Is there a "strictly necessary" route? No.** Article 29 Working Party Opinion 04/2012 on the cookie
consent exemption (WP194),
<https://ec.europa.eu/justice/article-29/documentation/opinion-recommendation/files/2012/wp194_en.pdf>,
read 2026-11-10 (**verified**), §4.3 "First party analytics": analytics are "not strictly necessary
to provide a functionality explicitly requested by the user", because the user "can access all the
functionalities … when such cookies are disabled". The same is true here, because per-user
recommendations already run on the device (analytics spec §9). The opinion predates the EDPB but
remains the EU-level reading of the exemption. Whether the EDPB has since formally endorsed WP194
was **not checked** (unverified).

**CNIL's audience-measurement exemption.** There are two primary sources:

- CNIL Délibération n° 2020-091 of 17 September 2020, the guidelines, Article 5, "Cas spécifique
  des traceurs de mesure d'audience". Légifrance, <https://www.legifrance.gouv.fr/jorf/id/JORFTEXT000042388179>,
  read 2026-11-10 through a browser (**verified**). Audience-measurement trackers are exempt when
  their purpose is "strictement limitée à la seule mesure de l'audience … pour le compte exclusif
  de l'éditeur". They must "uniquement servir à produire des données statistiques anonymes", and the
  data "ne peuvent être recoupées avec d'autres traitements ni transmises à des tiers".
- CNIL developer guide, Sheet n°16 (11 June 2020),
  <https://www.cnil.fr/en/sheet-ndeg16-use-analytics-your-websites-and-applications>, read
  2026-11-10 (**verified**). It lists the conditions: inform users; let them object; purposes
  limited to "audience measurement; A/B testing"; no cross-checking with other processing; scope
  limited to "a single site or application editor"; truncate the IP's last byte; and "limit the
  lifetime of the trackers to 13 months". Once those conditions are met, "we therefore switch from
  an opt-in to an opt-out regime". The sheet adds that the exemption "may be subject to national
  variation", so it is French law, not EU law.

**Does the design qualify? No**, on three independent grounds (**inference** from the verified text):

1. **Purpose.** The main purpose is improving recommendations (co-occurrence, weight tuning), not
   audience measurement or A/B testing.
2. **Tracker lifetime.** The spec's id has "No automatic rotation" (§6). That breaks the 13-month
   tracker-lifetime limit, independent of the 12-month server purge.
3. **Anonymous statistics only.** Keeping per-install raw event histories is not "uniquement …
   données statistiques anonymes".

Feature counts alone could fit, but only with a rotating id (≤ 13 months), IP truncation (the spec
already stores none), and use limited to audience measurement. **Correction:** the spec says the
exemption "requires single-app identifiers, no user cohorts". The single-editor scope is verified.
"No user cohorts" does not appear in either CNIL text read here (**unverified**: no source found).
The spec also omits the 13-month lifetime, which is the condition this design fails most plainly.

**Does the GDPR legal basis matter, given 5(3) applies first?** Yes, separately. EDPB Opinion 5/2019
on the interplay between the ePrivacy Directive and the GDPR, adopted 12 March 2019,
<https://www.edpb.europa.eu/sites/default/files/files/file1/201905_edpb_opinion_eprivacydir_gdpr_interplay_en_0.pdf>,
read 2026-11-10 (**verified**). Its ¶41 example says the placing or reading "must comply with the
national provision transposing article 5(3)". In addition, "Subsequent processing of personal data …
must also have a legal basis under article 6 of the GDPR". Its ¶38 adds that where the ePrivacy
Directive "particularises" the GDPR, it takes precedence as lex specialis. **Inference:** in the
EU, 5(3) consent is the gate. Once that consent is obtained, consent is the natural Art. 6 basis
for the same processing. Relying on legitimate interest for the server-side processing would not
avoid the 5(3) consent. This document does not cover which basis governs the server-side
aggregation after consent (**needs a lawyer**).

### B2. UK — PECR regulation 6 as amended by the Data (Use and Access) Act 2025

**Statute.** legislation.gov.uk, PECR 2003 (SI 2003/2426), regulation 6 and Schedule A1, revised
text, <https://www.legislation.gov.uk/uksi/2003/2426/regulation/6> and
<https://www.legislation.gov.uk/uksi/2003/2426/schedule/A1>, read 2026-11-10 (**verified**).

- The new reg. 6(1) is "Subject to Schedule A1, a person must not store information, or gain access
  to information stored, in the terminal equipment". It was substituted on **5.2.2026** by the
  Data (Use and Access) Act 2025 s. 112(2), commenced by S.I. 2026/82. So it is **in force**.
- Sch. A1 para 5(1), the statistical-purposes exception, has five conditions. (a) The person provides
  an information society service. (b) The "sole purpose" is "to collect information for
  statistical purposes about how the service is used with a view to making improvements to the
  service". (c) Information is not shared except with someone assisting those improvements.
  (d) The user gets "clear and comprehensive information". (e) The user gets "a simple means of
  objecting, free of charge" and "does not object".

**ICO guidance.** "What are the exceptions?" in *Guidance on the use of storage and access
technologies*,
<https://ico.org.uk/for-organisations/direct-marketing-and-privacy-and-electronic-communications/guidance-on-the-use-of-storage-and-access-technologies/what-are-the-exceptions/>,
read 2026-11-10 through a browser, because direct fetches returned HTTP 403 (**verified**).

- It covers "the creation of aggregate statistical information" and "is about how your service is
  used, not about who uses it." It is not for "identifying, tracking or monitoring people".
- The ICO adopts the UK GDPR's definition of statistical purposes for this exception. That
  definition requires that the result "is aggregate data that is not personal data", and that it is
  not used "in support of measures or decisions with respect to a particular data subject".
- **Consent is needed** if you "retain the individual-level information (after aggregating it)".
  You "must only store individual-level information for as long as you need it".
- Consent is needed for "logs or recordings of individual visitors … and the actions they took" and
  for "tracking or profiling individual visitors or categories of visitors".
- Default-on is allowed: the "simple means of objecting" may be "toggles on by default, with the
  ability for users to change them to off at any time."
- A third-party provider must be a processor, not a joint controller.

**Would feature counts qualify?** **Probably yes, but not as the spec builds them** (**inference**).
`app_active`, `reader_opened`, `search_used` and the like are statistics about how the service is
used. However, the spec keeps every raw event, keyed by install id, for 12 months (§7.1). That is
retaining "individual-level information (after aggregating it)", which the ICO says needs consent.
To use the exception, feature events would need aggregation on a short cycle (the ICO suggests
daily) and deletion of the individual rows. Alternatively, they could carry no install id at all.

**Would per-install reading histories qualify?** **No** (**inference**). They are logs of individual
users' actions, retained per install. Their purpose is recommendation modelling, which is more
than statistics about how the service is used. The spec's §5.1 conclusion is **confirmed**, and its
ICO quotes match the page.

### B3. Switzerland — revFADP and the Telecommunications Act

**Sources.** Federal Act on Data Protection (FADP), SR 235.1,
<https://www.fedlex.admin.ch/eli/cc/2022/491/en>; Telecommunications Act (TCA), SR 784.10,
<https://www.fedlex.admin.ch/eli/cc/1997/2187_2187_2187/en>. English versions on Fedlex, read
2026-11-10 through a browser (**verified**). The English text is an unofficial translation. Only the
German, French and Italian versions are authentic, which is a general Fedlex fact I did not
re-check this session (**unverified**).

- **TCA Art. 45c**, the Swiss device-storage rule: processing data on external equipment is
  permitted "if users are informed about the processing and its purpose and are informed that they
  may refuse to allow processing." That is **opt-out**, not opt-in.
- **FADP Art. 6(6)**: if consent "is required", it must be voluntary, specific and informed.
- **FADP Art. 6(7)**: consent "must be explicitly given for" (a) sensitive data, (b) "high-risk
  profiling by a private person", or (c) profiling by a federal body.
- **FADP Art. 5(f)–(g)**: profiling includes predicting "personal preferences, interests".
  High-risk profiling means profiling that poses a high risk "by matching data that allow an
  assessment to be made of essential aspects of the personality".
- **FADP Arts. 30–31**: processing breaches personality rights if it is "contrary to the express
  wishes of the data subject". It may be justified by consent "or by an overriding private or public
  interest".

**Does Swiss law require opt-in for this design? Probably not. The spec's opt-in list is
corrected** (**inference**). Art. 45c needs information plus a right to refuse, which the spec's
global opt-out model already provides. Explicit consent is required only for sensitive data or
high-risk profiling. Manga titles saved and finished are not in the Art. 5(c) list of sensitive
data. Whether a reading history combined with recommendation modelling is "high-risk profiling" is
a judgement, and **needs a lawyer**. Adult-classified titles are already excluded (spec §3), which
lowers that risk. The owner may still keep Switzerland opt-in as policy. If so, the spec should
present that as a choice, not a legal requirement.

### B4. US — CCPA/CPRA, thresholds, other states

**Sources.** California Civil Code §1798.140 (definitions) and §1798.100 (notice at collection),
<https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?lawCode=CIV&sectionNum=1798.140>
and `…sectionNum=1798.100`. CPPA, "Updated Monetary Thresholds in CCPA",
<https://cppa.ca.gov/regulations/cpi_adjustment.html>. Business & Professions Code §§22575 and
22577 (CalOPPA), `…lawCode=BPC&sectionNum=22575` and `22577`. All read 2026-11-10 (**verified**).

**Is first-party product analytics "selling" or "sharing"?** **No**, on the definitions (**inference**
from verified text):

- "Sell" means making personal information available "to a third party for monetary or other
  valuable consideration" (§1798.140(ad)).
- "Share" means making it available "to a third party for cross-context behavioral advertising"
  (§1798.140(ah)). Cross-context behavioural advertising is targeting ads using activity "across
  businesses … other than the business … with which the consumer intentionally interacts" (§(k)).
- A "third party" excludes the business itself and "A service provider to the business"
  (§1798.140(ai)).

So events sent to the developer's own server, or to a hosting provider bound as a service provider,
and never used for ads, are neither sold nor shared. The provider contract must contain the
§1798.140(ag) prohibitions (no selling, no use outside the business purpose, no combining).
**Verified** as to the statute's terms. Whether a particular Worker or host contract meets them is
**unverified**, because no contract exists yet.

**Is the data "personal information"?** Very likely. The definition includes a "unique personal
identifier, online identifier" and "information regarding a consumer's interaction with an"
online service (my extract cut off at that word). A "unique identifier" includes "a device identifier … or other forms of persistent
or probabilistic identifiers" (§1798.140(v), (aj)). **Verified.**

**Thresholds.** CCPA applies only to a "business" that does business in California and meets at
least one of these (§1798.140(d)(1), **verified**):

- (A) annual gross revenue over $25,000,000, which the CPPA adjusted to **$26,625,000 effective
  1 January 2025** (CPPA page, **verified**);
- (B) "annually buys, sells, or shares the personal information of 100,000 or more consumers or
  households";
- (C) 50% or more of revenue from selling or sharing.

**Inference:** a solo developer with no ads and no sales meets none of them. Threshold (B) counts
buying, selling or sharing, not collecting. So **CCPA very likely does not apply**, and its
obligations follow only if it does. Those obligations are: notice "at or before the point of
collection" of categories, purposes and "whether that information is sold or shared"
(§1798.100(a), **verified**), a privacy policy, and opt-out rights. The right to opt out of sale or
sharing would have nothing to act on, since nothing is sold or shared (**inference**). The
privacy-policy and rights provisions (§§1798.105–.130) were **not read** this session
(unverified).

**CalOPPA applies regardless of size**, where it applies at all. It covers "An operator of a
commercial Web site or online service that collects personally identifiable information" about
California residents, who must "conspicuously post its privacy policy" (§22575(a), **verified**).
Its "personally identifiable information" is narrower than the CCPA's: name, address, email, phone,
SSN, "Any other identifier that permits the physical or online contacting of a specific
individual", and data kept in combination with those (§22577(a), **verified**). **Inference:** a
random UUID that cannot be used to contact anyone may fall outside it. This is moot in practice,
because Apple requires a privacy policy for every app (B5).

**Other state laws with opt-in requirements.** Using Virginia's Consumer Data Protection Act as the
representative model, read 2026-11-10 at <https://law.lis.virginia.gov/vacode/title59.1/chapter53/>
(**verified**):

- It applies to controllers that process personal data of "at least 100,000 consumers" in a year,
  or 25,000 plus over 50% of revenue from sales (§59.1-576(A)).
- A controller must not "process sensitive data concerning a consumer without obtaining the
  consumer's consent" (§59.1-578(A)(5)).
- Sensitive data covers race or ethnicity, religion, health diagnosis, sexual orientation,
  citizenship, genetic or biometric data, "personal data collected from a known child", and
  precise geolocation (§59.1-575).

**Inference:** manga reading events are not sensitive data under that list. The one live edge is
"a known child". If the app ever learns a user is under 13, which it currently does not, the
COPPA-linked rule would apply. Other states (Colorado, Connecticut, Texas and others) have similar
opt-in rules for sensitive data. They were **not read** (unverified, deliberately out of scope).
Data derived from adult-classified titles could arguably reveal "sex life", which is sensitive
under CCPA §1798.140(ae)(2)(C) (**verified** definition). The spec's §3 exclusion of adult titles
is what keeps this design clear of it.

### B5. Apple — ATT, privacy label, `PrivacyInfo.xcprivacy`, and Guideline 5.1.1

**Sources.** "User privacy and data use", <https://developer.apple.com/app-store/user-privacy-and-data-use/>.
"App privacy details on the App Store", <https://developer.apple.com/app-store/app-privacy-details/>.
App Review Guidelines, <https://developer.apple.com/app-store/review/guidelines/>. Apple's DocC
JSON for `NSPrivacyAccessedAPIType`,
<https://developer.apple.com/tutorials/data/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype.json>.
All read 2026-11-10 (**verified**).

**Does this design need the ATT prompt? No** (**inference** from verified text). Tracking is "linking
user or device data collected from your app with user or device data collected from other companies'
apps, websites, or offline properties for targeted advertising or advertising measurement
purposes", or "sharing user or device data with data brokers". This design does neither. The spec's
§6 is **confirmed**. It holds only while the analytics data is never combined with third-party data
for ads and never given to a data broker.

**Guideline 5.1.1(ii), which the spec does not address.** It says: "Apps that collect user or usage
data must secure user consent for the collection, even if such data is considered to be anonymous".
Apps "must also provide the customer with an easily accessible and understandable way to withdraw
consent." It also says apps relying on GDPR legitimate interest without consent "must comply with
all terms of that law." **Verified.** **Inference, and the most important open question in this
document:** this is an Apple requirement, not a regional law. It applies in the US too. In the
spec's opt-out regions, the first-launch notice offers "OK" / "Turn off" while collection is
already on. Whether App Review treats that as having "secured consent" is not answered by the
guideline text. A design that sends nothing until the reader taps "OK" is closer to the text than
one that sends from first launch. **Needs a lawyer, or an App Review query, before slice 2.**

**Guideline 5.1.1(i)**: every app must link a privacy policy in App Store Connect and in the app.
The policy must explain retention and deletion and "how a user can revoke consent and/or request
deletion". **Verified.** The spec's §10.3 list is consistent with this.

**Privacy label categories** (App privacy details page, **verified**):

- **Device ID**: "Such as the device's advertising identifier, or other device-level ID."
- **User ID**: "Such as screen name, handle, account ID, assigned user ID, customer number, or
  other user- or account-level ID that can be used to identify a particular user or account."
- **Product Interaction**: "Such as app launches, taps, clicks, scrolling information … or other
  information about how the user interacts with the app."
- **Analytics** purpose: "Using data to evaluate user behavior, including to understand the
  effectiveness of existing product features, plan new features".
- **Product Personalization** purpose: "Customizing what the user sees, such as a list of
  recommended products".

**Inference on the id's category.** A per-install random UUID is not tied to any account, so Device
ID ("other device-level ID") is the closer fit, and the spec's choice is **confirmed**. "assigned
user ID" in the User ID definition makes the choice arguable, so a reviewer could prefer User ID.
Neither choice changes the Tracking answer.

**"Linked to you": correction.** The page says data is linked unless protections are applied
"before collection to de-identify or anonymize it", such as "Stripping data of any direct
identifiers, such as user ID or name". It then states: "'Personal Information' and 'Personal Data',
as defined under relevant privacy laws, are considered linked to the user." **Verified.**
**Inference:** a persistent install id together with a 12-month event history is pseudonymous
personal data under the GDPR, which is why ePrivacy and GDPR apply at all. Under Apple's own rule
that makes it **linked**. The spec's "Device ID … Linked **No**" (§8) should become **Linked: Yes**,
which is the spec's own Open question 2 "stricter" option. Product Interaction is already linked
because of MAL, so it does not change.

**Purpose: Analytics, possibly also Product Personalization.** The co-occurrence table changes "what
the user sees" in More Like This and For You. **Inference:** if aggregated pair counts feed
recommendations shown to readers, Product Personalization is arguably also a purpose. If they are
used only for offline weight tuning, Analytics alone fits. The owner settles this when §9's
pipeline is final.

**`PrivacyInfo.xcprivacy` required-reason APIs** (`NSPrivacyAccessedAPIType` JSON, **verified**):

- **UserDefaults CA92.1**: access "user defaults to read and write information that is only
  accessible to the app itself." It does not permit reading what other apps or the system wrote.
  Keeping consent flags in the app's own defaults fits. The current manifest already declares
  CA92.1 (`MangaCarta/PrivacyInfo.xcprivacy:17-20`, read in this worktree).
- **File timestamp C617.1**: access "timestamps, size, or other metadata of files inside the app
  container, app group container, or the app's CloudKit container." The manifest already declares
  it (`:9-12`). Unlike DDA9.1, which forbids sending the information off-device, C617.1 has no
  off-device restriction. The analytics design sends no timestamps in any case.
- **Inference:** the design adds no new required-reason category. That holds only if the buffer
  code does not read the system boot time (for example for "at most once per UTC day" logic) or
  disk space. Those would need `SystemBootTime` or `DiskSpace` reasons. Use wall-clock `Date()`,
  which is not a required-reason API. That `Date()` is not covered is an **inference** from its
  absence from Apple's list.
- `Storefront` is not a required-reason API. The categories in the JSON are file timestamp, system
  boot time, disk space, active keyboards and user defaults. **Verified** by reading the category
  list.

### B6. How the app learns the region

**Apple APIs** (DocC JSON, read 2026-11-10, **verified**):

- `Storefront.countryCode`: "The three-letter code that represents the country or region
  associated with the App Store storefront", in "ISO 3166-1 Alpha-3".
- `Storefront.current`: "The current App Store storefront for product purchases." Its use is to
  "determine a customer's current storefront region".
- `Locale.current` is based on the system locale, "Any app-specific locale choice made in the
  Settings app", and "The availability of the preferred locale in the app". Apple's example: an app
  that supports only English returns an English locale on a Spanish-set device. `Locale.region`
  "represents the language's region" unless a custom region is set.

**Inference on `Locale.current`:** it is a formatting preference, not a location or residence
signal. Its value can also be shaped by which localizations MangaCarta ships. It is a weak fallback.

**What determines the applicable law?**

- **EU GDPR** (EDPB Guidelines 3/2018 on territorial scope, v2.1, adopted 12 November 2019,
  <https://www.edpb.europa.eu/sites/default/files/files/file1/edpb_guidelines_3_2018_territorial_scope_after_public_consultation_en_1.pdf>,
  `pypdf`, **verified**). Art. 3(2) is "not limited by the citizenship, residence or other type of
  legal status". "the location of the data subject in the territory of the Union is a determining
  factor", assessed "at the moment when the relevant trigger activity takes place". Targeting must
  be intentional. In Example 10, an app "exclusively directed at the US market", used by a US
  tourist in Europe, "is not subject to the GDPR". So the test is **physical location plus the
  controller's targeting**, not residence.
- **ePrivacy 5(3)** territorial reach is set by each Member State's transposition. **Unverified:**
  no national law was read.
- **UK, CCPA, Switzerland.** For California, "Consumer" means "a natural person who is a California
  resident" (§1798.140(i), **verified**). So the test is **residence**. UK GDPR Art. 3 and FADP
  Art. 3 were **not read** (unverified). UK GDPR is understood to mirror GDPR Art. 3, but that was
  not checked this session.

**Is the storefront a reasonable proxy?** **Inference:** yes, and better than locale. An App Store
storefront is tied to the account's country of billing, which is closer to residence (the CCPA test).
Making the app available on EU storefronts is itself targeting EU users (EDPB's intentional
targeting). It is imperfect for the location test. A US-storefront reader physically in Paris is,
on Example 10's logic, probably outside GDPR only if the app is "exclusively directed" at the US,
and MangaCarta is not. **Needs a lawyer** for whether a globally offered app owes GDPR or ePrivacy
protection to such a traveller. The practical consequence is small, because the spec defaults
unknown regions to off.

**Which way to fail.** **Inference:** fail closed (opt-in), as the spec does. The cost of wrongly
asking a US reader is a missing data point. The cost of wrongly collecting from an EU reader is
a breach of 5(3). Apple's 5.1.1(ii) points the same way everywhere. **Confirmed.**

---

## What this changes in the analytics design

**§5.1 — What the law says.** **Corrected in part.**

- EU: confirmed. Replace "the text could not be extracted … unverified" with the EDPB ¶33, ¶44 and
  ¶63 findings (B1).
- CNIL: corrected. Drop "no user cohorts", which was not found. Add the 13-month tracker lifetime,
  which the never-rotated id fails, and the "anonymous statistics only" condition. Note that the
  exemption is French and varies by country.
- UK: confirmed, with an addition. The ICO says keeping individual-level rows after aggregation
  needs consent, so even §2.3 counts fail the exception while §7.1 keeps raw events for 12 months.
- Switzerland: **corrected**. TCA Art. 45c is opt-out, and explicit consent attaches only to
  sensitive data or high-risk profiling. Whether that applies here **needs a lawyer**.
- US: confirmed. Add the verified CCPA definitions and thresholds, CalOPPA, and Virginia's
  sensitive-data model.
- **Add Apple Guideline 5.1.1(ii)** as a global constraint. **Needs a lawyer or App Review.**

**§5.2 — Behaviour.** **Needs a lawyer.**

- Option (c)'s EU/EEA and UK rows are confirmed as opt-in.
- Moving Switzerland to the default-on group is legally supportable on the text read. Keeping it
  opt-in is a policy choice, and the spec should say so.
- The "Everywhere else: On" row is the open risk under Guideline 5.1.1(ii). The lowest-risk change
  that keeps the owner's opt-out intent is to send nothing until the first-launch notice has been
  acknowledged ("OK", which arms collection; "Turn off"). Record and buffer events locally until
  then. Whether that is enough for Apple is for a lawyer or App Review.
- The UK split in Open question 3 is viable only if the counts stream is aggregated and stripped of
  the install id (B2).

**§5.3 — How the app learns the region.** **Confirmed, with one change.** Storefront first is
reasonable, and fail-closed is correct. Downgrade `Locale.current.region` from a fallback that can
clear a reader for default-on. It depends on the app's shipped localizations and is not a location
signal. The safer rule is that when the storefront is `nil`, treat the region as unknown, which
means opt-in. Whether a non-EU-storefront reader physically in the EU is covered **needs a lawyer**.

**§6 — Identity.** **Confirmed for ATT. Corrected for the CNIL claim.** No ATT prompt,
`NSPrivacyTracking` false, and no IDFA or IDFV are all confirmed against Apple's definition.
"No automatic rotation" is what disqualifies the CNIL exemption (13 months), and the ICO exception
needs no persistent id at all for counts. If the owner wants any consent-free stream in France or
the UK, it must use a separate, rotating or absent id. Otherwise, §6 stands as written for
consent-gated collection.

**§8 — App Store label and `PrivacyInfo.xcprivacy`.** **Corrected.**

- Device ID: change to **Linked: Yes**. Apple counts personal data under privacy law as linked, and
  a persistent id with a history is personal data under the GDPR (B5).
- Device ID versus User ID: confirmed as Device ID, arguably.
- Product Interaction: adding the Analytics purpose is confirmed. Add Product Personalization if
  aggregates drive what readers see.
- Tracking: none, confirmed.
- `NSPrivacyAccessedAPITypes`: confirmed unchanged. CA92.1 and C617.1 cover the design, provided
  the implementation avoids boot-time and disk-space APIs. `Storefront` is not a required-reason
  API.

**§10.3 — Privacy-policy facts** (it builds on §5). Item 2 must change if Switzerland moves. Item 8
("Legal basis per region") **needs a lawyer**. Add the Guideline 5.1.1(i) items: how to revoke
consent and request deletion. Add the Unrar.swift MIT, UnRAR §2 and Intel BSD notices to the app's
acknowledgements, which is the local-formats spec, not the analytics spec.

## Sources not reached this session

- **UK GDPR Art. 3 and FADP Art. 3** (territorial scope): not fetched. B6 marks them unverified.
- **CCPA §§1798.105–1798.130** (deletion, access, opt-out mechanics): not read, because CCPA is
  very unlikely to apply (B4).
- **State laws other than Virginia's**: deliberately not surveyed.
- **National transpositions of ePrivacy 5(3)** other than France's: not read.
- **UnRAR 7.23 tarball from RARLAB**: RARLAB's file names did not map to `Unrar.swift`'s
  "v7.23", and `unrarsrc-7.2.3` turned out to be 7.20 beta 3. The licence was compared against
  7.30 beta 1 instead and is identical (A1).
