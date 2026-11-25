import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { mock, test } from "node:test";
import { handleRequest, runDailyMaintenance } from "../src/index.js";
import { decodeCBOR } from "../src/cbor.js";
import { base64, unbase64, utf8, concat, equal, sha256, verifyAttestation } from "../src/appattest.js";
import { sample, cbor, options, extensionMap, assertionFor, signingKey } from "./support/appattest.mjs";
import { makeD1 } from "./support/d1.mjs";
import { event, INSTALL, post, del } from "./support/fixtures.mjs";

const now = new Date(sample.validAt);
const other = "00000000-0000-4000-8000-000000000002";
const envFor = (DB) => ({DB, APP_ATTEST_APP_ID:sample.appID});
const events = (install = INSTALL) => JSON.stringify({v:1,events:[event("app_active",{}, {install,day:"2026-04-21"})]});
function bodyOnly(request) {
  return new Proxy(request, {get(target,prop) {
    if (prop === "headers" || prop === "cf") throw new Error("metadata read");
    const v = Reflect.get(target,prop,target); return typeof v === "function" ? v.bind(target) : v;
  }});
}
async function call(DB, path, value, at = now, env = envFor(DB)) {
  return handleRequest(bodyOnly(post(value,{path})),env,at);
}
async function issue(DB, install = INSTALL, at = now) {
  const response = await call(DB,"/v1/challenges",{install},at);
  assert.equal(response.status,200);
  return (await response.json()).challenge;
}
async function seedKey(DB, install = INSTALL, counter = 0) {
  const key = await signingKey();
  key.id = base64(await sha256(unbase64(key.publicKey)));
  DB.sqlite.prepare("INSERT INTO attested_keys VALUES (?, ?, ?, ?, ?)").run(install.toLowerCase(),key.id,key.publicKey,counter,"2026-04-21");
  return key;
}
async function wrapper(key, {body = events(), counter = 1, ...changes} = {}) {
  return {v:2,install:INSTALL,key:key.id,assertion:base64(await assertionFor(key,body,{counter,...changes})),body};
}

// Apple cannot sign our test challenges. This narrowly scoped hash oracle adapts only
// the sample's signed nonce to the exact challenge||install binding expected by this
// endpoint test. Chain signatures remain real; the unmodified sample is verified
// separately without mocks. Generated assertions and the device-capture test use no oracle.
async function sampleForIssuedChallenge(DB, challenge, fn, install = INSTALL) {
  const obj = decodeCBOR(options().attestation).value, auth = obj.get("authData");
  const at = decodeCBOR(auth,{offset:87,trailing:true}).offset;
  const modified = concat(auth.slice(0,at),cbor(extensionMap(3)));
  obj.set("authData",modified);
  const expectedInput = concat(modified,await sha256(concat(unbase64(challenge),utf8(install.toLowerCase()))));
  const realDigest = crypto.subtle.digest.bind(crypto.subtle);
  const mocked = mock.method(crypto.subtle,"digest",async (alg,input) => {
    if (alg === "SHA-256" && equal(new Uint8Array(input),expectedInput)) return unbase64(sample.expected.nonce).buffer;
    return realDigest(alg,input);
  });
  const value = {install,key:sample.keyId,attestation:base64(cbor(obj))};
  try { return await fn(value); } finally { mocked.mock.restore(); }
}

