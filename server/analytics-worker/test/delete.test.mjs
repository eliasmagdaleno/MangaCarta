import assert from "node:assert/strict";
import { test } from "node:test";
import { handleRequest } from "../src/index.js";
import { makeD1 } from "./support/d1.mjs";
import { del, event, INSTALL, NOW, post } from "./support/fixtures.mjs";

const OTHER = "0D4B9C1E-7A2F-4E3B-9C8D-112233445566";

async function seed(DB) {
  const events = [
    event("app_active"),
    event("work_saved", { ids: { mal: 1 } }),
    event("app_active", {}, { install: INSTALL.toLowerCase() }),
    event("app_active", {}, { install: OTHER }),
  ];
  assert.equal((await handleRequest(post({ v: 1, events }), { DB }, NOW)).status, 204);
}

test("DELETE removes every row for the id whatever its case, and keeps other installs", async () => {
  for (const spelling of [INSTALL, INSTALL.toLowerCase(), "5f0C2a9E-1b3D-4c5E-8f70-9A1b2C3d4E5f"]) {
    const DB = makeD1();
    await seed(DB);
    const response = await handleRequest(del(spelling), { DB }, NOW);
    assert.equal(response.status, 204);
    assert.equal(await response.text(), "");
    const rows = DB.rows();
    assert.equal(rows.length, 1, spelling);
    assert.equal(rows[0].install, OTHER.toLowerCase());
  }
});

test("DELETE returns 204 for an unknown id, the same as for a known one", async () => {
  const DB = makeD1();
  await seed(DB);
  const response = await handleRequest(del("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"), { DB }, NOW);
  assert.equal(response.status, 204);
  assert.equal(DB.rows().length, 4);
});

test("DELETE with a malformed id is 400 and deletes nothing", async () => {
  const DB = makeD1();
  await seed(DB);
  for (const id of ["not-a-uuid", INSTALL.replaceAll("-", ""), `${INSTALL}0`, "%27%20OR%201%3D1", "*"]) {
    assert.equal((await handleRequest(del(id), { DB }, NOW)).status, 400, id);
  }
  assert.equal(DB.rows().length, 4);
});
