import { readFileSync } from "node:fs";
import { concat, utf8, sha256, base64, unbase64 } from "../../src/appattest.js";
export const sample = JSON.parse(readFileSync(new URL("../fixtures/apple-sample-attestation.json", import.meta.url)));
export const options = () => ({ attestation: unbase64(sample.attestation), keyId: sample.keyId,
  appID: sample.appID, clientDataHash: utf8(sample.clientDataHashUtf8), now: new Date(sample.validAt), categories: [1] });

export function cbor(value) {
  function head(type, n) {
    if (n < 24) return Uint8Array.of(type * 32 + n);
    if (n < 256) return Uint8Array.of(type * 32 + 24, n);
    if (n < 65536) return Uint8Array.of(type * 32 + 25, n >> 8, n & 255);
    return Uint8Array.of(type * 32 + 26, n >>> 24, n >>> 16 & 255, n >>> 8 & 255, n & 255);
  }
  if (value instanceof Uint8Array) return concat(head(2, value.length), value);
  if (typeof value === "string") { const b = utf8(value); return concat(head(3, b.length), b); }
  if (typeof value === "number") return value < 0 ? head(1, -1 - value) : head(0, value);
  if (Array.isArray(value)) return concat(head(4, value.length), ...value.map(cbor));
  if (value instanceof Map) return concat(head(5, value.size), ...[...value].flatMap(([k,v]) => [cbor(k), cbor(v)]));
  if (value === true) return Uint8Array.of(245);
  if (value === false) return Uint8Array.of(244);
  throw new Error("test CBOR type");
}
export function der(tag, value) {
  const n = value.length;
  const length = n < 128 ? [n] : n < 256 ? [129,n] : [130,n >> 8,n & 255];
  return concat(Uint8Array.of(tag, ...length), value);
}
export function encodeDER(node) {
  return der(node.tag, node.tag & 32 ? concat(...node.children.map(encodeDER)) : node.value);
}
export function rawSignature(raw) {
  const integer = (n) => {
    while (n.length > 1 && n[0] === 0) n = n.slice(1);
    return der(2, n[0] & 128 ? concat(Uint8Array.of(0), n) : n);
  };
  return der(48, concat(integer(raw.slice(0,32)), integer(raw.slice(32))));
}
export function extensionMap(category = 3, version = "1") {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, category, true);
  return new Map([["apple_validation_category_01", b], ["apple_bundle_version_01", version]]);
}
export async function signingKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign","verify"]);
  return { pair, publicKey: base64(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))) };
}
export async function assertionFor(key, body, { appID = sample.appID, counter = 1, extensions = extensionMap(), suffix = new Uint8Array(), rp = null } = {}) {
  const count = new Uint8Array(4);
  new DataView(count.buffer).setUint32(0, counter);
  const auth = concat(rp ?? await sha256(utf8(appID)), Uint8Array.of(0), count, cbor(extensions), suffix);
  const nonce = await sha256(concat(auth, await sha256(utf8(body))));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, nonce));
  return cbor(new Map([["signature", rawSignature(sig)], ["authenticatorData", auth]]));
}
