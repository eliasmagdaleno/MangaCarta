// MangaCarta analytics ingest — a Cloudflare Worker over D1.
//
// Design: docs/superpowers/specs/2026-11-09-analytics-design.md §1 (option B), §2, §7, §13
// and Amendment 3. The Worker reads only the request body: it never touches request
// headers, `request.cf` or a time of day, and it never logs (§7.1). Any invalid event rejects
// the whole batch with 400 and nothing is written (Amendment 3 item 9).

export const MAX_BODY_BYTES = 65536;
export const MAX_EVENTS = 100;
const MAX_CATALOGUE_ID = 2 ** 31 - 1;
const MAX_CLASSIFY = 200;
const CLASSIFY_CHUNK = 50;
const RECHECK_DAYS = 30;
const RETENTION_MONTHS = 12;
const CO_MIN_INSTALLS = 20;
const CO_MAX_IDS = 500;
const CO_MAX_PER_INSTALL = 100;
const CO_MAX_NEIGHBORS = 20;
const CO_ROUNDING = 5;
const EARLIEST_DAY = "2026-01-01";
const ANILIST_URL = "https://graphql.anilist.co";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const PRINTABLE_ASCII = /^[\x20-\x7e]{1,32}$/;

const ENVELOPE_KEYS = ["v", "install", "day", "app", "name"];

const MODES = ["ltr", "rtl", "vertical"];
const REASONS = ["tag", "cooccurrence", "anilist", "mal", "explore", "other"];
const FILE_BUCKETS = ["1", "2-9", "10+"];
const ADULT_CLASSES = ["none", "mixed", "adultOnly"];
const BOOL_SETTINGS = ["notifications", "mal_sync", "show_adult"];

class Invalid extends Error {}

function fail() {
  throw new Invalid();
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(object, keys) {
  const actual = Object.keys(object);
  return actual.length === keys.length && keys.every((key) => Object.hasOwn(object, key));
}

function intIn(value, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) fail();
  return value;
}

function oneOf(value, allowed) {
  if (typeof value !== "string" || !allowed.includes(value)) fail();
  return value;
}

function positiveId(value) {
  // AniList's ids are GraphQL Ints. One larger id would fail its whole classification chunk,
  // every night.
  return intIn(value, 1, MAX_CATALOGUE_ID);
}

/** An ids object: only `mal` and/or `anilist`, at least one, each a positive 32-bit integer. */
function catalogueIDs(value) {
  if (!isObject(value)) fail();
  const keys = Object.keys(value);
  if (keys.length === 0 || keys.some((key) => key !== "mal" && key !== "anilist")) fail();
  return {
    mal: value.mal === undefined ? null : positiveId(value.mal),
    anilist: value.anilist === undefined ? null : positiveId(value.anilist),
  };
}

/** @param {Date} date */
export function utcDay(date) {
  return date.toISOString().slice(0, 10);
}

function addDays(day, days) {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return utcDay(date);
}

/** The same calendar day `months` earlier, clamped to the end of a shorter month. */
export function subtractMonths(day, months) {
  const [year, month, dayOfMonth] = day.split("-").map(Number);
  const target = new Date(Date.UTC(year, month - 1 - months, 1));
  const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(dayOfMonth, lastDay));
  return utcDay(target);
}

function validDay(value, now) {
  if (typeof value !== "string" || !DAY.test(value)) fail();
  // A real date: 2026-02-30 would roll over to March and no longer read back the same.
  const [year, month, dayOfMonth] = value.split("-").map(Number);
  if (utcDay(new Date(Date.UTC(year, month - 1, dayOfMonth))) !== value) fail();
  if (value < EARLIEST_DAY || value > addDays(utcDay(now), 1)) fail();
  return value;
}

/**
 * Each event's own fields: the exact keys it must carry, and how to turn them into columns.
 * `attrs` is rebuilt from validated values with its keys in sorted order, never copied.
 */
const IDS_ONLY = { keys: ["ids"], build: (e) => ({ ids: catalogueIDs(e.ids), attrs: {} }) };
const NO_FIELDS = { keys: [], build: () => ({ attrs: {} }) };

