# Offline site fixtures

Captured HTML for the S6 port tests (`WeebCentralPortTests`). Nothing here is fetched at
test time: both the compiled `bundled WeebCentral Source` and the configuration-backed Extension
load these files into a `WKWebView` with every subresource blocked and the page's own
JavaScript disabled, so the DOM under test is exactly the server-rendered markup below.

| Directory | What it is |
|---|---|
| `weebcentral/` | Real WeebCentral responses, captured **2026-09-11** with the host's pinned iOS Safari User-Agent. Listing and chapter-list pages are truncated after the first few `<article>` / chapter rows; nothing else is edited. These are the volatile ones — a WeebCentral redesign means recapturing them. |
| `pagedink/`, `slugcomics/` | Two synthetic sites. They exist to prove the engine is generic (acceptance criterion 1), and are deliberately structured unlike WeebCentral: different markup, different id path segments, different pagination. No such sites exist. |

Fixtures are resolved from `#filePath`, the convention `RecommendationGoldenTests` already
uses, so adding one needs no `project.pbxproj` edit.
