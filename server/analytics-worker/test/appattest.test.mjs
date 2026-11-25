import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeCBOR } from "../src/cbor.js";
import { decodeDER, derSignature } from "../src/der.js";
import { verifyAttestation, verifyAssertion, APPLE_ROOT_BASE64, unbase64, base64, sha256, concat, utf8 } from "../src/appattest.js";
import { sample, options, cbor, encodeDER, der, signingKey, assertionFor, extensionMap } from "./support/appattest.mjs";

test("pinned Apple root has the independently specified SHA256 fingerprint", async () => {
  assert.equal(Buffer.from(await sha256(unbase64(APPLE_ROOT_BASE64))).toString("hex"), "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932");
});
test("Apple sample attestation verifies including its real P384/SHA256 leaf signature", async () => {
  const result = await verifyAttestation(options());
  assert.equal(result.counter, 0);
  assert.equal(result.bundleVersion, "1");
  assert.equal(base64(await sha256(unbase64(result.publicKey))), sample.keyId);
});

// Fail on the particular check, so rejection by a different check cannot mask its removal.
const cases = [
  ["x5c order", "chain issuer", (o) => o.get("attStmt").get("x5c").reverse()],
  ["x5c cardinality", "x5c length", (o) => o.get("attStmt").get("x5c").pop()],
  ["foreign root", "chain issuer", (o) => {
    const chain = o.get("attStmt").get("x5c");
    // A self-issued foreign trust anchor is never accepted as the intermediate.
    const cert = decodeDER(unbase64(APPLE_ROOT_BASE64));
    cert.children[0].children[5].children[0].children[0].children[1].value[0] ^= 1;
    chain[1] = encodeDER(cert);
  }],
  ["broken leaf signature", "leaf signature", (o) => { const x = o.get("attStmt").get("x5c")[0]; x[x.length-1] ^= 1; }],
  ["broken intermediate signature", "intermediate signature", (o) => { const x = o.get("attStmt").get("x5c")[1]; x[x.length-1] ^= 1; }],
  ["intermediate without CA", "chain CA constraints", (o) => editCert(o, 1, (t) => {
    const ext = t.children[0].children[7].children[0].children.find((e) => Buffer.from(e.children[0].value).toString("hex") === "551d13");
    ext.children.at(-1).value = der(48, new Uint8Array());
  })],
  ["leaf is CA", "chain CA constraints", (o) => editCert(o, 0, (t) => {
    const ext = t.children[0].children[7].children[0].children.find((e) => Buffer.from(e.children[0].value).toString("hex") === "551d13");
    ext.children.at(-1).value = der(48, Uint8Array.of(1,1,255));
  })],
  ["nonce OID value", "attestation nonce", (o) => editCert(o, 0, (t) => {
    const ext = t.children[0].children[7].children[0].children.find((e) => Buffer.from(e.children[0].value).toString("hex") === "2a864886f763640802");
    ext.children.at(-1).value[ext.children.at(-1).value.length-1] ^= 1;
  })],
  ["credentialId differs", "credential ID", (o) => { o.get("authData")[55] ^= 1; }],
  ["RP ID hash", "RP ID", (o) => { o.get("authData")[0] ^= 1; }],
  ["nonzero attestation counter", "attestation counter", (o) => { o.get("authData")[36] = 1; }],
  ["development AAGUID", "production AAGUID", (o) => { o.get("authData").set(utf8("appattestdevelop"),37); }],
  ["COSE differs from certificate", "COSE key", (o) => { o.get("authData")[100] ^= 1; }],
  ["category 5", "validation category", (o) => changeExtensions(o, (m) => m.get("apple_validation_category_01")[0] = 5)],
  ["missing category", "validation category", (o) => changeExtensions(o, (m) => m.delete("apple_validation_category_01"))],
  ["integer category", "validation category", (o) => changeExtensions(o, (m) => m.set("apple_validation_category_01",1))],
  ["big endian category", "validation category", (o) => changeExtensions(o, (m) => m.set("apple_validation_category_01",Uint8Array.of(0,0,0,1)))],
  ["missing extensions", "CBOR bounds", (o) => { o.set("authData",o.get("authData").slice(0, extOffset(o))); }],
  ["malformed extensions", "extensions map", (o) => { o.set("authData",concat(o.get("authData").slice(0,extOffset(o)),cbor([]))); }],
  ["trailing auth bytes", "CBOR trailing bytes", (o) => { o.set("authData",concat(o.get("authData"),Uint8Array.of(0))); }],
];
function editCert(o, i, edit) {
  const chain = o.get("attStmt").get("x5c"), cert = decodeDER(chain[i]);
  edit(cert); chain[i] = encodeDER(cert);
}
function extOffset(o) { return decodeCBOR(o.get("authData"),{offset:87,trailing:true}).offset; }
function changeExtensions(o, edit) {
  const auth = o.get("authData"), at = extOffset(o), ext = decodeCBOR(auth,{offset:at}).value;
  edit(ext); o.set("authData",concat(auth.slice(0,at),cbor(ext)));
}
for (const [name, error, edit] of cases) test(`attestation refuses ${name}`, async () => {
  const opts = options(), obj = decodeCBOR(opts.attestation).value;
  edit(obj); opts.attestation = cbor(obj);
  await assert.rejects(verifyAttestation(opts), {message:error});
});
test("attestation refuses category 1 by default", async () => {
  const opts = options(); delete opts.categories;
  await assert.rejects(verifyAttestation(opts), {message:"validation category"});
});
test("attestation refuses a leaf outside validity", async () => {
  await assert.rejects(verifyAttestation({...options(),now:new Date("2026-04-24")}), {message:"chain validity"});
});
test("attestation refuses keyId unequal to SHA256(public key)", async () => {
  await assert.rejects(verifyAttestation({...options(),keyId:new Uint8Array(32)}), {message:"key ID hash"});
});
for (const version of ["", "a".repeat(33), "\n", "é"]) test(`attestation refuses bundle version ${JSON.stringify(version)}`, async () => {
  const opts = options(), obj = decodeCBOR(opts.attestation).value;
  changeExtensions(obj, (m) => m.set("apple_bundle_version_01",version));
  await assert.rejects(verifyAttestation({...opts,attestation:cbor(obj)}), {message:"bundle version"});
});

