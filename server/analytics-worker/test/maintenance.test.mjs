import assert from "node:assert/strict";
import { describe, test } from "node:test";
import worker, { runDailyMaintenance, subtractMonths } from "../src/index.js";
import { makeD1 } from "./support/d1.mjs";
import { INSTALL, NOW } from "./support/fixtures.mjs";

const install = INSTALL.toLowerCase();

function insert(DB, { day = "2026-11-15", received = "2026-11-15", mal = null, anilist = null, to_mal = null, to_anilist = null, name = "work_saved" } = {}) {
  DB.sqlite
    .prepare("INSERT INTO events (install, day, received, app, name, mal, anilist, to_mal, to_anilist, attrs) VALUES (?, ?, ?, '1.0 (42)', ?, ?, ?, ?, ?, '{}')")
    .run(install, day, received, name, mal, anilist, to_mal, to_anilist);
}

/** A fake AniList: answers from `catalogue`, records every request, never touches the network. */
function fakeAniList(catalogue, { fail = false } = {}) {
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push({ url, init, body: JSON.parse(init.body) });
    if (fail) throw new Error("offline");
    const { query, variables } = JSON.parse(init.body);
    const byMal = query.includes("idMal_in:");
    const media = catalogue.filter((m) => variables.ids.includes(byMal ? m.idMal : m.id));
    return new Response(JSON.stringify({ data: { Page: { media } } }), { status: 200 });
  };
  return { fetchImpl, requests };
}

const noAdults = () => fakeAniList([]).fetchImpl;

describe("retention purge", () => {
  test("removes rows received more than 12 months ago and keeps the rest", async () => {
    const DB = makeD1();
    insert(DB, { received: "2025-11-14", day: "2026-11-01", name: "old_received" }); // deleted: received too old
    insert(DB, { received: "2025-11-15", name: "exactly_twelve_months" }); // kept: on the cutoff
    insert(DB, { received: "2026-11-15", day: "2025-10-01", name: "old_day_new_received" }); // kept: retention is by received
    insert(DB, { received: "2025-10-20", name: "thirteenth_month" }); // deleted
    await runDailyMaintenance({ DB }, { now: NOW, fetchImpl: noAdults() });
    const names = DB.rows().map((row) => row.name).sort();
    assert.deepEqual(names, ["exactly_twelve_months", "old_day_new_received"]);
  });

  test("twelve calendar months back clamps to the end of a shorter month", () => {
    assert.equal(subtractMonths("2026-11-15", 12), "2025-11-15");
    assert.equal(subtractMonths("2028-02-29", 12), "2027-02-28");
    assert.equal(subtractMonths("2027-01-01", 12), "2026-01-01");
  });
});

describe("adult purge", () => {
  test("removes a row when any of its four id columns is listed, for the matching kind only", async () => {
    const DB = makeD1();
    DB.sqlite.exec("INSERT INTO adult_catalogue (kind, id) VALUES ('mal', 900), ('anilist', 800)");
    insert(DB, { mal: 900, name: "listed_mal" });
    insert(DB, { anilist: 800, name: "listed_anilist" });
    insert(DB, { mal: 1, to_mal: 900, name: "listed_to_mal" });
    insert(DB, { anilist: 2, to_anilist: 800, name: "listed_to_anilist" });
    insert(DB, { mal: 800, anilist: 900, name: "ids_of_the_other_kind" }); // kept: kinds don't cross
    insert(DB, { mal: 3, anilist: 4, name: "clean" });
    insert(DB, { name: "no_ids" });
    await runDailyMaintenance({ DB }, { now: NOW, fetchImpl: noAdults() });
    const names = DB.rows().map((row) => row.name).sort();
    assert.deepEqual(names, ["clean", "ids_of_the_other_kind", "no_ids"]);
  });
});

