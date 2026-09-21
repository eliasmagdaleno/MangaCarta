# ADR-0022 — The release build ships no adult source, and hides the control for one

- **Status:** Accepted (2026-08-31). **Amendment 1 below decides the case this ADR deferred:
  a reader-installed adult Source is reachable, behind the existing gate.**
- **Related:** ADR-0003, ADR-0016

## Context

The app has a third source — an adult one — built and working. It lives only on the local-only
`nhentai` branch and has never been pushed or merged. The gating machinery for it, however,
shipped to `main` long ago as part of extension-system Phase 1: `MangaSource.isNSFW`,
`SourceRegistry.visibleSources(includeAdult:)`, `enforceAdultGating(includeAdult:)`, and a
"Show adult sources" toggle in Settings backed by `settings.showAdultSources`.

Both registered sources declare `isNSFW = false`. So the build that would go to review today
already contains a Settings switch that changes nothing observable.

The first submission of an unknown app is the point of maximum review scrutiny and minimum
accumulated goodwill. Adult content is not forbidden on the App Store, but it is the single
largest review risk this app carries, and it is a risk taken on behalf of a source that is not
on the critical path for anything: Phases 2–5 are the extension system, and once that ships an
adult source is something a reader installs rather than something the app ships.

The decision is worth making **now** rather than at submission, because the cost being avoided
is entanglement. Every subsequent phase that treats the adult source as present — a theme
engine that assumes it, a repo listing that includes it, a test fixture that registers it — makes
removal more expensive. That accrues whether or not anyone has touched the code, which is exactly
the kind of cost a written decision made early is for.

## Decision

**The release build registers no source whose `isNSFW` is true.**

Enforced by *not merging* — the `nhentai` branch stays local-only, as it always has. No build
configuration, no compile-time flag, no release-only exclusion path.

**And Settings hides the "Show adult sources" toggle while no registered source declares
`isNSFW`.** A control that changes nothing is worse than no control: it invites a reviewer to go
looking for the behaviour it is supposed to gate, which is the exact attention this decision
exists to avoid, and it is equally confusing to a reader who flips it and sees nothing happen.
The toggle's stored preference is untouched — hiding the control does not clear it — so a build
that registers an adult source shows the switch again with its previous value intact.

## Alternatives considered

**Ship it gated behind the existing opt-in.** The machinery is real and the content is behind a
default-off switch. Rejected: a default-off switch is not a defence at review time, since a
reviewer's job is to find what is behind it, and the goodwill spent is spent on the submission
that can least afford it.

**A build-configuration exclusion — a release flag that strips adult sources even if one is
registered.** Rejected as a mechanism built to defend against a merge that *is itself* the
decision. It is cheaper not to merge than to build a machine that survives merging by mistake,
and the machine would need its own tests and its own maintenance through Phases 2–5.

**Leave the toggle visible.** Rejected for the reason in the Decision. It was left visible only
because nothing prompted a look at it once the adult source moved to a private branch.

## Consequences

- The public release ships MangaDex and WeebCentral. Nothing else changes about them.
- **The gating machinery stays.** `isNSFW`, `visibleSources(includeAdult:)` and
  `enforceAdultGating(includeAdult:)` are not deleted, and they keep their tests. This decision
  reverses by registering a source — it does not require rebuilding what would then be needed.
- Once the extension system ships, an adult source becomes a thing a reader installs. That is a
  different decision, about what the installer permits and what a repo may list, and it should be
  made in that context rather than inherited from this one. Expect to revisit this at Phase 4.
- Anyone reading `SettingsView` will find a toggle rendered conditionally for a reason that is
  not local to the file. The condition cites this ADR.

## Amendment 1 — a reader-installed adult Source is reachable, behind the existing gate (2026-09-11)

The decision above stands: the release build registers no source whose `isNSFW` is true, enforced
by not merging the `nhentai` branch. This amendment answers the question the Consequences section
deferred to Phase 4 — "an adult source becomes a thing a reader installs. That is a different
decision" — now that the repository format exists to install one.

### Context

The original decision is about what is *in the build* at review time. A Source a reader installs
from a repository they added is not in the build; it is a declaration record and an engine script
fetched after the fact, interpreted under the Host API, and it declares its own classification
(`adult: none | mixed | adultOnly`, fail-closed — see ADR-0003 Amendment 2). So the original ADR
does not decide this case and must not be read as if it did. The choice was between refusing such
declarations at install and accepting them behind the gate the original decision deliberately kept.
It is a product call with App Review consequences, and it was the user's; the design presented
both options with a recommendation, and the user chose the recommended one.

### Decision