for (const [name, bytes] of [
  ["empty",[]], ["truncated length",[88]], ["length past end",[67,1,2]], ["indefinite",[159,255]],
  ["duplicate text key",[162,97,97,1,97,97,2]], ["duplicate integer key",[162,1,1,1,2]],
  ["nonminimal length",[88,1,0]], ["trailing bytes",[0,0]], ["depth",[...Array(18).fill(129),0]],
]) test(`CBOR refuses ${name}`, () => assert.throws(() => decodeCBOR(Uint8Array.from(bytes))));
for (const [name, bytes] of [
  ["empty",[]], ["truncated",[48]], ["length past end",[4,2,0]], ["indefinite",[48,128,0,0]],
  ["nonminimal length",[4,129,1,0]], ["leading zero length",[4,130,0,128,...Array(128).fill(0)]],
  ["trailing bytes",[48,0,0]], ["negative padding",[2,2,255,255]],
  ["depth",Array.from({length:18}).reduce((v) => [...der(48,Uint8Array.from(v))],[5,0])],
]) test(`DER refuses ${name}`, () => assert.throws(() => decodeDER(Uint8Array.from(bytes))));
test("DER signature refuses negative and oversized scalars", () => {
  assert.throws(() => derSignature(der(48,concat(der(2,Uint8Array.of(128)),der(2,Uint8Array.of(1)))),32));
  assert.throws(() => derSignature(der(48,concat(der(2,Uint8Array.from({length:34},()=>1)),der(2,Uint8Array.of(1)))),32));
});
test("DER checks content bounds before returning a truncated primitive", () => {
  assert.throws(() => decodeDER(Uint8Array.of(4,2,0)),{message:"DER length bounds"});
});
test("CBOR rejects negative or past-end offsets", () => {
  for(const offset of [-1,2,0.5]) assert.throws(()=>decodeCBOR(Uint8Array.of(0),{offset}));
});

test("generated assertion verifies ECDSA P256/SHA256 over nonce and returns counter", async () => {
  const key = await signingKey(), body = "exact body bytes";
  const assertion = await assertionFor(key,body);
  assert.equal((await verifyAssertion({assertion,clientData:utf8(body),publicKey:key.publicKey,counter:0,appID:sample.appID})).counter,1);
});
for(const category of [2,3,4]) test(`assertion accepts launch category ${category} and a 32-character bundle version`,async()=>{
  const key=await signingKey(),body="body",assertion=await assertionFor(key,body,{extensions:extensionMap(category,"1".repeat(32))});
  assert.equal((await verifyAssertion({assertion,clientData:utf8(body),publicKey:key.publicKey,counter:0,appID:sample.appID})).bundleVersion,"1".repeat(32));
});
for (const [name, change, error] of [
  ["equal counter", {counter:1}, "assertion counter"], ["lower counter", {counter:0}, "assertion counter"],
  ["wrong RP", {rp:new Uint8Array(32)}, "RP ID"],
  ["category 1", {extensions:extensionMap(1)}, "validation category"],
  ["category 5", {extensions:extensionMap(5)}, "validation category"],
  ["missing category", {extensions:new Map([["apple_bundle_version_01","1"]])}, "validation category"],
  ["bundle version", {extensions:extensionMap(3,"")}, "bundle version"],
  ["malformed extensions", {extensions:[]}, "extensions map"],
  ["trailing bytes", {suffix:Uint8Array.of(0)}, "CBOR trailing bytes"],
]) test(`assertion refuses ${name}`, async () => {
  const key = await signingKey(), body = "body", assertion = await assertionFor(key,body,{counter:2,...change});
  await assert.rejects(verifyAssertion({assertion,clientData:utf8(body),publicKey:key.publicKey,counter:1,appID:sample.appID}),{message:error});
});
test("assertion refuses a different signed body and a bad signature", async () => {
  const key = await signingKey(), body = "body", assertion = await assertionFor(key,body);
  const opts = {assertion,clientData:utf8("body "),publicKey:key.publicKey,counter:0,appID:sample.appID};
  await assert.rejects(verifyAssertion(opts),{message:"assertion signature"});
  const obj = decodeCBOR(assertion).value; obj.get("signature")[10] ^= 1;
  await assert.rejects(verifyAssertion({...opts,assertion:cbor(obj),clientData:utf8(body)}),{message:"assertion signature"});
});
