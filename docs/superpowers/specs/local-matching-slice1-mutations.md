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
| M7 | ignore below-threshold ambiguity rival | KILLED | `MALEntityResolverTests/testCandidatesFlagNearMissRunnerUpAsAmbiguous()` |
| M8 | let bestMatch ignore shared ambiguity flag | KILLED | `MALEntityResolverTests/testCandidatesTopEqualsResolvePickWhenGuardClears()` |
| B1 | include id-less bridge listings in MAL candidates | KILLED | `MALEntityResolverTests/testBridgeCandidatesExcludeIDLessRowsAndDoNotRunForMangaDexWork()` |
| B2 | bridge a MangaDex-backed Work | KILLED | `MALEntityResolverTests/testBridgeCandidatesExcludeIDLessRowsAndDoNotRunForMangaDexWork()` |
| E4 | bypass shared filename title helper | KILLED | `LocalMatchingCoordinatorTests/testLocalEvidenceUsesTitlesNotChapterNumbers()` |
| S1 | persist an empty record list | KILLED | `LocalMatchStoreTests/testConfirmedMatchRoundTripsAndUnmatchKeepsLocalWork()` |
| S2 | mark unmatched record confirmed | KILLED | `LocalMatchStoreTests/testConfirmedMatchRoundTripsAndUnmatchKeepsLocalWork()` |
| S3 | default missing status to confirmed | KILLED | `LocalMatchStoreTests/testMissingFileReadsEmptyAndOptionalCodableDefaults()` |

17 killed, 0 survived, 0 equivalent, 0 error (of 17).
