import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { handleRequest, MAX_BODY_BYTES } from "../src/index.js";
import { makeD1 } from "./support/d1.mjs";
import { event, INSTALL, NOW, post } from "./support/fixtures.mjs";

const EVENT_COLUMNS = ["id", "install", "day", "received", "app", "name", "mal", "anilist", "to_mal", "to_anilist", "attrs"];

/** A request that throws if the Worker reads its headers or `cf`: the Worker reads only the body. */
function bodyOnly(request) {
  return new Proxy(request, {
    get(target, property) {
      if (property === "headers" || property === "cf") throw new Error(`Worker read request.${String(property)}`);
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

describe("POST /v1/events — a valid batch", () => {
  test("stores one row per event, and no column or value holds the request's IP, user agent or any header", async () => {
    const DB = makeD1();
    const request = post(
      { v: 1, events: [event("work_saved", { ids: { mal: 1 } }), event("app_active"), event("search_used")] },
      {
        headers: {
          "CF-Connecting-IP": "203.0.113.77",
          "X-Forwarded-For": "198.51.100.23",
          "User-Agent": "MangaCartaProbe/9.9",
          "X-Probe-Header": "probe-header-value",
        },
      },
    );
    const response = await handleRequest(bodyOnly(request), { DB }, NOW);
    assert.equal(response.status, 204);
    assert.equal(await response.text(), "");

    const rows = DB.rows();
    assert.equal(rows.length, 3);
    for (const row of rows) assert.deepEqual(Object.keys(row), EVENT_COLUMNS);

    const everything = JSON.stringify([
      DB.rows(),
      DB.rows("SELECT * FROM adult_catalogue"),
      DB.rows("SELECT * FROM catalogue_checked"),
    ]);
    for (const leaked of ["203.0.113.77", "198.51.100.23", "MangaCartaProbe", "probe-header-value", "application/json", "T12:"]) {
      assert.ok(!everything.includes(leaked), `stored ${leaked}`);
    }
    const columns = DB.sqlite.prepare("SELECT name FROM pragma_table_info('events')").all().map((c) => c.name);
    assert.deepEqual(columns, EVENT_COLUMNS);
  });

  test("every event name is accepted and stored with its columns and canonical attrs", async () => {
    const cases = [
      [event("work_saved", { ids: { mal: 11 } }), { mal: 11, anilist: null, attrs: "{}" }],
      [event("work_unsaved", { ids: { anilist: 12 } }), { mal: null, anilist: 12, attrs: "{}" }],
      [event("rec_not_interested", { ids: { mal: 13, anilist: 113 } }), { mal: 13, anilist: 113, attrs: "{}" }],
      [event("rec_more_like_this", { ids: { anilist: 14, mal: 4 } }), { mal: 4, anilist: 14, attrs: "{}" }],
      [event("chapter_completed", { progress: 12, ids: { mal: 15 } }), { mal: 15, attrs: '{"progress":12}' }],
      [
        event("for_you_opened", { reason: "explore", rank: 0, ids: { mal: 16 } }),
        { mal: 16, attrs: '{"rank":0,"reason":"explore"}' },
      ],
      [event("for_you_shown", { count: 20 }), { mal: null, attrs: '{"count":20}' }],
      [
        event("mlt_opened", { from: { mal: 17, anilist: 117 }, to: { mal: 18 } }),
        { mal: 17, anilist: 117, to_mal: 18, to_anilist: null, attrs: "{}" },
      ],
      [event("app_active"), { attrs: "{}" }],
      [event("search_used"), { attrs: "{}" }],
      [event("analytics_enabled"), { attrs: "{}" }],
      [event("reader_opened", { mode: "rtl" }), { attrs: '{"mode":"rtl"}' }],
      [event("local_import_finished", { files: "2-9" }), { attrs: '{"files":"2-9"}' }],
      [event("source_installed", { adult: "adultOnly" }), { attrs: '{"adult":"adultOnly"}' }],
      [event("setting_changed", { on: false, key: "show_adult" }), { attrs: '{"key":"show_adult","on":false}' }],
      [
        event("setting_changed", { key: "reading_mode_default", value: "vertical" }),
        { attrs: '{"key":"reading_mode_default","value":"vertical"}' },
      ],
    ];
    const DB = makeD1();
    const response = await handleRequest(post({ v: 1, events: cases.map(([e]) => e) }), { DB }, NOW);
    assert.equal(response.status, 204);
    const rows = DB.rows();
    assert.equal(rows.length, cases.length);
    rows.forEach((row, index) => {
      const [sent, expected] = cases[index];
      assert.equal(row.name, sent.name);
      assert.equal(row.install, INSTALL.toLowerCase());
      assert.equal(row.day, "2026-11-15");
      assert.equal(row.received, "2026-11-15");
      assert.equal(row.app, "1.0 (42)");
      for (const [column, value] of Object.entries(expected)) assert.equal(row[column], value, `${sent.name}.${column}`);
    });
  });

  test("the limits themselves are accepted: 100 events, tomorrow's day, a 32-character app, a body of exactly 64 KB", async () => {
    const DB = makeD1();
    const hundred = { v: 1, events: Array.from({ length: 100 }, () => event("app_active")) };
    assert.equal((await handleRequest(post(hundred), { DB }, NOW)).status, 204);

    const edge = { v: 1, events: [event("app_active", {}, { day: "2026-11-16", app: "x".repeat(32) })] };
    assert.equal((await handleRequest(post(edge), { DB }, NOW)).status, 204);

    const body = JSON.stringify({ v: 1, events: [event("app_active")] });
    const padded = body + " ".repeat(MAX_BODY_BYTES - Buffer.byteLength(body));
    assert.equal(Buffer.byteLength(padded), MAX_BODY_BYTES);
    assert.equal((await handleRequest(post(padded), { DB }, NOW)).status, 204);
    assert.equal(DB.rows().length, 102);
  });
});

describe("POST /v1/events — each invalid input rejects the whole batch with 400 and writes nothing", () => {
  const good = event("work_saved", { ids: { mal: 1 } });
  const batch = (...events) => ({ v: 1, events: [good, ...events] });
  const cases = {
    "unknown batch v": { v: 2, events: [good] },
    "batch v as a string": { v: "1", events: [good] },
    "unknown top-level key": { v: 1, events: [good], extra: true },
    "missing events": { v: 1 },
    "events not an array": { v: 1, events: { 0: good } },
    "zero events": { v: 1, events: [] },
    "more than 100 events": { v: 1, events: Array.from({ length: 101 }, () => good) },
    "unknown event v": batch(event("app_active", {}, { v: 2 })),
    "event v missing": batch((({ v, ...rest }) => rest)(event("app_active"))),
    "unknown name": batch(event("work_deleted", { ids: { mal: 1 } })),
    "inherited property as a name": batch(event("constructor")),
    "non-integer id": batch(event("work_saved", { ids: { mal: 1.5 } })),
    "zero id": batch(event("work_saved", { ids: { mal: 0 } })),
    "negative id": batch(event("work_saved", { ids: { anilist: -3 } })),
    "string id": batch(event("work_saved", { ids: { mal: "12" } })),
    "unsafe integer id": batch(event("work_saved", { ids: { mal: 2 ** 53 } })),
    "non-integer to id": batch(event("mlt_opened", { from: { mal: 1 }, to: { mal: 2.5 } })),
    "empty ids": batch(event("work_saved", { ids: {} })),
    "ids as an array": batch(event("work_saved", { ids: [1] })),
    "unknown key in ids": batch(event("work_saved", { ids: { mal: 1, mangadex: 2 } })),
    "unknown event key": batch(event("app_active", { title: "Berserk" })),
    "extra field on a fielded event": batch(event("chapter_completed", { ids: { mal: 1 }, progress: 1, page: 3 })),
    "missing field": batch(event("chapter_completed", { ids: { mal: 1 } })),
    "missing envelope key": batch((({ app, ...rest }) => rest)(event("app_active"))),
    "bad UUID": batch(event("app_active", {}, { install: "not-a-uuid" })),
    "UUID without dashes": batch(event("app_active", {}, { install: INSTALL.replaceAll("-", "") })),
    "bad day format": batch(event("app_active", {}, { day: "2026-11-15T12:00:00Z" })),
    "impossible day": batch(event("app_active", {}, { day: "2026-02-30" })),
    "future day": batch(event("app_active", {}, { day: "2026-11-17" })),
    "day before 2026": batch(event("app_active", {}, { day: "2025-12-31" })),
    "app too long": batch(event("app_active", {}, { app: "x".repeat(33) })),
    "empty app": batch(event("app_active", {}, { app: "" })),
    "non-printable app": batch(event("app_active", {}, { app: "1.0\n(42)" })),
    "non-ASCII app": batch(event("app_active", {}, { app: "1.0 (４２)" })),
    "progress out of range": batch(event("chapter_completed", { ids: { mal: 1 }, progress: 100001 })),
    "negative progress": batch(event("chapter_completed", { ids: { mal: 1 }, progress: -1 })),
    "rank out of range": batch(event("for_you_opened", { ids: { mal: 1 }, rank: 1000, reason: "tag" })),
    "unknown reason": batch(event("for_you_opened", { ids: { mal: 1 }, rank: 1, reason: "Isekai" })),
    "zero count": batch(event("for_you_shown", { count: 0 })),
    "count out of range": batch(event("for_you_shown", { count: 1001 })),
    "unknown mode": batch(event("reader_opened", { mode: "webtoon" })),
    "unknown file bucket": batch(event("local_import_finished", { files: "3" })),
    "unknown adult class": batch(event("source_installed", { adult: "adult" })),
    "unknown setting key": batch(event("setting_changed", { key: "theme", on: true })),
    "boolean setting with a string": batch(event("setting_changed", { key: "notifications", on: "true" })),
    "boolean setting with a value": batch(event("setting_changed", { key: "notifications", value: "ltr" })),
    "reading mode setting with on": batch(event("setting_changed", { key: "reading_mode_default", on: true })),
    "reading mode setting with a bad value": batch(event("setting_changed", { key: "reading_mode_default", value: "up" })),
    "an event that is not an object": batch("app_active"),
    "a body that is not an object": [good],
  };

  for (const [label, body] of Object.entries(cases)) {
    test(label, async () => {
      const DB = makeD1();
      const response = await handleRequest(post(body), { DB }, NOW);
      assert.equal(response.status, 400);
      assert.equal(DB.rows().length, 0);
    });
  }

  test("not JSON", async () => {
    const DB = makeD1();
    assert.equal((await handleRequest(post("{v:1"), { DB }, NOW)).status, 400);
    assert.equal((await handleRequest(post(""), { DB }, NOW)).status, 400);
    assert.equal(DB.rows().length, 0);
  });

  test("an oversized body, counted in bytes actually read from a stream with no length", async () => {
    const DB = makeD1();
    const body = JSON.stringify({ v: 1, events: [event("app_active")] });
    const padded = body + " ".repeat(MAX_BODY_BYTES + 1 - Buffer.byteLength(body));
    const bytes = new TextEncoder().encode(padded);
    const stream = new ReadableStream({
      start(controller) {
        for (let offset = 0; offset < bytes.length; offset += 1000) controller.enqueue(bytes.slice(offset, offset + 1000));
        controller.close();
      },
    });
    const request = new Request("https://analytics.example.workers.dev/v1/events", { method: "POST", body: stream, duplex: "half" });
    assert.equal((await handleRequest(request, { DB }, NOW)).status, 400);
    assert.equal((await handleRequest(post(padded), { DB }, NOW)).status, 400);
    assert.equal(DB.rows().length, 0);
  });

  test("a storage failure part-way through the batch writes nothing and answers 500", async () => {
    const DB = makeD1();
    DB.sqlite.exec("CREATE TRIGGER fail BEFORE INSERT ON events WHEN NEW.app = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END;");
    const body = { v: 1, events: [event("app_active"), event("app_active", {}, { app: "boom" })] };
    assert.equal((await handleRequest(post(body), { DB }, NOW)).status, 500);
    assert.equal(DB.rows().length, 0);
  });
});

describe("routing", () => {
  test("unknown paths are 404, wrong methods on known paths are 405, and there is no CORS", async () => {
    const DB = makeD1();
    const base = "https://analytics.example.workers.dev";
    const cases = [
      ["GET", "/", 404],
      ["POST", "/v1/event", 404],
      ["POST", "/v2/events", 404],
      ["GET", "/v1/installs", 404],
      ["DELETE", `/v1/installs/${INSTALL}/extra`, 404],
      ["GET", "/v1/events", 405],
      ["OPTIONS", "/v1/events", 405],
      ["DELETE", "/v1/events", 405],
      ["GET", `/v1/installs/${INSTALL}`, 405],
      ["POST", `/v1/installs/${INSTALL}`, 405],
    ];
    for (const [method, path, status] of cases) {
      const response = await handleRequest(new Request(base + path, { method }), { DB }, NOW);
      assert.equal(response.status, status, `${method} ${path}`);
      assert.equal(response.headers.get("Access-Control-Allow-Origin"), null);
      assert.ok((await response.text()).length <= 20);
    }
  });
});
