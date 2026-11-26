// Deliberately small CBOR subset: no tags, floats, indefinite or non-minimal lengths.
// Maps retain their types (including negative COSE keys), without object coercion.
export function decodeCBOR(bytes, { offset = 0, trailing = false, maxDepth = 16 } = {}) {
  if (!(bytes instanceof Uint8Array)) throw new Error("CBOR bytes");
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > bytes.length) throw new Error("CBOR offset");
  let at = offset;
  function take(n) {
    if (!Number.isSafeInteger(n) || n < 0 || at + n > bytes.length) throw new Error("CBOR bounds");
    const value = bytes.slice(at, at + n);
    at += n;
    return value;
  }
  function read(depth) {
    if (depth > maxDepth) throw new Error("CBOR depth");
    const head = take(1)[0], major = head >> 5, ai = head & 31;
    if (major === 7) {
      if (ai === 20) return false;
      if (ai === 21) return true;
      if (ai === 22) return null;
      throw new Error("CBOR simple");
    }
    let n = ai;
    if (ai >= 24) {
      if (ai > 27) throw new Error("CBOR indefinite/reserved");
      const width = 2 ** (ai - 24);
      n = 0;
      for (const b of take(width)) n = n * 256 + b;
      if (!Number.isSafeInteger(n) || n < (width === 1 ? 24 : 2 ** (8 * (width / 2)))) throw new Error("CBOR non-minimal length");
    }
    if (major === 0) return n;
    if (major === 1) return -1 - n;
    if (major === 2) return take(n);
    if (major === 3) return new TextDecoder("utf-8", { fatal: true }).decode(take(n));
    if (major === 4) {
      const values = [];
      for (let i = 0; i < n; i++) values.push(read(depth + 1));
      return values;
    }
    if (major === 5) {
      const values = new Map(), keys = new Set();
      for (let i = 0; i < n; i++) {
        const key = read(depth + 1);
        if (typeof key !== "string" && typeof key !== "number" && !(key instanceof Uint8Array)) throw new Error("CBOR map key");
        const identity = key instanceof Uint8Array ? `bytes:${Array.from(key)}` : `${typeof key}:${key}`;
        if (keys.has(identity)) throw new Error("CBOR duplicate key");
        keys.add(identity);
        values.set(key, read(depth + 1));
      }
      return values;
    }
    throw new Error("CBOR type");
  }
  const value = read(0);
  if (!trailing && at !== bytes.length) throw new Error("CBOR trailing bytes");
  return { value, offset: at };
}