const EVENTS = {
  work_saved: IDS_ONLY,
  work_unsaved: IDS_ONLY,
  rec_not_interested: IDS_ONLY,
  rec_more_like_this: IDS_ONLY,
  chapter_completed: {
    keys: ["ids", "progress"],
    build: (e) => ({ ids: catalogueIDs(e.ids), attrs: { progress: intIn(e.progress, 0, 100000) } }),
  },
  for_you_opened: {
    keys: ["ids", "rank", "reason"],
    build: (e) => ({
      ids: catalogueIDs(e.ids),
      attrs: { rank: intIn(e.rank, 0, 999), reason: oneOf(e.reason, REASONS) },
    }),
  },
  for_you_shown: { keys: ["count"], build: (e) => ({ attrs: { count: intIn(e.count, 1, 1000) } }) },
  mlt_opened: {
    keys: ["from", "to"],
    build: (e) => ({ ids: catalogueIDs(e.from), to: catalogueIDs(e.to), attrs: {} }),
  },
  app_active: NO_FIELDS,
  search_used: NO_FIELDS,
  analytics_enabled: NO_FIELDS,
  reader_opened: { keys: ["mode"], build: (e) => ({ attrs: { mode: oneOf(e.mode, MODES) } }) },
  local_import_finished: { keys: ["files"], build: (e) => ({ attrs: { files: oneOf(e.files, FILE_BUCKETS) } }) },
  source_installed: { keys: ["adult"], build: (e) => ({ attrs: { adult: oneOf(e.adult, ADULT_CLASSES) } }) },
  setting_changed: {
    keys: (e) => (e.key === "reading_mode_default" ? ["key", "value"] : ["key", "on"]),
    build: (e) => {
      if (e.key === "reading_mode_default") return { attrs: { key: e.key, value: oneOf(e.value, MODES) } };
      const key = oneOf(e.key, BOOL_SETTINGS);
      if (typeof e.on !== "boolean") fail();
      return { attrs: { key, on: e.on } };
    },
  },
};

function canonicalJSON(attrs) {
  const sorted = {};
  for (const key of Object.keys(attrs).sort()) sorted[key] = attrs[key];
  return JSON.stringify(sorted);
}

function validateEvent(event, now) {
  if (!isObject(event)) fail();
  if (typeof event.name !== "string" || !Object.hasOwn(EVENTS, event.name)) fail();
  const spec = EVENTS[event.name];
  const fieldKeys = typeof spec.keys === "function" ? spec.keys(event) : spec.keys;
  if (!hasExactKeys(event, [...ENVELOPE_KEYS, ...fieldKeys])) fail();
  if (event.v !== 1) fail();
  if (typeof event.install !== "string" || !UUID.test(event.install)) fail();
  const day = validDay(event.day, now);
  if (typeof event.app !== "string" || !PRINTABLE_ASCII.test(event.app)) fail();
  const { ids, to, attrs } = spec.build(event);
  return {
    install: event.install.toLowerCase(),
    day,
    app: event.app,
    name: event.name,
    mal: ids?.mal ?? null,
    anilist: ids?.anilist ?? null,
    to_mal: to?.mal ?? null,
    to_anilist: to?.anilist ?? null,
    attrs: canonicalJSON(attrs),
  };
}

/**
 * Validates a parsed batch body. Returns the rows to insert, or null if anything is invalid.
 * @param {unknown} json
 * @param {Date} now
 */
export function validateBatch(json, now) {
  try {
    if (!isObject(json) || !hasExactKeys(json, ["v", "events"])) fail();
    if (json.v !== 1) fail();
    const { events } = json;
    if (!Array.isArray(events) || events.length < 1 || events.length > MAX_EVENTS) fail();
    return events.map((event) => validateEvent(event, now));
  } catch (error) {
    if (error instanceof Invalid) return null;
    throw error;
  }
}

