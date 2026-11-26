import assert from "node:assert/strict";
import { test } from "node:test";
import { handleRequest, runDailyMaintenance } from "../src/index.js";
import { makeD1 } from "./support/d1.mjs";
import { NOW } from "./support/fixtures.mjs";

function uuid(n) {
  return `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
}

/** Events for one install, plus the history that lets it count: three days over a week. */
function addInstall(DB, install, ids, { name = "work_saved", anilist = null, days = ["2026-11-08", "2026-11-10"], attested = 1 } = {}) {
  for (const day of days) {
    DB.sqlite.prepare("INSERT INTO events (install, day, received, app, name, attrs, attested) VALUES (?, ?, ?, 'test', 'app_active', '{}', ?)")
      .run(install, day, day, attested);
  }
  for (const mal of ids) {
    DB.sqlite.prepare("INSERT INTO events (install, day, received, app, name, mal, anilist, attrs, attested) VALUES (?, '2026-11-15', '2026-11-15', 'test', ?, ?, ?, '{}', ?)")
      .run(install, name, mal, anilist, attested);
  }
}

function classifyIds(DB, kind, ids, { known = ids, adult = [] } = {}) {
  for (const id of ids) DB.sqlite.prepare("INSERT INTO catalogue_checked (kind, id, checked) VALUES (?, ?, '2026-11-15')").run(kind, id);
  for (const id of known) DB.sqlite.prepare("INSERT INTO catalogue_known (kind, id) VALUES (?, ?)").run(kind, id);
  for (const id of adult) DB.sqlite.prepare("INSERT INTO adult_catalogue (kind, id) VALUES (?, ?)").run(kind, id);
}

async function publish(DB, options = {}) {
  await runDailyMaintenance({ DB }, { now: NOW, fetchImpl: async () => new Response(JSON.stringify({ data: { Page: { media: [] } } })), ...options });
  return JSON.parse(DB.sqlite.prepare("SELECT body FROM published WHERE name = 'cooccurrence-v1.json'").get().body);
}

/**
 * The stored table after maintenance in which no id is due for classification and the adult
 * purge does nothing, so the query's own conditions are what a test sees.
 */
async function aggregate(DB) {
  const purge = DB.prepare;
  DB.prepare = (sql) => {
    if (sql.includes("ORDER BY COALESCE")) return { bind: () => ({ all: async () => ({ results: [] }) }) };
    if (sql.includes("FROM adult_catalogue WHERE kind")) return { run: async () => ({}) };
    return purge.call(DB, sql);
  };
  try {
    return await publish(DB);
  } finally {
    DB.prepare = purge;
  }
}

test("k is 20 distinct installs; repeat events by one install count once", async () => {
  const DB = makeD1();
  classifyIds(DB, "mal", [1, 2]);
  for (let i = 1; i <= 19; i += 1) addInstall(DB, uuid(i), [1, 2]);
  const { pairs } = await aggregate(DB);
  assert.equal(pairs["1"], undefined);
  addInstall(DB, uuid(20), [1, 1, 2]);
  const result = await publish(DB);
  assert.deepEqual(result.pairs["1"], [[2, 20]]);
  assert.deepEqual(result.pairs["2"], [[1, 20]]);
  assert.ok(!JSON.stringify(result).includes(uuid(1)));
});

test("two widely held titles that 19 installs share are not a pair", async () => {
  const DB = makeD1();
  classifyIds(DB, "mal", [1, 2]);
  for (let i = 1; i <= 19; i += 1) addInstall(DB, uuid(i), [1, 2]);
  addInstall(DB, uuid(20), [1]);
  addInstall(DB, uuid(21), [2]);
  // Repeats by one install can't make up the difference.
  addInstall(DB, uuid(1), [1, 2, 1, 2], { name: "chapter_completed" });
  assert.deepEqual((await aggregate(DB)).pairs, {});
});

for (const [label, days] of [
  ["two days", ["2026-11-08"]],
  ["three days within six", ["2026-11-09", "2026-11-10"]],
]) {
  test(`an install seen on ${label} does not count`, async () => {
    const DB = makeD1();
    classifyIds(DB, "mal", [1, 2]);
    for (let i = 1; i <= 19; i += 1) addInstall(DB, uuid(i), [1, 2]);
    addInstall(DB, uuid(20), [1, 2], { days });
    assert.deepEqual((await aggregate(DB)).pairs, {});
    // The same install with its history counts, so only the history kept it out.
    addInstall(DB, uuid(20), [], {});
    assert.deepEqual((await aggregate(DB)).pairs["1"], [[2, 20]]);
  });
}

test("only saves and completions with MAL ids count", async () => {
  const DB = makeD1();
  classifyIds(DB, "mal", [1, 2, 3, 4]);
  for (let i = 1; i <= 20; i += 1) {
    addInstall(DB, uuid(i), [1, 4], { name: "work_unsaved" });
    addInstall(DB, uuid(i + 20), [1, 2], { name: "chapter_completed" });
    addInstall(DB, uuid(i + 40), [1, 3], { name: "work_saved" });
  }
  DB.sqlite.prepare("INSERT INTO events (install, day, received, app, name, attrs) VALUES (?, '2026-11-15', '2026-11-15', 'test', 'work_saved', '{}')").run(uuid(100));
  const { pairs } = await aggregate(DB);
  assert.deepEqual(pairs["1"], [[2, 20], [3, 20]]);
  assert.deepEqual(pairs["2"], [[1, 20]]);
});

for (const kind of ["mal", "anilist"]) {
  for (const [label, change] of [
    ["unchecked", "DELETE FROM catalogue_checked"],
    ["checked but unknown", "DELETE FROM catalogue_known"],
    ["adult", null],
  ]) {
    test(`an event whose ${kind} id is ${label} is not read`, async () => {
      // The control half publishes 1–2, so only the bad id can be what removes 3.
      const DB = makeD1();
      classifyIds(DB, "mal", [1, 2, 3]);
      classifyIds(DB, "anilist", [10, 30]);
      for (let i = 1; i <= 20; i += 1) {
        addInstall(DB, uuid(i), [1, 2], { anilist: 10 });
        addInstall(DB, uuid(i), [3], { anilist: 30 });
      }
      assert.deepEqual((await aggregate(DB)).pairs["1"], [[2, 20], [3, 20]]);
      const id = kind === "mal" ? 3 : 30;
      if (change) DB.sqlite.prepare(`${change} WHERE kind = ? AND id = ?`).run(kind, id);
      else DB.sqlite.prepare("INSERT INTO adult_catalogue (kind, id) VALUES (?, ?)").run(kind, id);
      assert.deepEqual((await aggregate(DB)).pairs, { 1: [[2, 20]], 2: [[1, 20]] });
    });
  }
}

test("catalogue_known follows successful answers; unanswered ids are removed; failed chunks change nothing", async () => {
  const DB = makeD1();
  DB.sqlite.prepare("INSERT INTO events (install, day, received, app, name, mal, attrs) VALUES (?, '2026-11-15', '2026-11-15', 'test', 'work_saved', 1, '{}')").run(uuid(1));
  const response = async () => new Response(JSON.stringify({ data: { Page: { media: [{ id: 101, idMal: 1, isAdult: false, genres: [] }] } } }));
  await runDailyMaintenance({ DB }, { now: NOW, fetchImpl: response });
  assert.equal(DB.rows("SELECT * FROM catalogue_known WHERE kind = 'mal' AND id = 1").length, 1);
  const empty = async () => new Response(JSON.stringify({ data: { Page: { media: [] } } }));
  await runDailyMaintenance({ DB }, { now: new Date("2026-12-20T12:00:00Z"), fetchImpl: empty });
  assert.equal(DB.rows("SELECT * FROM catalogue_known WHERE kind = 'mal' AND id = 1").length, 0);
  DB.sqlite.prepare("INSERT INTO catalogue_known (kind, id) VALUES ('mal', 1)").run();
  const failed = async () => { throw new Error("offline"); };
  await runDailyMaintenance({ DB }, { now: new Date("2027-01-25T12:00:00Z"), fetchImpl: failed });
  assert.equal(DB.rows("SELECT * FROM catalogue_known WHERE kind = 'mal' AND id = 1").length, 1);
});

test("counts round down to five; ranked by count then id; at most 20 per title", async () => {
  const DB = makeD1();
  const others = Array.from({ length: 22 }, (_, i) => i + 2); // 2…23
  classifyIds(DB, "mal", [1, ...others]);
  // 23 is held by 29 installs (→ 25), the rest by 20–24 (→ 20); one title too many for the list.
  for (let i = 1; i <= 29; i += 1) addInstall(DB, uuid(i), i <= 20 ? [1, ...others] : [1, 23]);
  const { pairs } = await aggregate(DB);
  assert.deepEqual(pairs["1"], [[23, 25], ...others.slice(0, 19).map((id) => [id, 20])]);
});

test("keeps the 500 most widely held ids, then the lowest", async () => {
  const DB = makeD1();
  // 251 disjoint pairs of ids, so a neighbour list never fills. 502 ids: 501–502 have more
  // installs and stay; the tie among the rest drops the highest two, 499 and 500.
  const groups = Array.from({ length: 251 }, (_, i) => [2 * i + 1, 2 * i + 2]);
  classifyIds(DB, "mal", groups.flat());
  groups.forEach((ids, g) => {
    const size = g === 250 ? 21 : 20;
    for (let i = 1; i <= size; i += 1) addInstall(DB, uuid(g * 100 + i), ids);
  });
  const { pairs } = await aggregate(DB);
  assert.equal(Object.keys(pairs).length, 500);
  assert.deepEqual(pairs["501"], [[502, 20]]);
  assert.equal(pairs["499"], undefined);
});

test("each install contributes its 100 most widely held ids", async () => {
  const DB = makeD1();
  const held = Array.from({ length: 101 }, (_, i) => i + 1);
  classifyIds(DB, "mal", held);
  for (let i = 1; i <= 20; i += 1) addInstall(DB, uuid(i), held);
  // Everything but id 1 is held more widely, so id 1, the lowest, is the one left out.
  for (let i = 21; i <= 22; i += 1) addInstall(DB, uuid(i), held.slice(1));
  // Many completions of one title use one of the hundred places.
  for (let i = 1; i <= 20; i += 1) addInstall(DB, uuid(i), [50, 50, 50], { name: "chapter_completed" });
  const { pairs } = await aggregate(DB);
  assert.equal(pairs["1"], undefined);
  assert.equal(Object.keys(pairs).length, 100);
});

test("deleted install drops a pair; failed maintenance keeps the prior body", async () => {
  const DB = makeD1();
  classifyIds(DB, "mal", [1, 2]);
  for (let i = 1; i <= 20; i += 1) addInstall(DB, uuid(i), [1, 2]);
  await publish(DB);
  await DB.prepare("DELETE FROM events WHERE install = ?").bind(uuid(1)).run();
  await publish(DB);
  const oldBody = DB.sqlite.prepare("SELECT body FROM published").get().body;
  assert.deepEqual(JSON.parse(oldBody).pairs, {});
  for (let i = 1; i <= 20; i += 1) addInstall(DB, uuid(i + 100), [1, 2]);
  const prepare = DB.prepare;
  for (const failing of ["DELETE FROM events WHERE received", "FROM adult_catalogue WHERE kind", "MATERIALIZED"]) {
    DB.prepare = (sql) => {
      if (sql.includes(failing)) throw new Error("storage");
      return prepare.call(DB, sql);
    };
    await assert.rejects(() => publish(DB));
    DB.prepare = prepare;
    assert.equal(DB.sqlite.prepare("SELECT body FROM published").get().body, oldBody, failing);
  }
  assert.deepEqual((await aggregate(DB)).pairs["1"], [[2, 35]]);
});

test("route serves stored and empty bodies with headers, and rejects other methods", async () => {
  const DB = makeD1();
  const empty = await handleRequest(new Request("https://x/v1/cooccurrence-v1.json"), { DB }, NOW);
  assert.equal(empty.status, 200);
  assert.deepEqual(await empty.json(), { v: 1, k: 20, pairs: {} });
  assert.equal(empty.headers.get("Content-Type"), "application/json");
  assert.equal(empty.headers.get("Cache-Control"), "public, max-age=86400");
  DB.sqlite.prepare("INSERT INTO published (name, body) VALUES ('cooccurrence-v1.json', '{\"v\":1,\"k\":20,\"pairs\":{}}')").run();
  const stored = await handleRequest(new Request("https://x/v1/cooccurrence-v1.json"), { DB }, NOW);
  const storedBody = await stored.text();
  assert.equal(storedBody, '{"v":1,"k":20,"pairs":{}}');
  const wrongMethod = await handleRequest(new Request("https://x/v1/cooccurrence-v1.json", { method: "POST" }), { DB }, NOW);
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get("Allow"), "GET");
  assert.ok(!storedBody.includes(uuid(1)));
});

test("cooccurrence is an accepted closed-set reason", async () => {
  const DB = makeD1();
  const body = { v: 1, events: [{ v: 1, install: uuid(1), day: "2026-11-15", app: "test", name: "for_you_opened", ids: { mal: 1 }, rank: 0, reason: "cooccurrence" }] };
  const response = await handleRequest(new Request("https://x/v1/events", { method: "POST", body: JSON.stringify(body) }), { DB }, NOW);
  assert.equal(response.status, 204);
});

test("twenty unattested installs publish nothing; twenty attested publish a pair", async () => {
  const DB = makeD1();
  classifyIds(DB, "mal", [1, 2]);
  for (let i=1;i<=20;i++) addInstall(DB,uuid(i),[1,2],{attested:0});
  // Attested history cannot make unattested pair rows count.
  for (let i=1;i<=20;i++) addInstall(DB,uuid(i),[],{attested:1, days:["2026-11-08","2026-11-10","2026-11-15"]});
  assert.deepEqual((await aggregate(DB)).pairs,{});
  for (let i=1;i<=20;i++) addInstall(DB,uuid(i),[1,2],{attested:1});
  assert.deepEqual((await aggregate(DB)).pairs,{1:[[2,20]],2:[[1,20]]});
});

test("maturity ignores unattested history even when pair rows are attested", async () => {
  const DB = makeD1();
  classifyIds(DB,"mal",[1,2]);
  for(let i=1;i<=20;i++) {
    addInstall(DB,uuid(i),[],{attested:0});
    addInstall(DB,uuid(i),[1,2],{attested:1,days:[]});
  }
  assert.deepEqual((await aggregate(DB)).pairs,{});
  for(let i=1;i<=20;i++) addInstall(DB,uuid(i),[],{attested:1});
  assert.deepEqual((await aggregate(DB)).pairs,{1:[[2,20]],2:[[1,20]]});
});
