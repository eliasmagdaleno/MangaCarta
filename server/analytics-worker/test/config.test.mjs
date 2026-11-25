import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

const root = new URL("../", import.meta.url);

/** Just enough TOML for wrangler.toml: [tables], [[array tables]], strings, booleans, string arrays. */
function parseTOML(text) {
  const document = {};
  let table = document;
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\s+#.*$/, "").replace(/^#.*$/, "").trim();
    if (line === "") continue;
    let match;
    if ((match = /^\[\[([\w.]+)\]\]$/.exec(line))) {
      document[match[1]] ??= [];
      table = {};
      document[match[1]].push(table);
    } else if ((match = /^\[([\w.]+)\]$/.exec(line))) {
      table = match[1].split(".").reduce((parent, key) => (parent[key] ??= {}), document);
    } else if ((match = /^([\w]+)\s*=\s*(.+)$/.exec(line))) {
      table[match[1]] = JSON.parse(match[2]);
    } else {
      throw new Error(`unparsed wrangler.toml line: ${raw}`);
    }
  }
  return document;
}

test("wrangler.toml has observability off, logpush = false, preview_urls = false", () => {
  const config = parseTOML(readFileSync(new URL("wrangler.toml", root), "utf8"));
  assert.equal(config.name, "mangacarta-analytics");
  assert.equal(config.main, "src/index.js");
  assert.equal(config.workers_dev, true);
  assert.equal(config.preview_urls, false);
  assert.equal(config.logpush, false);
  assert.equal(config.observability.enabled, false);
  assert.equal(config.observability.logs.enabled, false);
  assert.equal(config.observability.logs.invocation_logs, false);
  assert.equal(config.observability.traces.enabled, false);
  assert.deepEqual(config.d1_databases, [
    { binding: "DB", database_name: "mangacarta-analytics", database_id: "REPLACE_WITH_ID_FROM_wrangler_d1_create" },
  ]);
  assert.deepEqual(config.triggers.crons, ["17 3 * * *"]);
  // No `[[tail_consumers]]`: a tail Worker would receive every request's headers.
  assert.equal(config.tail_consumers, undefined);
});

test("the source has no console. call and never reads headers, request.cf or a time of day", () => {
  const files = readdirSync(new URL("src/", root), { recursive: true }).filter((f) => f.endsWith(".js"));
  assert.ok(files.length > 0);
  for (const file of files) {
    const source = readFileSync(new URL(`src/${file}`, root), "utf8");
    assert.ok(!/\bconsole\s*\./.test(source), `${file} calls console`);
    // Comments may name what is never read; the code may not.
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
    assert.ok(!/\.headers\b|\.cf\b|CF-Connecting-IP|X-Forwarded-For|User-Agent/i.test(code), `${file} reads request metadata`);
    assert.ok(!/getUTCHours|getHours|getMinutes|getUTCMinutes|Date\.now\(\)/.test(code), `${file} reads a time of day`);
  }
});
