// DER TLV tree. OCTET/BIT STRING contents are opaque until explicitly decoded.
export function decodeDER(bytes, maxDepth = 16) {
  if (!(bytes instanceof Uint8Array)) throw new Error("DER bytes");
  let at = 0;
  function read(end, depth) {
    if (depth > maxDepth) throw new Error("DER depth");
    function byte() {
      if (at >= end) throw new Error("DER bounds");
      return bytes[at++];
    }
    const start = at, tag = byte();
    if ((tag & 31) === 31 || tag === 0) throw new Error("DER tag");
    let length = byte();
    if (length >= 128) {
      const width = length & 127;
      if (width === 0 || width > 4) throw new Error("DER indefinite/length");
      length = 0;
      for (let i = 0; i < width; i++) {
        const b = byte();
        if (i === 0 && b === 0) throw new Error("DER non-minimal length");
        length = length * 256 + b;
      }
      if (length < 128) throw new Error("DER non-minimal length");
    }
    const content = at, stop = at + length;
    if (stop > end) throw new Error("DER length bounds");
    const children = [];
    if (tag & 32) while (at < stop) children.push(read(stop, depth + 1));
    else at = stop;
    const value = bytes.slice(content, stop);
    if (tag === 2 && (!length || (length > 1 && ((value[0] === 0 && value[1] < 128) || (value[0] === 255 && value[1] >= 128))))) throw new Error("DER integer");
    if (tag === 1 && (length !== 1 || (value[0] !== 0 && value[0] !== 255))) throw new Error("DER boolean");
    if (tag === 3 && (!length || value[0] > 7 || (length === 1 && value[0] !== 0) || (value[length - 1] & ((1 << value[0]) - 1)))) throw new Error("DER bit string");
    return { tag, value, children, raw: bytes.slice(start, stop) };
  }
  const result = read(bytes.length, 0);
  if (at !== bytes.length) throw new Error("DER trailing bytes");
  return result;
}

export function expectTag(node, tag) {
  if (node?.tag !== tag) throw new Error("DER structure");
  return node;
}

// WebCrypto ECDSA uses IEEE P1363 r||s, whereas X.509/App Attest use DER.
export function derSignature(bytes, size) {
  const seq = expectTag(decodeDER(bytes), 48);
  if (seq.children.length !== 2) throw new Error("ECDSA signature");
  const out = new Uint8Array(size * 2);
  seq.children.forEach((node, i) => {
    let n = expectTag(node, 2).value;
    if (n[0] & 128) throw new Error("ECDSA negative");
    if (n[0] === 0) n = n.slice(1);
    if (!n.length || n.length > size || n.every((b) => b === 0)) throw new Error("ECDSA size");
    out.set(n, (i + 1) * size - n.length);
  });
  return out;
}
