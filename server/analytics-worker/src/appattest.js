import { decodeCBOR } from "./cbor.js";
import { decodeDER, expectTag, derSignature } from "./der.js";

// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
export const APPLE_ROOT_BASE64 = "MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD";
export const utf8 = (s) => new TextEncoder().encode(s);
export const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};
export const equal = (a, b) => a instanceof Uint8Array && b instanceof Uint8Array && a.length === b.length && a.every((v, i) => v === b[i]);
export const sha256 = async (bytes) => new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
export function base64(bytes) { return btoa(String.fromCharCode(...bytes)); }
export function unbase64(text, max = 16384) {
  check(typeof text === "string" && text.length > 0 && text.length <= 4 * Math.ceil(max / 3) && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text), "base64");
  const bytes = Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
  check(bytes.length <= max && base64(bytes) === text, "base64");
  return bytes;
}
function check(ok, message) { if (!ok) throw new Error(message); }
function map(value, keys) {
  check(value instanceof Map && value.size === keys.length && keys.every((k) => value.has(k)), "CBOR shape");
  return value;
}
function hex(bytes) { return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join(""); }
const OID = {
  ec: "2a8648ce3d0201", p256: "2a8648ce3d030107", p384: "2b81040022",
  sha256: "2a8648ce3d040302", sha384: "2a8648ce3d040303",
  constraints: "551d13", usage: "551d0f", nonce: "2a864886f763640802",
};
function oid(node) { return hex(expectTag(node, 6).value); }
function date(node) {
  check(node?.tag === 23 || node?.tag === 24, "certificate time");
  const text = new TextDecoder().decode(node.value);
  check((node.tag === 23 ? /^\d{12}Z$/ : /^\d{14}Z$/).test(text), "certificate time");
  const full = node.tag === 23 ? `${Number(text.slice(0, 2)) >= 50 ? "19" : "20"}${text}` : text;
  const iso = `${full.slice(0,4)}-${full.slice(4,6)}-${full.slice(6,8)}T${full.slice(8,10)}:${full.slice(10,12)}:${full.slice(12,14)}.000Z`;
  const result = new Date(iso);
  check(Number.isFinite(+result) && result.toISOString() === iso, "certificate time");
  return +result;
}
function certificate(bytes) {
  const cert = expectTag(decodeDER(bytes), 48).children;
  check(cert.length === 3, "certificate structure");
  const tbs = expectTag(cert[0], 48), c = tbs.children;
  check(c.length === 8 && c[0].tag === 160 && equal(c[0].value, new Uint8Array([2, 1, 2])), "certificate version");
  check(equal(c[2].raw, cert[1].raw), "certificate algorithm mismatch");
  const alg = expectTag(cert[1], 48).children;
  check(alg.length === 1 && [OID.sha256, OID.sha384].includes(oid(alg[0])), "certificate algorithm");
  const validity = expectTag(c[4], 48).children;
  check(validity.length === 2, "certificate validity structure");
  const spki = expectTag(c[6], 48), s = spki.children;
  check(s.length === 2, "certificate SPKI");
  const keyAlg = expectTag(s[0], 48).children;
  check(keyAlg.length === 2 && oid(keyAlg[0]) === OID.ec, "certificate key algorithm");
  const curve = oid(keyAlg[1]);
  check([OID.p256, OID.p384].includes(curve), "certificate curve");
  const point = expectTag(s[1], 3).value;
  check(point[0] === 0 && point[1] === 4 && point.length === (curve === OID.p256 ? 66 : 98), "certificate public key");
  const extensions = new Map();
  const ext = expectTag(c[7], 163);
  check(ext.children.length === 1, "certificate extensions");
  for (const entry of expectTag(ext.children[0], 48).children) {
    const fields = expectTag(entry, 48).children;
    check(fields.length === 2 || (fields.length === 3 && fields[1].tag === 1 && fields[1].value[0] === 255), "certificate extension");
    const id = oid(fields[0]);
    check(!extensions.has(id), "certificate duplicate extension");
    // Unknown critical extensions cannot safely be ignored.
    check(fields.length !== 3 || [OID.constraints, OID.usage].includes(id), "certificate critical extension");
    extensions.set(id, expectTag(fields.at(-1), 4).value);
  }
  const constraints = expectTag(decodeDER(extensions.get(OID.constraints)), 48).children;
  check(constraints.length <= 2 && (!constraints.length || constraints[0].tag === 1), "CA constraints");
  const ca = constraints.length > 0 && constraints[0].value[0] === 255;
  if (constraints.length === 2) check(ca && constraints[1].tag === 2 && constraints[1].value[0] < 128, "CA path length");
  const sig = expectTag(cert[2], 3).value;
  check(sig[0] === 0, "certificate signature bits");
  return { tbs: tbs.raw, issuer: expectTag(c[3], 48).raw, subject: expectTag(c[5], 48).raw,
    from: date(validity[0]), to: date(validity[1]), ca, extensions, spki: spki.raw,
    publicKey: point.slice(1), curve: curve === OID.p256 ? "P-256" : "P-384",
    hash: oid(alg[0]) === OID.sha256 ? "SHA-256" : "SHA-384", signature: sig.slice(1) };
}
async function signatureValid(child, issuer) {
  const key = await crypto.subtle.importKey("spki", issuer.spki, { name: "ECDSA", namedCurve: issuer.curve }, false, ["verify"]);
  return crypto.subtle.verify({ name: "ECDSA", hash: child.hash }, key,
    derSignature(child.signature, issuer.curve === "P-256" ? 32 : 48), child.tbs);
}
function extensions(bytes, offset, categories) {
  const ext = decodeCBOR(bytes, { offset }).value;
  check(ext instanceof Map, "extensions map");
  const cat = ext.get("apple_validation_category_01");
  check(cat instanceof Uint8Array && cat.length === 4 && categories.includes(new DataView(cat.buffer, cat.byteOffset, 4).getUint32(0, true)), "validation category");
  const version = ext.get("apple_bundle_version_01");
  check(typeof version === "string" && /^[\x20-\x7e]{1,32}$/.test(version), "bundle version");
  return { bundleVersion: version };
}
function authPrefix(bytes) {
  check(bytes instanceof Uint8Array && bytes.length >= 37, "authenticator data bounds");
  return new DataView(bytes.buffer, bytes.byteOffset + 33, 4).getUint32(0);
}

