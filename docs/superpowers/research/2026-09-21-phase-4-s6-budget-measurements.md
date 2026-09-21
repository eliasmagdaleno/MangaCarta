# Phase 4 S6 budget measurements

This is the S6 corpus item for the Host API design's **Storage** section and the repository format design's **Bounds** section. Measurements use the installed WeebCentral fixture package and captured HTML fixtures on an iPhone 17 simulator, with no live network.

## Serialized bytes

| Artifact | Bytes | Measurement point |
|---|---:|---|
| `repositories.json` | 3,073 | After install |
| `extension-storage.json` | 0 (file not created) | After install and browse/read fixture operations |
| Installed package script on disk | 13,794 | `extension-scripts/<repository UUID>/html-selector.js` |
| Repository index fixture | 5,251 | Served `repository-index.json` bytes |
| Engine script fixture | 13,794 | Served `repository-engine.js` bytes |

## Wall clock and request counts

| Operation | Wall clock (ms) | Repository or browser requests |
|---|---:|---:|
| Add | 0.36 | 1 index fetch |
| Refresh | 0.29 | 1 index fetch |
| Install | 0.67 | 1 script fetch |
| Search | 25.77 | 1 browser extraction |
| Detail | 25.95 | 1 browser extraction |
| Chapters | 27.72 | 1 browser extraction |
| Pages | 27.29 | 1 browser extraction |

The fixture transport counts each index and script fetch. The captured-site host counts each browser extraction; the fixture responses come from local HTML files, so these values describe operation calls and not Internet latency. Wall clock values are milliseconds from the full `MangaCartaTests` run on one iPhone 17 simulator, rounded to two decimals; they are an observation, not a latency distribution. `extension-storage.json` is absent because these WeebCentral operations do not call `host.storage`.
