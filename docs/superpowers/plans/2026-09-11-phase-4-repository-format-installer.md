# Plan — Phase 4: repository format + installer

Written 2026-09-11, against `main` at `86557d7`, after Phase 3 closed (#162).

Phase 3 built a runtime that can run a configuration-backed Source. **Nothing can put one there.**
Phase 4 is the path from a URL a user types to a Source in the picker: a package format, a
repository store, an installer, and the seam that registers an installed Source with the app.

## What is actually missing — verified against `main`, not assumed

Four gaps, in dependency order. The first two are tracked issues; the third is not tracked anywhere
and is the one that makes "install" meaningful; the fourth is where the format has to start.

1. **#164 — three of four host capabilities are unreachable.** `HostBrowserJSCapability` is the only
   `ExtensionHostCapability` conformer. `host.http`, `host.storage`, `host.log` exist as tested Swift
   types with no bridge. WeebCentral does not notice (`httpOrigins` is empty); **most Sources will**.
2. **#161 — `reinstall` takes an already-typed `SourceDeclaration`.** The typed precondition is prose
   in a doc comment. The installer is the only caller that will ever construct one, so the boundary
   is Phase 4's to draw.
3. **There is no `MangaSource` adapter over `ExtensionRuntime`.** `grep "MangaSource {"` finds
   `MangaDexSource`, `WeebCentralSource`, two UI-test stubs and test doubles — nothing extension-backed.
   `ExtensionRuntime(` is constructed **only in `MangaCartaTests`**. `SourceRegistry.builtInSources()`
   returns a hard-coded array of two. Until this seam exists, a successful install changes nothing a
   user can see.
4. **The engine bundle and the WeebCentral declaration are Swift string constants** —
   `HTMLSelectorThemeEngine.bundleScript`, `.weebCentralJSON`, `.weebCentralConfigurationJSON`. The
   port proved they *can* be data. Phase 4 is where they *become* data, loaded from a package rather
   than compiled in.

## Decisions this phase must make before it can be called complete

Host API design §16 lists four open evidence gates and says each "must be resolved before its
dependent runtime or installer slice is called complete." **Two of them are this phase's**, and two
tracked issues sit alongside them. All four are design decisions, not implementation choices, so D0
below makes them — in writing, in an ADR amendment — before any installer code is written.

| Decision | Owner | Where it must land |
|---|---|---|
| Gate 3 — stable repository identity across URL moves, forks, key rotation | D0 | ADR-0003 Amendment 3 |
| Gate 4 — who may attest adult classification, and how review is maintained | D0 | ADR-0003 Amendment 3 |
| #161 — raw JSON at the `reinstall` boundary, or the typed precondition accepted | D0 | same amendment; close #161 |
| Signing and trust — in v1, or deliberately deferred with the migration named | D0 | same amendment |
| Whether a user-installed adult Source is reachable at all, given ADR-0022 | D0 | ADR-0022 amendment |
| Whether the app cuts over from compiled `WeebCentralSource` to the installed declaration | S6 + user | ADR, not a PR body |

**Evidence gate 1 (budgets) is not this phase's to close**, but S6 is its second corpus item and
should record measurements rather than skip them — see "Evidence gate 1" at the bottom.

### The two that will be argued about, with a recommendation

**Gate 3 — repository identity.** The cheap answer is "identity is the URL", and it is wrong: §11
already says a repository replacement must get a *different* identity while a repository *move* must
keep the same one, and a URL cannot distinguish those. Recommendation: **installer-minted opaque
identity**, a UUID generated at first install and stored locally, bound to the origin it was
installed from and displayed by URL. A URL change is then a user-confirmed re-point of an existing
identity, not a new install; a fork served from a new URL is a new identity unless the user says
otherwise. This keeps `QualifiedSourceID` stable — which is what Listings and pins depend on — with
no signing infrastructure. Record the migration path to key-based identity explicitly; do not leave
it implied.

**ADR-0022 and installed adult Sources.** ADR-0022 says no adult source ships *in the release build*.
A user-installed one is not in the build, so the ADR does not decide this and must not be read as if
it did. This is a product decision with App Review consequences; **it is the user's call, and D0
asks rather than assumes.**

## Slices and dependency order

| # | Slice | Depends on | Wave | Agent |
|---|---|---|---|---|
| D0 | Repository format design + the decisions above | — | 0 | **Opus high**, with the user in the loop |
| S1 | Host capability bridge — `host.http`, `host.storage`, `host.log` (#164) | — | 0 (parallel with D0) | Sonnet or Codex |
| S2 | Package parsing + validation: repository index, bundle manifest | D0 | 1 | Sonnet or Codex |
| S3 | `RepositoryStore` + installer pipeline: add, install, update, disable, uninstall, reinstall | D0, S2 | 2 | strongest available |
| S4 | `ExtensionSource: MangaSource` + dynamic registration in `SourceRegistry` | S1, D0 | 2 | strongest available |
| S5 | Settings UI: add repository by URL, manage installed repositories and Sources | S3 | 3 | Sonnet or Codex |
| S6 | End-to-end proof: WeebCentral installed from a package, not compiled in | S3, S4 | 3 | strongest + review |

**S1 runs in Wave 0 alongside D0 deliberately.** It depends on nothing D0 decides — it is a seam
between two merged slices — and S4 cannot be written without it. Starting it first is free.

**Waves 2 and 3 run at most two wide**, and only one of any pair may build against the simulator:
two `xcodebuild` runs against the shared device produce `Executed 0 tests` plus a named failing test
and a `DebuggerLLDB` store error, which looks exactly like a real failure. Say which worker owns the
simulator, in the brief, in as many words.

**Split every wave across providers.** Both providers have stalled a wave here and every stall was
silent. Default `--model` to something cheap; make Opus high earn its place — D0 earns it (it is the
phase's only genuine design risk), S3 and S6 earn it on cross-cutting depth. **Fable is not available
on this account.** Prefer a Claude subagent in a *prepared* worktree for the hardest slice: proven
twice now (S6, S7), and it cannot stall on a provider trust prompt.

## Acceptance criteria

Eleven, each owned by exactly one slice, each demonstrated **by a test** rather than asserted in a
PR body. These are Phase 4's definition of done.

1. A well-formed repository index parses into typed values; every malformed shape is rejected with a
   located error naming the offending key path. *(S2)*
2. A bundle manifest carrying one or more declaration records plus one engine script validates
   through `SourceDeclarationValidator` **from raw JSON**, and an unvalidated declaration cannot
   reach `SourceLifecycleRegistry` as a typed value. *(S2, S3 — closes #161)*
3. Repository identity is minted at first install, survives a URL change, and a different repository
   serving the same `localId` receives a different `QualifiedSourceID`. *(S3)*
4. Installing two repositories whose bundles collide on qualified id is rejected, and the rejection
   names both. *(S3)*
5. An update may change name, engine, configuration and capabilities but not identity;
   `validateUpdate` rejection surfaces as a failed update that leaves the installed Source intact.
   *(S3)*
6. Disable, uninstall and reinstall preserve and reconnect Listings, pins and bounded Source storage
   for the same qualified identity. *(S3 — extends criterion 10's coverage past the registry)*
7. `host.http`, `host.storage` and `host.log` are each callable from a running engine, each admitted
   through `scope.admitHostCall`, each returning only via that call's `deliver`, and each rejecting
   with a Host API error code so the taxonomy survives the round trip. *(S1 — closes #164)*
8. An installed Source appears in `SourceRegistry`, is selectable as the browse source, and serves
   search, detail, chapters and pages through `ExtensionRuntime` — with `sourceId` stamped so
   `source(for: manga)` routes back to it. *(S4)*
9. Uninstalling the Source backing an open Listing degrades to unavailable without data loss, and
   fulfillment ranking chooses another registered Source where one exists. *(S4, against ADR-0004)*
10. Adding a repository by URL, installing a Source from it, and removing it are all reachable from
    Settings, and every failure mode reaches the user as a sentence rather than a silent no-op. *(S5)*
11. WeebCentral runs from an **installed package** — engine script and declaration loaded from the
    package, not from `HTMLSelectorThemeEngine`'s Swift constants — and returns the same results the
    port's fixtures already pin. *(S6)*

## Shared preamble — include verbatim at the top of every Phase 4 worker brief

You are implementing one slice of **Phase 4** of MangaCarta (repo
`/Users/eliasmagdaleno/Manga-Reader`, GitHub `eliasmagdaleno/MangaCarta`, branch off `main`).
Phase 4 builds the repository format and the installer on top of the extension runtime Phase 3
shipped.

### Read these before writing code, in this order

1. `docs/superpowers/specs/2026-09-02-host-api-design.md` — especially "Identity lifecycle",
   "Adult classification", "Storage", and §16's open evidence gates.
2. `docs/adr/0003-extension-substrate.md`, including **all amendments** — Amendment 3 is Phase 4's
   own design and is authoritative over anything this plan says.
3. `docs/superpowers/specs/<D0's repository format design>` — the wire shapes for this phase.
4. `CLAUDE.md` — build commands, architecture, conventions, and **document ownership**.

**The split is load-bearing: the ADR owns decisions and their reasoning; the spec owns wire shapes,
validation rules, and operation semantics.** Do not invent an answer either already gives, and do
not edit either from an implementation slice.

### Non-negotiable working rules

Each has already cost this repository real time.

1. **Test-driven, and a passing test is not evidence until you have seen it fail.** Write it first,
   watch it go red, then make it green. **Mutate the implementation and re-run** before believing any
   green assertion — "it stopped compiling" is not seeing it fail.
2. **Count clauses, not tests.** Each acceptance criterion above is a sentence with several claims in
   it. **Mutate each clause separately** and report the mutation per clause. S6 did eleven of these
   and it was the cheapest review this project has run.
3. **Cite documents by term or section heading, never `file:line`.** Line citations rot inside a
   single session.
4. **CI is a major version behind this machine** — `macos-15` / Xcode 16.4 / Swift 6.0 vs local
   26.x / 6.2. Treat isolated conformances (`extension X: @MainActor P`), `nonisolated(nonsending)`,
   `@concurrent` and `Task.immediate` as **unavailable**. CI's SwiftLint is not this machine's either.
5. **Every `xcodebuild` targets the iPhone 17 Pro simulator**
   (`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`) — it holds the seeded fixture.
   `** TEST FAILED **` naming no failing test is a wedged device: `xcrun simctl boot "iPhone 17 Pro"`
   and re-run. **Never erase it** — that has destroyed `works.json` once.
6. **Test totals come from the result bundle**, not the log tail: `-resultBundlePath <path>`, then
   `xcrun xcresulttool get test-results summary --path <path>`.
7. **Adding files:** `MangaCarta/Models/`, `MangaCarta/Services/` and `MangaCarta/Views/Components/`
   are synchronized groups and compile automatically. **`MangaCarta/Views/` and `MangaCartaTests/`
   are not** — use `xcp add-file "$PWD/MangaCarta.xcodeproj" --file "$PWD/<path>" --targets <target>`.
8. **`project.pbxproj` churns under you** whenever Xcode has the project open. Check
   `git diff --stat` immediately before `git add`, not right after `xcp`.
9. **`Secrets.xcconfig` is gitignored.** A fresh worktree fails to build with "Unable to open base
   configuration reference file" until it is copied in. That is not a broken branch.
10. **Do not stack PRs.** A child closes unrecoverably when its base is deleted.

### What to report

A PR body naming, per acceptance criterion you own, **the test that demonstrates it and the mutation
that made that test fail.** A criterion with a test but no mutation is not yet evidence.

---

## Worker briefs

### D0 — Repository format design, and the decisions Phase 4 cannot start without

**No implementation code.** Output is `docs/superpowers/specs/<date>-repository-format-design.md`
plus **ADR-0003 Amendment 3** (and an ADR-0022 amendment if the user's answer on installed adult
Sources requires one).

Design and write down:

- **The package format.** A repository index fetched over HTTPS from a static host — the shape
  Paperback and Aidoku use, and deliberately boring. Per bundle: one engine script plus one or more
  validator-accepted declaration records. S6 established that **nothing else was required to run a
  Source**, so start from exactly that and justify every addition. Include `presentation.feeds`
  eyebrows; they match the compiled source's `homeRailEyebrows`.
- **Versioning of the format itself**, distinct from `hostAPI` range negotiation, which already
  exists.
- **Gate 3 — repository identity.** See the recommendation above. Name the migration to key-based
  identity rather than implying it.
- **Gate 4 — adult attestation.** §12 already says a repository index may override a declaration only
  *toward* a more restrictive class. Decide who attests and what happens to an under-classified
  Source, given that this project has no moderation capacity.
- **#161 — the `reinstall` boundary.** Recommendation: the installer takes **raw JSON** and validates
  it, so an unvalidated declaration cannot reach the registry as a typed value. This is cheapest now
  and it is the reason the issue was held for this phase. Whatever is decided, record the reasoning
  and close #161 against the amendment.
- **Signing and trust.** Deferring is defensible for v1. Deferring *silently* is not — name what a
  signed format would change and what an unsigned one asks the user to trust.
- **Storage quota and uninstall retention.** §11 retains bounded storage on ordinary uninstall and
  erases it only on explicit removal. Decide the quota, or state what measurement settles it and
  leave the number to S6's corpus — do not quietly pick one.

**Ask the user directly about installed adult Sources** (ADR-0022's boundary) and about whether
signing is in v1. Both are product calls with App Review consequences. Everything else is yours.

### S1 — Bridge `host.http`, `host.storage` and `host.log` (#164)

Closes criterion 7 and issue #164. **Independent of D0; start immediately.**

`HostBrowserJSCapability` is the pattern and the contract: every asynchronous call admitted through
`scope.admitHostCall`, results delivered only through that call's `deliver`, failures rejecting with
a Host API error code. Three more capabilities must do the same over the already-tested
`HostHTTPClient`, `HostStorage` and `HostLogger`.

**Decide whether the four adapters share one implementation** rather than repeating that structure
four times — #164 asks this explicitly. If they do, `HostBrowserJSCapability` moves onto the shared
path and its existing tests must stay green unchanged.

Each capability needs a test that **an engine actually calls it** — not that the Swift type works,
which S5 already proved. Test the seam.

### S2 — Package parsing and validation

Criteria 1 and 2. Pure functions over JSON, no network, no JavaScriptCore. Mirror
`SourceDeclarationValidator`'s conventions exactly: located errors carrying a key path, unknown keys
rejected outside `configuration`, bounded text limits.

The declaration path must go **through the existing validator from raw JSON** — do not re-implement
declaration validation, and do not construct `SourceDeclaration` values directly.

### S3 — `RepositoryStore` and the installer pipeline

Criteria 2 (registry half), 3, 4, 5, 6. The core of the phase.

Add, install, update, disable, uninstall, reinstall, over the merged `SourceLifecycleRegistry` —
which already owns state transitions and `validateUpdate` consistency; **do not duplicate them.**
Persistence follows the existing store conventions (`UpdateStateStore`, `SourcePreferenceStore`):
a JSON file under Application Support, written through the same shape.

Identity minting, collision rejection and the URL-move path are this slice's hardest part and its
most important tests. **A `nil` is unknown, never zero**, here as everywhere in this codebase.

### S4 — `ExtensionSource: MangaSource` and dynamic registration

Criteria 8 and 9. **This is the slice that makes installation mean something.**

An `ExtensionSource` conforming to `MangaSource`, backed by `ExtensionRuntime` plus a declaration,
translating `SourceOperation` invocations into the protocol's methods and the domain wire values into
`Manga` / `Chapter` / page URLs through S2's merged adapters. `MangaSource` is deliberately
**bridge-friendly** — `Int`/`String` parameters, value returns — which is exactly why this adapter is
possible; keep it that way.

`SourceRegistry.builtInSources()` currently returns a hard-coded pair. It must take installed Sources
too, **without** breaking the injected-registry rule: `AppComposition.registry` is the graph's one,
views take it from the environment, and `SourceRegistry.shared` survives only as the production
default. Registration changing at runtime must reach the picker, fulfillment ranking, and adult
gating.

`Manga.sourceId` must be stamped with the qualified id on every conversion path — the same rule
`toManga(id:relationships:)` follows for MangaDex. Criterion 9 is where this is proved.

### S5 — Settings UI

Criterion 10. Add a repository by URL; list repositories and their Sources; install, disable,
uninstall, update; surface every failure as a sentence.

**The adult install sheet is a declared-age gate** (ADR-0022 Amendment 2, 2026-09-16 — decided
after this plan was written): the sheet for a `mixed` or `adultOnly` Source names the Source, its
repository and its class *and* asks the reader to confirm they are 18 or over, once per device,
stored beside the "Show adult sources" preference and cleared with it. The "Show adult sources"
toggle stays hidden until a confirmed reader has an adult Source registered. The mechanics are the
repository format design §7.1; `ExtensionInstaller`'s `acknowledgeAdult` closure is the seam the
sheet answers through. The copy must not imply developer moderation.

Rows are namespaced in this codebase's accessibility identifiers (`browseSource.`,
`preferredSource.`) because a bare query matches the wrong list — follow that. A hermetic UI test is
a merge condition; `UpdatesUITests` and `SourcePreferenceUITests` run on every PR and anything in
`MangaCartaUITests.swift` is live and run by name. **Do not name live data in a test that does not
measure it.**

### S6 — WeebCentral, installed rather than compiled

Criterion 11, and the phase's proof. Serve a repository from a local fixture, install it, and run the
WeebCentral declaration end to end through the installed package. The port's captured fixtures
(`MangaCartaTests/__Fixtures__/weebcentral/`) already pin the expected results — reuse them, and any
divergence is this slice's to explain.

**Whether the shipping app then stops using compiled `WeebCentralSource` is a separate decision** and
belongs in an ADR with the user's agreement, not in this PR. Keeping both briefly is fine; keeping
both *silently* is how two copies of one fact diverge.

## Evidence gate 1 — budgets

Still open, still unowned, and S6 is only its second corpus item. Every additional engine makes the
corpus more representative and the gate no cheaper to close. **S6 should measure** — serialized
storage size, wall-clock per operation, request counts — and record the numbers in the spec's
profiling corpus even though closing the gate is not its job. Measuring nothing was S6-of-Phase-3's
one real gap; do not repeat it.

## Supervision protocol

Unchanged from Phase 3, and it caught real defects every time:

1. `git -C <worktree> status` and the terminal preview — **the dispatch status lies.**
2. Rebase onto `main`; expect a `project.pbxproj` conflict if a peer landed first. Resolution is
   **keep-both**.
3. Re-run the **full** `MangaCartaTests` bundle after the rebase; read totals from the result bundle.
4. **Review by mutation, not by reading** — and check clause coverage, not test count.
5. Only then merge, and check the PR body names a test *and a mutation* per criterion it claims.

Add `orca orchestration check --terminal <handle> --types question` to every pass — a worker can block
on its own question while heartbeating `live`. Keep the default pass cheap: `check` plus
`git -C <worktree> status -sb`.

**Verify the worker's claims against the repository, not against its report.** Two of S6's claims
looked like defects until the code said otherwise; checking is what established that. **A layering
difference is not a divergence** — check where a fallback lives before calling it a regression.