/** Full Apple validation, with the design's explicit receipt/challenge departures. */
export async function verifyAttestation({ attestation, keyId, clientDataHash, appID, now, categories = [2, 3, 4] }) {
  const obj = map(decodeCBOR(attestation).value, ["fmt", "attStmt", "authData"]);
  check(obj.get("fmt") === "apple-appattest", "attestation format");
  const stmt = map(obj.get("attStmt"), ["x5c", "receipt"]), x5c = stmt.get("x5c");
  check(Array.isArray(x5c) && x5c.length === 2, "x5c length");
  const leaf = certificate(x5c[0]), intermediate = certificate(x5c[1]), root = certificate(unbase64(APPLE_ROOT_BASE64));
  check(equal(leaf.issuer, intermediate.subject) && equal(intermediate.issuer, root.subject), "chain issuer");
  check(!leaf.ca && intermediate.ca && root.ca, "chain CA constraints");
  check(leaf.curve === "P-256" && intermediate.curve === "P-384", "chain curves");
  check(Number.isFinite(+now) && [leaf, intermediate, root].every((c) => +now >= c.from && +now <= c.to), "chain validity");
  const auth = obj.get("authData"), counter = authPrefix(auth);
  check(equal(auth.slice(0, 32), await sha256(utf8(appID))), "RP ID");
  check(counter === 0, "attestation counter");
  check((auth[32] & 64) !== 0 && auth.length >= 55, "attested credential data");
  check(equal(auth.slice(37, 53), concat(utf8("appattest"), new Uint8Array(7))), "production AAGUID");
  const key = typeof keyId === "string" ? unbase64(keyId, 32) : keyId;
  check(equal(key, await sha256(leaf.publicKey)), "key ID hash");
  const length = new DataView(auth.buffer, auth.byteOffset + 53, 2).getUint16(0);
  check(length === 32 && equal(auth.slice(55, 55 + length), key), "credential ID");
  const cose = decodeCBOR(auth, { offset: 55 + length, trailing: true });
  const m = map(cose.value, [1, 3, -1, -2, -3]);
  check(m.get(1) === 2 && m.get(3) === -7 && m.get(-1) === 1 &&
    equal(m.get(-2), leaf.publicKey.slice(1, 33)) && equal(m.get(-3), leaf.publicKey.slice(33)), "COSE key");
  const metadata = extensions(auth, cose.offset, categories); // ED is clear in Apple's genuine sample.
  const nonceExtension = expectTag(decodeDER(leaf.extensions.get(OID.nonce)), 48);
  check(nonceExtension.children.length === 1, "nonce structure");
  const nonceWrapper = expectTag(nonceExtension.children[0], 161);
  check(nonceWrapper.children.length === 1, "nonce structure");
  const nonce = expectTag(nonceWrapper.children[0], 4).value;
  check(equal(nonce, await sha256(concat(auth, clientDataHash))), "attestation nonce");
  check(await signatureValid(intermediate, root), "intermediate signature");
  check(await signatureValid(leaf, intermediate), "leaf signature");
  return { publicKey: base64(leaf.publicKey), counter, ...metadata };
}

export async function verifyAssertion({ assertion, clientData, publicKey, counter: storedCounter, appID, categories = [2, 3, 4] }) {
  const obj = map(decodeCBOR(assertion).value, ["signature", "authenticatorData"]);
  const auth = obj.get("authenticatorData"), counter = authPrefix(auth);
  check(equal(auth.slice(0, 32), await sha256(utf8(appID))), "RP ID");
  check(Number.isSafeInteger(storedCounter) && counter > storedCounter, "assertion counter");
  const metadata = extensions(auth, 37, categories);
  const nonce = await sha256(concat(auth, await sha256(clientData)));
  const point = typeof publicKey === "string" ? unbase64(publicKey, 65) : publicKey;
  const key = await crypto.subtle.importKey("raw", point, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  check(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, derSignature(obj.get("signature"), 32), nonce), "assertion signature");
  return { counter, ...metadata };
}