**A `mixed` or `adultOnly` declaration installs like any other Source, behind the existing
default-off "Show adult sources" gate, with a one-time acknowledgement at install.** The
acknowledgement names the Source, its repository and its class; declining ends the install with
nothing persisted. The mechanics are in the repository format design's "Adult Sources" section.

What the original decision's gating machinery was kept *for* is exactly this. `isNSFW`,
`visibleSources(includeAdult:)` and `enforceAdultGating(includeAdult:)` were retained "because
this decision reverses by registering a source"; an installed Source is one, registered by the
reader rather than the build. The toggle's conditional visibility also carries over unchanged: at
review time nothing adult is registered, so the toggle is hidden by the rule already in place, and
a reviewer sees no adult control unless they add a repository that carries an adult Source. The
argument the original ADR made against shipping gated content — "a default-off switch is not a
defence, since a reviewer's job is to find what is behind it" — does not transfer, because there
is nothing behind the switch in the build a reviewer receives.

### The App Review consequence, stated plainly

If Review reads the app as a browser for adult content the developer does not moderate, the
citations are guidelines 1.1.4 (overtly sexual material) and 1.2 (user-generated and third-party
content without moderation). The defence is that the build ships no such source, no source list,
and no default repository; every adult Source is something a reader chose to add by URL and then
chose to acknowledge. That is the posture Paperback and Aidoku take, and neither is on the App
Store — which is the honest reading of the risk. Two facts make this the right call anyway:
refusing later is a one-line change to the installer, whereas refusing *now* cannot be reversed
without an app update; and refusing would leave the Host API's per-Listing elevation with nothing
to elevate into, so a `none` Source that honestly labels one Listing `erotica` would have that
Listing silently dropped forever.

### Alternatives considered

**Refuse `mixed` and `adultOnly` at install.** The index would still list them, greyed, as not
available in this build; the toggle would never appear. Rejected for the two reasons above: it is
the irreversible direction, and it makes honest per-Listing labelling self-defeating.

**Accept `mixed` but refuse `adultOnly`.** Rejected as a line with no principle behind it: the
gate treats both the same, and a maintainer who wanted through would declare `mixed`.

### Consequences

- The "Show adult sources" toggle becomes reachable by a reader who installs an adult Source, with
  its stored preference intact from before it was hidden — the original decision preserved it for
  this.
- ADR-0003 Amendment 4's Gate 4 decision applies to installed adult Sources: attestation is the
  maintainer's, the trust decision is the reader's, per-Listing elevation is the enforcement, and a
  reader may elevate a Source locally. Nothing here is moderated by the developer, and the
  acknowledgement copy should not imply otherwise.
- The `nhentai` branch is unaffected. It stays local-only; the way for that Source to reach a
  reader's device is now the same as for any other — as a declaration in a repository the reader
  adds — and whether to publish one is a separate decision nobody has made.
- If Review objects, the reversal is the installer refusing the two classes, and this amendment is
  where the reason for that reversal should be recorded as Amendment 2.

## Amendment 2 — submit with installable adult Sources reachable, behind a declared-age gate; and a correction to Amendment 1's premise (2026-09-16)

Amendment 1 decided that a reader-installed adult Source is reachable. It deferred a separate,
dated question — what the app does *at submission* about the App Review exposure it named — to
#171. This amendment records that decision, made by the user on 2026-09-16 on the write-up in
#171, and corrects a factual premise Amendment 1 rested on. Per this repository's rule the
premise is not edited in place; it is corrected here.

### The correction

Amendment 1 says the reader-installs-it posture "is the posture Paperback and Aidoku take, and
neither is on the App Store." **Paperback is on the App Store**, and has been for three years:
`id1626613373`, v0.8.11 dated 2025-02-28, age rating 16+, privacy label "does not collect any
data", described in two sentences as "An Ad-Free Komga client for iOS. Supports an extensive
scripting API using TypeScript/JavaScript to extend the app functionality." Its reviews confirm
that the App Store build is the one in which readers add repositories themselves. Aidoku is not
on the App Store and says no plans for a release have been made. So the honest reading of the
risk is not "nobody with this posture has been approved"; it is that one app with this exact
posture has been approved and has stayed up, positioned as a client for a reader-supplied
service with a scripting seam, shipping no sources. A precedent, not a guarantee.

### Context

The guidelines were re-read from the live page on 2026-09-16. Amendment 1 named 1.1.4 and 1.2.
**1.2 is a poor fit** — it governs user-generated content (posting, reporting, blocking users), and
nothing here is posted. **The rule that fits is 4.7**: "Apps may offer certain software that is not
embedded in the binary, specifically HTML5 and JavaScript mini apps … and plug-ins. You are
responsible for all such software offered in your app." An engine script installed from a
repository is a plug-in not embedded in the binary. Its sub-rules are concrete: 4.7.4 requires "an
index of software and metadata available in your app … universal links that lead to all of the
software offered", and 4.7.5 requires "a way for users to identify software that exceeds the app's
age rating, and … an age restriction mechanism based on verified or declared age." The rule 4.7
is an exception to, 2.5.2, forbids downloading or executing code that changes the app's features
outright.

