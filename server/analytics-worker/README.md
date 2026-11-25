# MangaCarta analytics Worker

The server half of opt-in analytics: one Cloudflare Worker and one D1 database. It accepts batches of the
events in the analytics design (`docs/superpowers/specs/2026-11-09-analytics-design.md`, §2 and Amendments 3–5),
deletes one install's events on request, runs a daily purge, and publishes anonymous co-occurrence counts. It reads only the request body: no IP
address, user agent or header is read or stored. Events store UTC days only; short-lived App Attest
challenges alone store an expiry to the second.

| File | What it is |
|---|---|
| `src/index.js` | The Worker: ingest and delete endpoints, `GET /v1/cooccurrence-v1.json`, and daily maintenance |
| `src/appattest.js`, `src/cbor.js`, `src/der.js` | App Attest verification, pinned Apple root, and bounded parsers; WebCrypto only |
| `schema.sql` | Event, catalogue, publication, key and challenge tables, plus the replay trigger. Safe to run again |
| `wrangler.toml` | Deploy config. Every logging switch is off; each line says why |
| `test/` | `node --test` tests over a D1 stand-in built on `node:sqlite` |

Every command below uses **wrangler 4.162.0**, pinned so these steps keep meaning the same thing. Run them
from this directory (`server/analytics-worker/`).

## Recommendation table

Daily maintenance publishes distinct-install, k ≥ 20 MAL co-occurrence counts from attested saved and completed Works at `GET /v1/cooccurrence-v1.json`. Maturity (three received days spanning seven days) also counts only attested events. After changing the Worker or schema, re-run setup steps **6 (schema)** and **7 (deploy)**.

## App Attest endpoints

Enable the App ID's App Attest capability in the Apple developer account and confirm its prefix before
device capture or deployment. `[vars].APP_ATTEST_APP_ID` in `wrangler.toml` is
`V2BG9SHQYS.Elias-Magdaleno.Manga-Reader`. Without it, challenge/attestation routes return 404 and v2 returns 409.

| Request | Result |
|---|---|
| `POST /v1/challenges {"install":"<UUID>"}` | 200 `{"challenge":"<standard base64>"}`; 32 random bytes, once only, ten minutes; replaces an older challenge |
| `POST /v1/attestations {"install":"<UUID>","key":"<base64>","attestation":"<base64>"}` | 204 after verification; 400 on failure; replaces this install's key and resets its counter; a key cannot belong to two installs |
| `POST /v1/events {"v":2,"install":"<UUID>","key":"<base64>","assertion":"<base64>","body":"<v1 JSON string>"}` | 204 with `attested=1`; 409 for a failed assertion, with no events stored; malformed requests are 400 |
| Existing v1 event batches | Still 204 with `attested=0`; still count for feature analytics |
| `DELETE /v1/installs/<UUID>` | 204, deleting events, key and outstanding challenge together |

Attestation binds `SHA256(challenge bytes || lower-case install UTF-8)`. Assertions sign the exact
decoded `body` bytes; all events must match the wrapper's install. The request cap is 128 KB, the body
cap remains 64 KB, keys are 32 bytes, attestations at most 16 KB, assertions at most 1 KB (decoded).
A failed assertion tells the app to discard its key and resend v1; a storage failure remains 500 for retry.
The counter update and inserts share a transaction; the database trigger rejects concurrent replays.
Nightly maintenance removes expired challenges and keys unused for over twelve calendar months.
Receipts are neither verified nor stored, per the approved design's fraud-metric omission.

## Owner setup checklist

Do these in order. Steps 1–7 need nothing from the app; step 10 is the only one that touches it.

1. **Create a Cloudflare account** at <https://dash.cloudflare.com/sign-up>. The free plan is enough
   (Workers: 100,000 requests a day; D1: 100,000 rows written a day, 5 GB).

2. **Log in from this machine.** This opens a browser window and stores a token locally:

   ```sh
   npx wrangler@4.162.0 login
   ```