/** Reads at most MAX_BODY_BYTES of the body; null if it is longer. Counts real bytes. */
async function readCappedBody(request) {
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function reply(status, word, allow) {
  const headers = allow ? { Allow: allow } : undefined;
  return new Response(status === 204 ? null : word, { status, headers });
}

const INSERT_EVENT =
  "INSERT INTO events (install, day, received, app, name, mal, anilist, to_mal, to_anilist, attrs) " +
  "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

async function ingest(request, env, now) {
  const bytes = await readCappedBody(request);
  if (bytes === null) return reply(400, "bad request");
  let json;
  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return reply(400, "bad request");
  }
  const rows = validateBatch(json, now);
  if (rows === null) return reply(400, "bad request");
  const received = utcDay(now);
  await env.DB.batch(
    rows.map((row) =>
      env.DB.prepare(INSERT_EVENT).bind(
        row.install, row.day, received, row.app, row.name,
        row.mal, row.anilist, row.to_mal, row.to_anilist, row.attrs,
      ),
    ),
  );
  return reply(204);
}

async function deleteInstall(id, env) {
  if (!UUID.test(id)) return reply(400, "bad request");
  // 204 whether or not rows existed: the response never reveals whether an id was known (§13).
  await env.DB.prepare("DELETE FROM events WHERE install = lower(?)").bind(id).run();
  return reply(204);
}

/**
 * @param {Request} request
 * @param {{ DB: D1Database }} env
 * @param {Date} now
 */
export async function handleRequest(request, env, now) {
  const { pathname } = new URL(request.url);
  try {
    if (pathname === "/v1/events") {
      if (request.method !== "POST") return reply(405, "method not allowed", "POST");
      return await ingest(request, env, now);
    }
    if (pathname === "/v1/cooccurrence-v1.json") {
      if (request.method !== "GET") return reply(405, "method not allowed", "GET");
      const row = await env.DB.prepare("SELECT body FROM published WHERE name = 'cooccurrence-v1.json'").first();
      const body = row?.body ?? JSON.stringify({ v: 1, k: CO_MIN_INSTALLS, pairs: {} });
      return new Response(body, {
        status: 200,
        headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=86400" },
      });
    }
    const install = /^\/v1\/installs\/([^/]+)$/.exec(pathname);
    if (install) {
      if (request.method !== "DELETE") return reply(405, "method not allowed", "DELETE");
      return await deleteInstall(install[1], env);
    }
    return reply(404, "not found");
  } catch {
    // A storage failure. 5xx makes the client keep its events and retry later (§11.3).
    return reply(500, "error");
  }
}

// MARK: - Daily maintenance

// Oldest due first: an id never checked is due on the day it was first received, a checked id
// when its recheck falls due. The order never depends on the id, so a client can't send low ids
// to keep its own at the front (Amendment 4).
const PENDING_IDS = `
  SELECT seen.kind, seen.id FROM (
    SELECT kind, id, MIN(received) AS first_received, MIN(event) AS first_event FROM (
      SELECT 'mal' AS kind, mal AS id, received, id AS event FROM events WHERE mal IS NOT NULL
      UNION ALL SELECT 'mal', to_mal, received, id FROM events WHERE to_mal IS NOT NULL
      UNION ALL SELECT 'anilist', anilist, received, id FROM events WHERE anilist IS NOT NULL
      UNION ALL SELECT 'anilist', to_anilist, received, id FROM events WHERE to_anilist IS NOT NULL
    ) GROUP BY kind, id
  ) AS seen
  LEFT JOIN catalogue_checked AS c ON c.kind = seen.kind AND c.id = seen.id
  WHERE c.checked IS NULL OR c.checked <= ?
  ORDER BY COALESCE(date(c.checked, '+${RECHECK_DAYS} days'), seen.first_received),
    seen.first_event, seen.kind, seen.id
  LIMIT ?`;

const ADULT_PURGE = `
  DELETE FROM events
  WHERE mal IN (SELECT id FROM adult_catalogue WHERE kind = 'mal')
     OR to_mal IN (SELECT id FROM adult_catalogue WHERE kind = 'mal')
     OR anilist IN (SELECT id FROM adult_catalogue WHERE kind = 'anilist')
     OR to_anilist IN (SELECT id FROM adult_catalogue WHERE kind = 'anilist')`;

