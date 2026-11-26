| id | description | result | killed by |
|---|---|---|---|
| E1 | drop ComicInfo Series priority | KILLED | `LocalMatchingCoordinatorTests/testLocalEvidenceUsesTitlesNotChapterNumbers()` |
| E2 | feed ComicInfo volume as title | KILLED | `LocalMatchingCoordinatorTests/testEvidenceDeduplicatesAndKeepsOrder()` +1 more |
| E3 | remove title de-duplication | KILLED | `LocalMatchingCoordinatorTests/testEvidenceDeduplicatesAndKeepsOrder()` |
| M1 | exclude candidates exactly at threshold | KILLED | `MALEntityResolverTests/testCandidateAtAcceptanceThresholdIsIncluded()` |
| M2 | break ambiguity flag | KILLED | `MALEntityResolverTests/testAmbiguousCandidatesAreListedButResolveRefuses()` |
| M3 | reverse MAL id tie-break | KILLED | `MALEntityResolverTests/testCandidatesAreOrderedByScoreThenMALIDAndSearchDespiteKnownID()` |
| M4 | include novels at the MAL API boundary | KILLED | `MangaCartaTests/testExcludingNovelsRemovesTheProseTwinOfAnAdaptation()` |
| M5 | write resolver cache from read-only candidate query | KILLED | `MALEntityResolverTests/testLocalMatchRequiresConfirmationForUniqueExactCandidate()` |
| M6 | swallow failed search | KILLED | `MALEntityResolverTests/testCandidatesThrowOnFailedSearch()` |
| S1 | persist an empty record list | KILLED | `LocalMatchStoreTests/testConfirmedMatchRoundTripsAndUnmatchKeepsLocalWork()` |
| S2 | mark unmatched record confirmed | KILLED | `LocalMatchStoreTests/testConfirmedMatchRoundTripsAndUnmatchKeepsLocalWork()` |
| S3 | default missing status to confirmed | KILLED | `LocalMatchStoreTests/testMissingFileReadsEmptyAndOptionalCodableDefaults()` |

12 killed, 0 survived, 0 equivalent, 0 error (of 12).