3. **Choose where the database lives.** This is fixed at creation and cannot be changed later without
   making a new database. Pick one:

   - `--location weur|eeur|wnam|enam|apac|oc` — a *location hint* (Western Europe, Eastern Europe, Western
     North America, Eastern North America, Asia-Pacific, Oceania). D1 places the primary copy near there,
     but a hint is not a legal guarantee.
   - `--jurisdiction eu` — a *jurisdiction*: the data is stored and processed inside the EU, guaranteed.
     This is the stronger promise to make to European readers.

   **Write your choice down and report it back** — the privacy policy's "Where it goes" names the location
   (`docs/app-store/privacy-policy.md`, currently `[D1 REGION]`).

4. **Create the database**, with the flag you chose in step 3 (here, the EU jurisdiction):

   ```sh
   npx wrangler@4.162.0 d1 create mangacarta-analytics --jurisdiction eu
   ```

   or, for a location hint instead:

   ```sh
   npx wrangler@4.162.0 d1 create mangacarta-analytics --location weur
   ```

5. **Paste the id.** The output of step 4 prints a `database_id = "…"`. Put it in `wrangler.toml` in place of
   `REPLACE_WITH_ID_FROM_wrangler_d1_create`. The id is not a secret, but it is per-account, so don't commit it
   unless you mean to.

6. **Create the tables:**

   ```sh
   npx wrangler@4.162.0 d1 execute mangacarta-analytics --remote --file schema.sql
   ```

7. **Deploy:**

   ```sh
   npx wrangler@4.162.0 deploy
   ```

   The output prints the Worker's URL, `https://mangacarta-analytics.<your-subdomain>.workers.dev`. The part
   after `https://` is the **host** used in steps 9–11.

8. **Confirm in the dashboard that every kind of logging is OFF.** `wrangler.toml` turns these off, but the
   dashboard is the source of truth, and some of them are account-level and can't be set from the file.
   **Until every box below is confirmed, the privacy policy's "Your IP address is not stored" is false** —
   Cloudflare's own logs would hold each reader's IP address and user agent.

   - [ ] **Workers Logs / observability.** Workers & Pages › `mangacarta-analytics` › Settings ›
         Observability: **Workers Logs** disabled (no invocation logs) and **Traces** disabled.
   - [ ] **Logpush.** Account home › Analytics & Logs › Logpush: **no job** exists for Workers — in particular
         none with the dataset **Workers Trace Events**, which is the per-request Worker log.
   - [ ] **Workers Trace Events** are not pushed anywhere else either (the same Logpush page, every dataset).
   - [ ] **No live tail.** Workers & Pages › `mangacarta-analytics` › Logs: no live log stream is open, and no
         `wrangler tail` session is running on any machine. (A tail only exists while it is open; never leave
         one running.)
   - [ ] **Preview URLs off.** Workers & Pages › `mangacarta-analytics` › Settings › Domains & Routes:
         **Preview URLs** disabled. (`preview_urls = false` in `wrangler.toml`; confirm it took.)

9. **Smoke test.** Replace `HOST` with the host from step 7. This sends one event, deletes it, and checks the
   table is empty again (on a fresh database the count is 0):

   ```sh
   HOST=mangacarta-analytics.your-subdomain.workers.dev
   ID=$(uuidgen)
   DAY=$(date -u +%F)

   # Expect: 204
   curl -s -o /dev/null -w '%{http_code}\n' -X POST "https://$HOST/v1/events" \
     -H 'Content-Type: application/json' \
     --data "{\"v\":1,\"events\":[{\"v\":1,\"install\":\"$ID\",\"day\":\"$DAY\",\"app\":\"smoke\",\"name\":\"app_active\"}]}"

   # Expect: 204
   curl -s -o /dev/null -w '%{http_code}\n' -X DELETE "https://$HOST/v1/installs/$ID"

   # Expect: COUNT(*) = 0
   npx wrangler@4.162.0 d1 execute mangacarta-analytics --remote --command "SELECT COUNT(*) FROM events"
   ```

   Anything other than 204 from the POST means the event was rejected (400) or storage failed (500); the
   Worker gives no further detail, by design.