function mediaQuery(kind) {
  const filter = kind === "mal" ? "idMal_in" : "id_in";
  return `query ($ids: [Int]) { Page(perPage: ${CLASSIFY_CHUNK}) { media(${filter}: $ids, type: MANGA) { id idMal isAdult genres } } }`;
}

/** Asks AniList about one chunk of ids of one kind. Null on any failure. */
async function fetchMedia(kind, ids, fetchImpl) {
  try {
    const response = await fetchImpl(ANILIST_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      // Only catalogue ids leave the Worker — never an install id (Amendment 3 item 10).
      body: JSON.stringify({ query: mediaQuery(kind), variables: { ids } }),
    });
    if (!response.ok) return null;
    const json = await response.json();
    const media = json?.data?.Page?.media;
    return Array.isArray(media) ? media : null;
  } catch {
    return null;
  }
}

function isAdultMedia(media) {
  return media.isAdult === true || (Array.isArray(media.genres) && media.genres.includes("Hentai"));
}

async function classify(env, today, fetchImpl) {
  const since = addDays(today, -RECHECK_DAYS);
  const { results } = await env.DB.prepare(PENDING_IDS).bind(since, MAX_CLASSIFY).all();
  for (const kind of ["mal", "anilist"]) {
    const ids = results.filter((row) => row.kind === kind).map((row) => row.id);
    for (let start = 0; start < ids.length; start += CLASSIFY_CHUNK) {
      const chunk = ids.slice(start, start + CLASSIFY_CHUNK);
      const media = await fetchMedia(kind, chunk, fetchImpl);
      // A failed fetch marks nothing checked, so those ids are asked about again tomorrow.
      if (media === null) continue;
      const statements = [];
      // "Known" means AniList returned a record. Checked alone doesn't say so (Amendment 5 item 1).
      const answered = new Set(media.map((entry) => (kind === "mal" ? entry.idMal : entry.id)));
      const known = chunk.filter((id) => answered.has(id));
      const unknown = chunk.filter((id) => !answered.has(id));
      // json_each keeps this to one statement per set: D1 limits the queries in one invocation.
      statements.push(
        env.DB.prepare("INSERT OR IGNORE INTO catalogue_known (kind, id) SELECT ?, value FROM json_each(?)")
          .bind(kind, JSON.stringify(known)),
        env.DB.prepare("DELETE FROM catalogue_known WHERE kind = ? AND id IN (SELECT value FROM json_each(?))")
          .bind(kind, JSON.stringify(unknown)),
        env.DB.prepare(
          "INSERT INTO catalogue_checked (kind, id, checked) SELECT ?, value, ? FROM json_each(?) WHERE true " +
            "ON CONFLICT (kind, id) DO UPDATE SET checked = excluded.checked",
        ).bind(kind, today, JSON.stringify(chunk)),
      );
      for (const entry of media.filter(isAdultMedia)) {
        if (Number.isSafeInteger(entry.idMal) && entry.idMal > 0) {
          statements.push(env.DB.prepare("INSERT OR IGNORE INTO adult_catalogue (kind, id) VALUES ('mal', ?)").bind(entry.idMal));
        }
        if (Number.isSafeInteger(entry.id) && entry.id > 0) {
          statements.push(env.DB.prepare("INSERT OR IGNORE INTO adult_catalogue (kind, id) VALUES ('anilist', ?)").bind(entry.id));
        }
      }
      await env.DB.batch(statements);
    }
  }
}

/**
 * The daily cron: (a) the 12-month purge by `received`, (b) adult classification through
 * AniList, (c) the adult purge, (d) the recommendation table. In that order, so an id classified
 * tonight is purged tonight, and nothing is published unless both purges succeeded.
 * @param {{ DB: D1Database }} env
 * @param {{ now: Date, fetchImpl: typeof fetch }} options
 */
