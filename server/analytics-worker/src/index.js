// MangaCarta analytics ingest — a Cloudflare Worker over D1.
//
// Design: docs/superpowers/specs/2026-11-09-analytics-design.md §1 (option B), §2, §7, §13
// and Amendment 3. The Worker reads only the request body: it never touches request
// headers, `request.cf` or a time of day, and it never logs (§7.1). Any invalid event rejects
// the whole batch with 400 and nothing is written (Amendment 3 item 9).

export const MAX_BODY_BYTES = 65536;
export const MAX_EVENTS = 100;
const MAX_CLASSIFY = 200;
const CLASSIFY_CHUNK = 50;
const RECHECK_DAYS = 30;
const RETENTION_MONTHS = 12;
const EARLIEST_DAY = "2026-01-01";
const ANILIST_URL = "https://graphql.anilist.co";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const PRINTABLE_ASCII = /^[\x20-\x7e]{1,32}$/;

const ENVELOPE_KEYS = ["v", "install", "day", "app", "name"];

const MODES = ["ltr", "rtl", "vertical"];
const REASONS = ["tag", "anilist", "mal", "explore", "other"];
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
  if (!Number.isSafeInteger(value) || value <= 0) fail();
  return value;
}

/** An ids object: only `mal` and/or `anilist`, at least one, each a positive safe integer. */
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

const PENDING_IDS = `
  SELECT kind, id FROM (
    SELECT 'mal' AS kind, mal AS id FROM events WHERE mal IS NOT NULL
    UNION SELECT 'mal', to_mal FROM events WHERE to_mal IS NOT NULL
    UNION SELECT 'anilist', anilist FROM events WHERE anilist IS NOT NULL
    UNION SELECT 'anilist', to_anilist FROM events WHERE to_anilist IS NOT NULL
  ) AS seen
  WHERE NOT EXISTS (
    SELECT 1 FROM catalogue_checked AS c WHERE c.kind = seen.kind AND c.id = seen.id AND c.checked > ?
  )
  ORDER BY kind, id
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
      for (const entry of media.filter(isAdultMedia)) {
        if (Number.isSafeInteger(entry.idMal) && entry.idMal > 0) {
          statements.push(env.DB.prepare("INSERT OR IGNORE INTO adult_catalogue (kind, id) VALUES ('mal', ?)").bind(entry.idMal));
        }
        if (Number.isSafeInteger(entry.id) && entry.id > 0) {
          statements.push(env.DB.prepare("INSERT OR IGNORE INTO adult_catalogue (kind, id) VALUES ('anilist', ?)").bind(entry.id));
        }
      }
      for (const id of chunk) {
        statements.push(
          env.DB.prepare(
            "INSERT INTO catalogue_checked (kind, id, checked) VALUES (?, ?, ?) " +
              "ON CONFLICT (kind, id) DO UPDATE SET checked = excluded.checked",
          ).bind(kind, id, today),
        );
      }
      await env.DB.batch(statements);
    }
  }
}

/**
 * The daily cron: (a) the 12-month purge by `received`, (b) adult classification through
 * AniList, (c) the adult purge. In that order, so an id classified tonight is purged tonight.
 * @param {{ DB: D1Database }} env
 * @param {{ now: Date, fetchImpl: typeof fetch }} options
 */
export async function runDailyMaintenance(env, { now, fetchImpl }) {
  const today = utcDay(now);
  const cutoff = subtractMonths(today, RETENTION_MONTHS);
  await env.DB.prepare("DELETE FROM events WHERE received < ?").bind(cutoff).run();
  await classify(env, today, fetchImpl);
  await env.DB.prepare(ADULT_PURGE).run();
}

export default {
  async fetch(request, env) {
    return handleRequest(request, env, new Date());
  },
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(runDailyMaintenance(env, { now: new Date(), fetchImpl: fetch }));
  },
};