describe("classification", () => {
  test("records isAdult or Hentai ids, skips ids checked within 30 days, and sends no install id to AniList", async () => {
    const DB = makeD1();
    insert(DB, { mal: 10 }); // isAdult
    insert(DB, { mal: 11 }); // Hentai genre, isAdult false
    insert(DB, { mal: 12, to_mal: 13 }); // ordinary; 13 is absent from AniList's answer
    insert(DB, { anilist: 5000, to_anilist: 5001 }); // 5000 isAdult; 5001 ordinary
    insert(DB, { mal: 14 }); // checked 10 days ago: skipped
    insert(DB, { mal: 15 }); // checked 31 days ago: asked again
    DB.sqlite.exec(`INSERT INTO catalogue_checked (kind, id, checked) VALUES ('mal', 14, '2026-11-05'), ('mal', 15, '2026-10-15')`);

    const { fetchImpl, requests } = fakeAniList([
      { id: 1010, idMal: 10, isAdult: true, genres: ["Drama"] },
      { id: 1011, idMal: 11, isAdult: false, genres: ["Hentai", "Comedy"] },
      { id: 1012, idMal: 12, isAdult: false, genres: ["Action"] },
      { id: 1014, idMal: 14, isAdult: true, genres: [] },
      { id: 1015, idMal: 15, isAdult: false, genres: [] },
      { id: 5000, idMal: null, isAdult: true, genres: [] },
      { id: 5001, idMal: 501, isAdult: false, genres: [] },
    ]);
    await runDailyMaintenance({ DB }, { now: NOW, fetchImpl });

    const adults = DB.rows("SELECT kind, id FROM adult_catalogue ORDER BY kind, id").map((r) => `${r.kind}:${r.id}`);
    assert.deepEqual(adults, ["anilist:1010", "anilist:1011", "anilist:5000", "mal:10", "mal:11"]);

    const asked = requests.flatMap((r) => r.body.variables.ids.map((id) => `${r.body.query.includes("idMal_in:") ? "mal" : "anilist"}:${id}`));
    assert.deepEqual(asked.sort(), ["anilist:5000", "anilist:5001", "mal:10", "mal:11", "mal:12", "mal:13", "mal:15"]);

    const checked = DB.rows("SELECT kind, id, checked FROM catalogue_checked ORDER BY kind, id").map((r) => `${r.kind}:${r.id}:${r.checked}`);
    assert.deepEqual(checked, [
      "anilist:5000:2026-11-15",
      "anilist:5001:2026-11-15",
      "mal:10:2026-11-15",
      "mal:11:2026-11-15",
      "mal:12:2026-11-15",
      "mal:13:2026-11-15",
      "mal:14:2026-11-05",
      "mal:15:2026-11-15",
    ]);

    for (const { url, init, body } of requests) {
      assert.equal(url, "https://graphql.anilist.co");
      assert.equal(init.method, "POST");
      assert.deepEqual(Object.keys(body).sort(), ["query", "variables"]);
      assert.deepEqual(Object.keys(body.variables), ["ids"]);
      assert.ok(body.variables.ids.every((id) => Number.isSafeInteger(id) && id > 0));
      assert.match(body.query, /Page\(perPage: 50\) \{ media\((idMal_in|id_in): \$ids, type: MANGA\) \{ id idMal isAdult genres \} \}/);
      const sent = JSON.stringify(init).toLowerCase();
      assert.ok(!sent.includes(install) && !sent.includes("install"), "an install id was sent to AniList");
    }

    // Step (c) ran after classification: the newly listed ids' rows are gone the same night.
    const remaining = DB.rows().map((r) => r.mal ?? r.anilist).sort((a, b) => a - b);
    assert.deepEqual(remaining, [12, 14, 15]);
  });

  test("asks in chunks of 50, at most 200 ids a night", async () => {
    const DB = makeD1();
    for (let id = 1; id <= 230; id += 1) insert(DB, { mal: id });
    const { fetchImpl, requests } = fakeAniList([]);
    await runDailyMaintenance({ DB }, { now: NOW, fetchImpl });
    assert.deepEqual(requests.map((r) => r.body.variables.ids.length), [50, 50, 50, 50]);
    assert.equal(DB.rows("SELECT * FROM catalogue_checked").length, 200);
  });

  test("takes the oldest due ids, so a flood of low ids can't starve a real one", async () => {
    const DB = makeD1();
    insert(DB, { mal: 900000, received: "2026-11-10" }); // the real title, seen first
    insert(DB, { to_anilist: 900001, received: "2026-11-10" });
    for (let id = 1; id <= 400; id += 1) insert(DB, { mal: id });
    const askedOn = async (day) => {
      const { fetchImpl, requests } = fakeAniList([]);
      await runDailyMaintenance({ DB }, { now: new Date(`${day}T12:00:00Z`), fetchImpl });
      return requests.flatMap((r) => r.body.variables.ids);
    };
    const first = await askedOn("2026-11-15");
    assert.equal(first.length, 200);
    assert.ok(first.includes(900000) && first.includes(900001));
    // A bigger flood arrives while 202 ids still wait, and a recheck falls due behind them.
    for (let id = 1001; id <= 1400; id += 1) insert(DB, { mal: id, received: "2026-11-16" });
    const second = await askedOn("2026-11-16");
    assert.ok(second.every((id) => id >= 199 && id <= 400), "the older ids go before the new flood");
  });

  for (const { ahead, asked } of [{ ahead: 199, asked: true }, { ahead: 200, asked: false }]) {
    test(`a recheck keeps its place: ${ahead} ids due before it, and it is ${asked ? "" : "not "}asked`, async () => {
      const DB = makeD1();
      insert(DB, { mal: 5000, received: "2026-09-01" });
      DB.sqlite.exec("INSERT INTO catalogue_checked (kind, id, checked) VALUES ('mal', 5000, '2026-10-12')"); // due 2026-11-11
      for (let id = 1; id <= ahead; id += 1) insert(DB, { mal: id, received: "2026-11-10" });
      for (let id = 201; id <= 300; id += 1) insert(DB, { mal: id, received: "2026-11-12" });
      const { fetchImpl, requests } = fakeAniList([]);
      await runDailyMaintenance({ DB }, { now: NOW, fetchImpl });
      const ids = requests.flatMap((r) => r.body.variables.ids).sort((a, b) => a - b);
      assert.deepEqual(ids, [...Array.from({ length: ahead }, (_, i) => i + 1), ...(asked ? [5000] : [])]);
    });
  }

  test("a failed fetch marks nothing checked", async () => {
    const DB = makeD1();
    insert(DB, { mal: 10 });
    const { fetchImpl } = fakeAniList([], { fail: true });
    await runDailyMaintenance({ DB }, { now: NOW, fetchImpl });
    assert.equal(DB.rows("SELECT * FROM catalogue_checked").length, 0);

    const notOK = async () => new Response("slow down", { status: 429 });
    await runDailyMaintenance({ DB }, { now: NOW, fetchImpl: notOK });
    assert.equal(DB.rows("SELECT * FROM catalogue_checked").length, 0);

    const malformed = async () => new Response(JSON.stringify({ errors: [{ message: "x" }] }), { status: 200 });
    await runDailyMaintenance({ DB }, { now: NOW, fetchImpl: malformed });
    assert.equal(DB.rows("SELECT * FROM catalogue_checked").length, 0);
    assert.equal(DB.rows().length, 1);
  });
});

test("the scheduled handler hands maintenance to ctx.waitUntil", async () => {
  const DB = makeD1();
  const waited = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({ data: { Page: { media: [] } } }), { status: 200 });
  try {
    await worker.scheduled({}, { DB }, { waitUntil: (promise) => waited.push(promise) });
    assert.equal(waited.length, 1);
    await waited[0];
  } finally {
    globalThis.fetch = realFetch;
  }
});