test("challenges are 32 random bytes, lower-case scoped, and new challenges replace old", async () => {
  const DB = makeD1(), first = await issue(DB), second = await issue(DB);
  assert.equal(unbase64(first).length,32); assert.equal(unbase64(second).length,32);
  assert.notEqual(first,second);
  assert.deepEqual(DB.rows("SELECT * FROM challenges"),[{install:INSTALL.toLowerCase(),challenge:second,expires:Math.floor(+now/1000)+600}]);
  await sampleForIssuedChallenge(DB,first, async (value) => assert.equal((await call(DB,"/v1/attestations",value)).status,400));
});
test("challenge and attestation routes are 404 when App ID is absent and 405 for wrong methods", async () => {
  const DB = makeD1();
  for (const path of ["/v1/challenges","/v1/attestations"]) {
    assert.equal((await call(DB,path,{},now,{DB})).status,404);
    assert.equal((await handleRequest(new Request(`https://x${path}`),envFor(DB),now)).status,405);
  }
});
test("attestation stores a key and consumes the challenge once", async () => {
  const DB = makeD1(), challenge = await issue(DB);
  await sampleForIssuedChallenge(DB,challenge,async (value) => {
    assert.equal((await call(DB,"/v1/attestations",value)).status,204);
    const [key] = DB.rows("SELECT * FROM attested_keys");
    assert.equal(key.install,INSTALL.toLowerCase()); assert.equal(key.key_id,sample.keyId);
    assert.equal(key.counter,0); assert.equal(key.last_used,"2026-04-21");
    assert.equal(base64(await sha256(unbase64(key.public_key))),sample.keyId);
    assert.equal(DB.rows("SELECT * FROM challenges").length,0);
    assert.equal((await call(DB,"/v1/attestations",value)).status,400);
  });
});
test("challenge expires exactly after ten minutes", async () => {
  const DB = makeD1(), challenge = await issue(DB);
  await sampleForIssuedChallenge(DB,challenge,async (value) => {
    assert.equal((await call(DB,"/v1/attestations",value,new Date(+now+600000))).status,400);
    assert.equal(DB.rows("SELECT * FROM attested_keys").length,0);
  });
});
test("challenge is bound to the lower-case install in clientDataHash", async () => {
  const DB = makeD1(), challenge = await issue(DB);
  // Same challenge moved to another install: lookup succeeds but cryptographic binding fails.
  DB.sqlite.prepare("INSERT INTO challenges SELECT ?,challenge,expires FROM challenges").run(other);
  await sampleForIssuedChallenge(DB,challenge,async (value) => {
    assert.equal((await call(DB,"/v1/attestations",{...value,install:other})).status,400);
    assert.equal(DB.rows("SELECT * FROM attested_keys").length,0);
  });
});
test("wrong install with no issued challenge is refused", async () => {
  const DB = makeD1(), challenge = await issue(DB);
  await sampleForIssuedChallenge(DB,challenge,async (value) => {
    assert.equal((await call(DB,"/v1/attestations",{...value,install:other})).status,400);
  });
});
test("a key cannot belong to two installs; re-attestation replaces a key and resets its counter", async () => {
  const DB = makeD1();
  await seedKey(DB);
  const challenge = await issue(DB);
  await sampleForIssuedChallenge(DB,challenge,async (value) => assert.equal((await call(DB,"/v1/attestations",value)).status,204));
  DB.sqlite.prepare("UPDATE attested_keys SET counter=9").run();
  const replacement = await issue(DB);
  await sampleForIssuedChallenge(DB,replacement,async (value) => assert.equal((await call(DB,"/v1/attestations",value)).status,204));
  assert.equal(DB.rows("SELECT * FROM attested_keys")[0].counter,0);
  const another = await issue(DB,other);
  await sampleForIssuedChallenge(DB,another,async (value) => assert.equal((await call(DB,"/v1/attestations",value)).status,400),other);
  assert.equal(DB.rows("SELECT * FROM attested_keys").length,1);
});
test("well-formed but unverified attestations are 400 and never store keys", async () => {
  const DB = makeD1(); await issue(DB);
  assert.equal((await call(DB,"/v1/attestations",{install:INSTALL,key:sample.keyId,attestation:sample.attestation})).status,400);
  assert.deepEqual(DB.rows("SELECT * FROM attested_keys"),[]);
});