10. **Point the app at it.** On the machine that archives App Store builds, add one line to the repository's
    `Secrets.xcconfig` (gitignored, at the repository root):

    ```
    ANALYTICS_HOST = mangacarta-analytics.your-subdomain.workers.dev
    ```

    **The host only — no `https://`.** An `.xcconfig` file treats `//` as the start of a comment, so
    `ANALYTICS_HOST = https://host` silently becomes `https:`. The app adds `https://` and the `/v1/…` paths
    itself, so it can never send over plain HTTP. Debug builds still send nothing unless launched with
    `-analytics-debug-uploads`.

11. **Report back** the host (step 7) and the D1 location or jurisdiction (step 3). The privacy policy's
    "Where it goes" and its effective date are updated with them; until then the policy is not ready to
    publish.

## Routine tasks

### Mark a title as adult by hand

The daily cron classifies ids through AniList, but you can list one yourself (`kind` is `mal` or `anilist`).
Its events are purged at the next cron run (03:17 UTC); run the second command to purge them now.

```sh
npx wrangler@4.162.0 d1 execute mangacarta-analytics --remote \
  --command "INSERT OR IGNORE INTO adult_catalogue (kind, id) VALUES ('mal', 12345)"

npx wrangler@4.162.0 d1 execute mangacarta-analytics --remote \
  --command "DELETE FROM events WHERE mal IN (SELECT id FROM adult_catalogue WHERE kind = 'mal') OR to_mal IN (SELECT id FROM adult_catalogue WHERE kind = 'mal') OR anilist IN (SELECT id FROM adult_catalogue WHERE kind = 'anilist') OR to_anilist IN (SELECT id FROM adult_catalogue WHERE kind = 'anilist')"
```

### Answer an emailed access or deletion request

The reader quotes the analytics id shown in Settings › Privacy. Ids are stored lower-case; `lower()` makes
the case they send irrelevant.

Access (send them the output; `--json` gives a file-friendly form):

```sh
npx wrangler@4.162.0 d1 execute mangacarta-analytics --remote --json \
  --command "SELECT day, received, app, name, mal, anilist, to_mal, to_anilist, attrs FROM events WHERE install = lower('<id>') ORDER BY id"
```

Deletion:

```sh
npx wrangler@4.162.0 d1 execute mangacarta-analytics --remote \
  --command "DELETE FROM events WHERE install = lower('<id>'); DELETE FROM attested_keys WHERE install = lower('<id>'); DELETE FROM challenges WHERE install = lower('<id>');"
```

Check the id looks like a UUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) before pasting it into a command.

### After changing the Worker

Re-run step 6 (the schema is idempotent) if `schema.sql` changed, then step 7. Re-check step 8 after any
change to `wrangler.toml`.

## Running the tests

Needs Node 22.13 or later (for `node:sqlite`); developed on Node 26. There are no dependencies to install.

```sh
cd server/analytics-worker
npm test
```

The tests run the Worker's handlers directly against an in-memory SQLite database standing in for D1, with a
fake AniList — nothing touches the network or Cloudflare. CI does not run them yet.

Apple's recorded sample verifies without mocks at its recorded validity time, with category 1 explicitly
enabled only in that test. Endpoint attestation tests use a narrowly scoped nonce hash stand-in to adapt
that sample to issued challenges; assertion tests generate P-256 keys. These do not establish Apple's real
assertion format. The optional `test/fixtures/device-capture.json` test verifies the owner's attestation and
two assertions without mocks when the capture exists; until then it is skipped. No capture is fabricated.
Run `node scripts/mutate-appattest.mjs <report.md>` to repeat the App Attest mutation audit.