export async function runDailyMaintenance(env, { now, fetchImpl }) {
  const today = utcDay(now);
  const cutoff = subtractMonths(today, RETENTION_MONTHS);
  await env.DB.prepare("DELETE FROM events WHERE received < ?").bind(cutoff).run();
  await classify(env, today, fetchImpl);
  await env.DB.prepare(ADULT_PURGE).run();
  await publishCooccurrence(env);
}

// Eligible ids are reduced to an install/id relation before pair work. MATERIALIZED keeps D1
// and SQLite from expanding these shared stages into repeated scans.
const COOCCURRENCE_QUERY = `
  WITH eligible_events AS MATERIALIZED (
    SELECT install, mal FROM events
    WHERE name IN ('work_saved', 'chapter_completed') AND mal IS NOT NULL
      AND EXISTS (SELECT 1 FROM catalogue_checked c JOIN catalogue_known k USING (kind, id)
        WHERE c.kind = 'mal' AND c.id = events.mal)
      AND NOT EXISTS (SELECT 1 FROM adult_catalogue a WHERE a.kind = 'mal' AND a.id = events.mal)
      AND (anilist IS NULL OR (
        EXISTS (SELECT 1 FROM catalogue_checked c JOIN catalogue_known k USING (kind, id)
          WHERE c.kind = 'anilist' AND c.id = events.anilist)
        AND NOT EXISTS (SELECT 1 FROM adult_catalogue a WHERE a.kind = 'anilist' AND a.id = events.anilist)))
  ), install_ids AS MATERIALIZED (
    SELECT DISTINCT install, mal FROM eligible_events
  ), id_counts AS MATERIALIZED (
    SELECT mal, COUNT(*) AS installs FROM install_ids GROUP BY mal
    HAVING COUNT(*) >= ${CO_MIN_INSTALLS}
  ), kept_ids AS MATERIALIZED (
    SELECT mal, installs FROM id_counts ORDER BY installs DESC, mal ASC LIMIT ${CO_MAX_IDS}
  ), per_install AS MATERIALIZED (
    SELECT i.install, i.mal, c.installs,
      ROW_NUMBER() OVER (PARTITION BY i.install ORDER BY c.installs DESC, i.mal ASC) AS rn
    FROM install_ids i JOIN kept_ids c USING (mal)
  ), bounded AS MATERIALIZED (
    SELECT install, mal FROM per_install WHERE rn <= ${CO_MAX_PER_INSTALL}
  ), pairs AS MATERIALIZED (
    SELECT a.mal AS source, b.mal AS target, COUNT(DISTINCT a.install) AS installs
    FROM bounded a JOIN bounded b ON a.install = b.install AND a.mal <> b.mal
    GROUP BY a.mal, b.mal HAVING COUNT(DISTINCT a.install) >= ${CO_MIN_INSTALLS}
  ), ranked AS MATERIALIZED (
    SELECT source, target, installs,
      ROW_NUMBER() OVER (PARTITION BY source ORDER BY installs DESC, target ASC) AS rn
    FROM pairs
  )
  SELECT source, target, (installs / ${CO_ROUNDING}) * ${CO_ROUNDING} AS count FROM ranked
  WHERE rn <= ${CO_MAX_NEIGHBORS} ORDER BY source ASC, rn ASC`;

async function publishCooccurrence(env) {
  const { results } = await env.DB.prepare(COOCCURRENCE_QUERY).all();
  const pairs = {};
  for (const row of results) {
    const key = String(row.source);
    if (!pairs[key]) pairs[key] = [];
    pairs[key].push([row.target, row.count]);
  }
  const body = JSON.stringify({ v: 1, k: CO_MIN_INSTALLS, pairs });
  await env.DB.prepare("INSERT OR REPLACE INTO published (name, body) VALUES ('cooccurrence-v1.json', ?)").bind(body).run();
}

export default {
  async fetch(request, env) {
    return handleRequest(request, env, new Date());
  },
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(runDailyMaintenance(env, { now: new Date(), fetchImpl: fetch }));
  },
};