test("v2 accepts a valid assertion with attested=1, updates counter and last_used", async () => {
  const DB = makeD1(), key = await seedKey(DB);
  const signed = await wrapper(key);
  assert.equal((await call(DB,"/v1/events",signed)).status,204);
  assert.equal(DB.rows()[0].attested,1);
  assert.equal(DB.rows("SELECT counter FROM attested_keys")[0].counter,1);
  assert.equal((await call(DB,"/v1/events",await wrapper(key,{counter:2}),new Date("2026-04-22"))).status,204);
  assert.equal(DB.rows("SELECT last_used FROM attested_keys")[0].last_used,"2026-04-22");
});
for (const [name, edit] of [
  ["unknown key",async (v) => { v.key=base64(new Uint8Array(32)); }],
  ["bad signature",async (v) => { const o=decodeCBOR(unbase64(v.assertion)).value; o.get("signature")[10]^=1; v.assertion=base64(cbor(o)); }],
  ["equal counter",async (v,k) => { Object.assign(v,await wrapper(k,{counter:2})); }],
  ["lower counter",async (v,k) => { Object.assign(v,await wrapper(k,{counter:1})); }],
  ["wrong RP",async (v,k) => { Object.assign(v,await wrapper(k,{counter:3,rp:new Uint8Array(32)})); }],
  ["category",async (v,k) => { Object.assign(v,await wrapper(k,{counter:3,extensions:extensionMap(1)})); }],
  ["other install event",async (v,k) => { Object.assign(v,await wrapper(k,{counter:3,body:events(other)})); }],
  ["body not signed bytes",async (v) => { v.body += " "; }],
]) test(`v2 refuses ${name} with 409 and writes nothing`, async () => {
  const DB=makeD1(),key=await seedKey(DB,INSTALL,2),v=await wrapper(key,{counter:3});
  await edit(v,key);
  assert.equal((await call(DB,"/v1/events",v)).status,409);
  assert.deepEqual(DB.rows(),[]); assert.equal(DB.rows("SELECT counter FROM attested_keys")[0].counter,2);
});
test("v2 is 409 without configured App ID", async () => {
  const DB=makeD1(),key=await seedKey(DB);
  assert.equal((await call(DB,"/v1/events",await wrapper(key),now,{DB})).status,409);
  assert.deepEqual(DB.rows(),[]);
});
test("two concurrent replays store exactly one batch (database trigger, not read-then-write)", async () => {
  const DB=makeD1(),key=await seedKey(DB),v=await wrapper(key);
  const original=DB.prepare; let reads=0,release;
  const barrier=new Promise((r)=>{release=r;});
  DB.prepare=(sql)=>{
    const stmt=original.call(DB,sql);
    if (!sql.startsWith("SELECT public_key")) return stmt;
    const bind=stmt.bind.bind(stmt);
    stmt.bind=(...args)=>{
      const bound=bind(...args),first=bound.first.bind(bound);
      bound.first=async()=>{ const result=await first(); if (++reads===2) release(); await barrier; return result; };
      return bound;
    };
    return stmt;
  };
  const responses=await Promise.all([call(DB,"/v1/events",v),call(DB,"/v1/events",v)]);
  assert.deepEqual(responses.map((r)=>r.status).sort(),[204,409]); assert.equal(DB.rows().length,1);
});
test("counter update is first; failed insert rolls counter back", async () => {
  const DB=makeD1(),key=await seedKey(DB),batch=DB.batch.bind(DB);
  DB.batch=async(statements)=>{
    assert.match(statements[0].sql,/^UPDATE attested_keys/);
    return batch([...statements,DB.prepare("INSERT INTO missing_table VALUES (1)")]);
  };
  assert.equal((await call(DB,"/v1/events",await wrapper(key))).status,500);
  assert.equal(DB.rows("SELECT counter FROM attested_keys")[0].counter,0); assert.deepEqual(DB.rows(),[]);
});
test("deletion or key replacement during verification cannot store an unsigned batch", async () => {
  for (const replace of [false,true]) {
    const DB=makeD1(),key=await seedKey(DB),batch=DB.batch.bind(DB);
    DB.batch=async(statements)=>{
      DB.sqlite.prepare("DELETE FROM attested_keys").run();
      if(replace) DB.sqlite.prepare("INSERT INTO attested_keys VALUES (?,?,?,?,?)").run(INSTALL.toLowerCase(),"replacement",key.publicKey,1,"2026-04-21");
      return batch(statements);
    };
    assert.equal((await call(DB,"/v1/events",await wrapper(key))).status,409); assert.deepEqual(DB.rows(),[]);
  }
});
test("trigger rejects equal and lower counter updates and schema can run twice", async () => {
  const DB=makeD1(); await seedKey(DB,INSTALL,2);
  DB.sqlite.exec(readFileSync(new URL("../schema.sql",import.meta.url),"utf8"));
  for(const n of [1,2]) assert.throws(()=>DB.sqlite.prepare("UPDATE attested_keys SET counter=?").run(n),/attestation counter must rise/);
});
test("v1 is still accepted with attested=0", async () => {
  const DB=makeD1(); assert.equal((await call(DB,"/v1/events",events())).status,204);
  assert.equal(DB.rows()[0].attested,0);
});
test("128KB request cap and decoded 64KB body cap are independent", async () => {
  const DB=makeD1(),key=await seedKey(DB),v=await wrapper(key);
  // Whitespace is valid JSON and signed, and escaped whitespace increases wrapper size.
  const bigBody=events()+"\n".repeat(1000)+" ".repeat(64536-utf8(events()).length);
  assert.equal((await call(DB,"/v1/events",await wrapper(key,{body:bigBody}))).status,204);
  const oversized=await wrapper(key,{body:bigBody+" ",counter:2});
  assert.equal((await call(DB,"/v1/events",oversized)).status,400);
  assert.equal((await call(DB,"/v1/events",JSON.stringify(v)+" ".repeat(131072))).status,400);
  assert.equal(DB.rows().length,1);
});
for(const [name,change] of [
  ["invalid install",(v)=>v.install="bad"], ["noncanonical key",(v)=>v.key="AAAA"],
  ["bad base64",(v)=>v.assertion="--__"], ["oversized assertion",(v)=>v.assertion=base64(new Uint8Array(1025))],
  ["body object",(v)=>v.body={}], ["unknown field",(v)=>v.extra=1],
  ["invalid body",(v)=>v.body="{}"],
]) test(`malformed v2 ${name} is 400`,async()=>{
  const DB=makeD1(),key=await seedKey(DB),v=await wrapper(key); change(v);
  assert.equal((await call(DB,"/v1/events",v)).status,400); assert.deepEqual(DB.rows(),[]);
});
test("DELETE erases keys and challenges together with events, regardless of case", async () => {
  const DB=makeD1(); await seedKey(DB); await seedKey(DB,other); await issue(DB); await issue(DB,other);
  await call(DB,"/v1/events",events());
  assert.equal((await handleRequest(del(INSTALL),envFor(DB),now)).status,204);
  assert.deepEqual(DB.rows(),[]);
  assert.deepEqual(DB.rows("SELECT install FROM attested_keys"),[{install:other}]);
  assert.deepEqual(DB.rows("SELECT install FROM challenges"),[{install:other}]);
});
test("nightly maintenance purges expired challenges and keys idle over twelve months",async()=>{
  const DB=makeD1(); await seedKey(DB); await seedKey(DB,other);
  DB.sqlite.prepare("UPDATE attested_keys SET last_used=? WHERE install=?").run("2025-04-20",INSTALL.toLowerCase());
  DB.sqlite.prepare("UPDATE attested_keys SET last_used=? WHERE install=?").run("2025-04-21",other);
  await issue(DB); await issue(DB,other,new Date(+now+1e6));
  await runDailyMaintenance(envFor(DB),{now:new Date(+now+600000),fetchImpl:async()=>{throw new Error("unexpected fetch");}});
  assert.deepEqual(DB.rows("SELECT install FROM attested_keys"),[{install:other}]);
  assert.deepEqual(DB.rows("SELECT install FROM challenges"),[{install:other}]);
});