The load-bearing phrase is "software **offered in** your app". The build ships no default
repository, no source list and no index — ADR-0003 Amendment 4 chose that for its own reasons —
so there is a defensible reading under which the app offers nothing and the reader brings the
software. That is Paperback's position, and it is why 4.7.4 has nothing to attach to in v1.
**Shipping a default repository would change this**; that decision, if it is ever made, reopens
this amendment.

### Decision

**The app is submitted with reader-installed adult Sources reachable as Amendment 1 specifies,
with one mitigation: the install-time acknowledgement for a `mixed` or `adultOnly` Source is a
declared-age gate.** The sheet asks the reader to confirm they are 18 or over; the confirmation is
stored once, on the device; declining ends the install with nothing persisted, as before; and the
"Show adult sources" toggle stays hidden until a confirmed reader has an adult Source registered.
The mechanics are the repository format design's "Adult Sources" section; the term is the
glossary's "declared-age gate".

The App Store answers follow from this and are recorded here so they are decided once:

- **Age rating:** answered honestly on the two shipped sources, expecting 16+/17+ as Paperback's
  16+. "Unrestricted Web Access" is not the lever — the app embeds no navigable browser.
- **Description:** what the app is, in Paperback's register — a reader for MangaDex with an
  extension seam. It names no sites, does not say "any source", and does not mention adult content.
- **Review notes:** state plainly that the build ships two content sources and no extension
  repository; that extensions are configuration-backed sources a reader may add by URL from a
  repository they choose; that each declares its own content class; and that any adult class is
  hidden by default, requires the reader's declared age, and is never listed or recommended by the
  app. Name the gate. Do not volunteer a guideline number.
- **Privacy policy:** names MAL, the fields, retention and revocation, per #149 — same pass.

### Alternatives considered

**Submit as amended with the plain acknowledgement.** Rejected because 4.7.5's wording — "verified
or declared age" — is satisfied by a declared-age question and not by an acknowledgement that
names a class. The gate is a few lines in the sheet Settings builds anyway and turns the weakest
citation into a rule met by construction.

**Refuse `mixed` and `adultOnly` at install for v1.** Rejected again, for Amendment 1's two
reasons — it is the irreversible direction and it makes honest per-Listing elevation
self-defeating — and now for a third: the precedent says the posture can pass, so the cost of
refusing is paid against a risk that is smaller than Amendment 1 believed.

**A verified-age gate.** Rejected: 4.7.5 accepts declared age, verification would need a service
and a data flow the privacy label would have to carry, and the app has no account to bind it to.

### Consequences

- The Phase 4 S5 brief carries the gate; the acknowledgement sheet the repository format design
  §7.1 describes is the gate, not a sibling of it.
- The declared-age confirmation is a per-device preference, stored beside the "Show adult sources"
  preference and cleared with it; it is not a per-Source or per-Repository fact.
- If Review objects anyway, the reversal is unchanged — the installer refusing the two classes —
  and the reason is recorded as Amendment 3.
- #171 closes when this amendment is merged and the S5 brief carries the gate.

## Amendment 3 — a bundled WeebCentral package is not the default repository Amendment 2 guards against (2026-09-21)

Amendment 2 said that shipping a default repository "reopens this amendment". On 2026-09-21 the
user decided WeebCentral ships as a **bundled package** — index, script and declaration as app
bundle resources, installed through the ordinary installer under a fixed app-owned identity,
updated only with app updates ([ADR-0003 Amendment 5](0003-extension-substrate.md#amendment-5--weebcentral-ships-as-a-bundled-package-and-the-compiled-source-goes-2026-09-21)).

This amendment records that **Amendment 2's sentence is about a network repository** — an index the
app fetches and whose Sources it offers to the reader, the "software offered in your app" that
guideline 4.7 reaches — and that a package embedded in the binary is not one. It is app content
under 2.5.2's ordinary rules, exactly as the compiled `WeebCentralSource` was. Nothing in Amendment
2's decision or its App Store answers changes: the build still ships two content sources and no
extension repository, the review notes still say so, and the age rating is still answered on
those two. What changes is only how one of the two is built.

The condition that *would* reopen Amendment 2 is unchanged and restated so it is not lost: an
index the app fetches over the network by default, or a bundled package that offers a `mixed` or
`adultOnly` Source. The reversal Amendment 2 reserved for "if Review objects anyway" is now the
next amendment, not this one.
