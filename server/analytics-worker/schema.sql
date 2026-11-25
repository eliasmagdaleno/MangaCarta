-- MangaCarta analytics — D1 schema. Idempotent: safe to run again on every deploy.
-- Design: docs/superpowers/specs/2026-11-09-analytics-design.md §2, §7 and Amendment 3.

-- One row per accepted event. There is deliberately no column for an IP address, a user
-- agent, a header or a time of day (§7.1): the Worker reads only the request body.
--   install  the random analytics id, stored lower-case so a DELETE in any case matches it
--   day      the client's UTC day, yyyy-MM-dd (day granularity only, §2.1)
--   received the server's UTC day, yyyy-MM-dd; retention is measured from this, not `day`
--   mal / anilist        the event's `ids`, or `from` for mlt_opened
--   to_mal / to_anilist  `to` for mlt_opened; NULL otherwise
--   attrs    canonical JSON of the event's validated non-id fields, e.g. {"progress":12} or {}
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY,
  install TEXT NOT NULL,
  day TEXT NOT NULL,
  received TEXT NOT NULL,
  app TEXT NOT NULL,
  name TEXT NOT NULL,
  mal INTEGER,
  anilist INTEGER,
  to_mal INTEGER,
  to_anilist INTEGER,
  attrs TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS events_install ON events(install);
CREATE INDEX IF NOT EXISTS events_received ON events(received);
CREATE INDEX IF NOT EXISTS events_mal ON events(mal);
CREATE INDEX IF NOT EXISTS events_anilist ON events(anilist);
CREATE INDEX IF NOT EXISTS events_to_mal ON events(to_mal);
CREATE INDEX IF NOT EXISTS events_to_anilist ON events(to_anilist);

-- Catalogue ids known to be adult (owner decision 7). Filled by the daily classification
-- against AniList, or by hand (README). Every event naming one of these is purged nightly.
CREATE TABLE IF NOT EXISTS adult_catalogue (
  kind TEXT NOT NULL CHECK (kind IN ('mal', 'anilist')),
  id INTEGER NOT NULL,
  PRIMARY KEY (kind, id)
);

-- When each catalogue id was last classified, so an id is asked about at most once in 30 days.
CREATE TABLE IF NOT EXISTS catalogue_checked (
  kind TEXT NOT NULL,
  id INTEGER NOT NULL,
  checked TEXT NOT NULL,
  PRIMARY KEY (kind, id)
);