const captureURL=new URL("./fixtures/device-capture.json",import.meta.url);
test("owner device capture: attestation and both assertions through production endpoints",{skip:!existsSync(captureURL)},async()=>{
  const f=JSON.parse(readFileSync(captureURL)),DB=makeD1(),at=new Date(f.capturedAt);
  assert.equal(f.appID,"V2BG9SHQYS.Elias-Magdaleno.Manga-Reader");
  const env={DB,APP_ATTEST_APP_ID:f.appID};
  const result=await verifyAttestation({attestation:unbase64(f.attestation),keyId:f.key,
    clientDataHash:await sha256(concat(Uint8Array.from(Buffer.from(f.challengeHex,"hex")),utf8(f.install.toLowerCase()))),appID:env.APP_ATTEST_APP_ID,now:at});
  assert.equal(result.bundleVersion,f.bundleVersion);
  DB.sqlite.prepare("INSERT INTO challenges VALUES (?,?,?)").run(f.install.toLowerCase(),base64(Uint8Array.from(Buffer.from(f.challengeHex,"hex"))),Math.floor(+at/1000)+600);
  assert.equal((await call(DB,"/v1/attestations",{install:f.install,key:f.key,attestation:f.attestation},at,env)).status,204);
  for(let i=0;i<2;i++) assert.equal((await call(DB,"/v1/events",{v:2,install:f.install,key:f.key,assertion:f.assertions[i],body:f.bodies[i]},at,env)).status,204);
  assert.ok(DB.rows().every((r)=>r.attested===1));
});
