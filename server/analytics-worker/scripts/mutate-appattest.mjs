// Deliberate source mutations, one at a time; always restore before the next run.
// Invoke manually, outside npm test: node scripts/mutate-appattest.mjs /absolute/report.md
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = fileURLToPath(new URL("../", import.meta.url));
const report = process.argv[2];
if (!report) throw new Error("Supply the mutation table output path");
const mutations = [];
function replace(name, file, from, to, equivalentReason = null) {
  mutations.push({name,file,equivalentReason,apply(source) {
    const at=source.indexOf(from);
    if(at<0 || source.indexOf(from,at+from.length)>=0) throw new Error(`Ambiguous/missing mutation ${name}`);
    return {source:source.slice(0,at)+to+source.slice(at+from.length),line:source.slice(0,at).split("\n").length};
  }});
}
function checkRemoved(name, label) {
  mutations.push({name,file:"src/appattest.js",apply(source) {
    const at=source.indexOf(`, "${label}");`),start=source.lastIndexOf("check(",at),end=at+label.length+6;
    if(at<0 || start<0 || source.slice(end-2,end)!==");") throw new Error(`Missing check ${label}`);
    return {source:source.slice(0,start)+`check(true, "${label}");`+source.slice(end),line:source.slice(0,start).split("\n").length};
  }});
}
for(const [name,label] of [
  ["attestation format check removed","attestation format"],
  ["certificate algorithm equality removed","certificate algorithm mismatch"],
  ["unknown critical extension check removed","certificate critical extension"],
  ["chain curve policy removed","chain curves"],
  ["x5c cardinality removed","x5c length"], ["issuer/subject equality removed (order and foreign root)","chain issuer"],
  ["intermediate root signature removed","intermediate signature"], ["leaf chain signature removed","leaf signature"],
  ["certificate validity removed","chain validity"], ["CA constraints removed","chain CA constraints"],
  ["nonce comparison removed","attestation nonce"], ["key ID hash comparison removed","key ID hash"],
  ["credential ID comparison removed","credential ID"], ["RP ID comparison removed","RP ID"],
  ["attestation counter-zero check removed","attestation counter"], ["production AAGUID check removed","production AAGUID"],
  ["COSE/certificate equality removed","COSE key"], ["category check removed (1, 5, missing)","validation category"],
  ["bundle version check removed","bundle version"], ["extensions map check removed","extensions map"],
  ["assertion counter check removed","assertion counter"], ["assertion signature/body binding removed","assertion signature"],
]) checkRemoved(name,label);
replace("AT flag check removed","src/appattest.js","(auth[32] & 64) !== 0 && auth.length >= 55","auth.length >= 55");
replace("pinned root DER replaced","src/appattest.js","MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmD","MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmE");
replace("assertion RP ID check removed","src/appattest.js",
  'check(equal(auth.slice(0, 32), await sha256(utf8(appID))), "RP ID");\n  check(Number.isSafeInteger',
  'check(true, "RP ID");\n  check(Number.isSafeInteger');
replace("counter comparison accepts equality (>=)","src/appattest.js","counter > storedCounter","counter >= storedCounter");
replace("CBOR bounds check removed","src/cbor.js",'if (!Number.isSafeInteger(n) || n < 0 || at + n > bytes.length) throw new Error("CBOR bounds");',"");
replace("CBOR depth limit removed","src/cbor.js",'if (depth > maxDepth) throw new Error("CBOR depth");',"");
replace("CBOR non-minimal lengths allowed","src/cbor.js",'if (!Number.isSafeInteger(n) || n < (width === 1 ? 24 : 2 ** (8 * (width / 2)))) throw new Error("CBOR non-minimal length");',"");
replace("CBOR duplicate map keys allowed","src/cbor.js",'if (keys.has(identity)) throw new Error("CBOR duplicate key");',"");
replace("CBOR trailing bytes allowed","src/cbor.js",'if (!trailing && at !== bytes.length) throw new Error("CBOR trailing bytes");',"");
replace("DER length bounds check removed","src/der.js",'if (stop > end) throw new Error("DER length bounds");',"");
replace("DER depth limit removed","src/der.js",'if (depth > maxDepth) throw new Error("DER depth");',"");
replace("DER non-minimal length allowed","src/der.js",'if (length < 128) throw new Error("DER non-minimal length");',"");
replace("challenge expiry removed","src/index.js","DELETE FROM challenges WHERE install = ? AND expires > ? RETURNING challenge","DELETE FROM challenges WHERE install = ? AND ? IS NOT NULL RETURNING challenge");
replace("challenge reuse allowed","src/index.js","DELETE FROM challenges WHERE install = ? AND expires > ? RETURNING challenge","SELECT challenge FROM challenges WHERE install = ? AND expires > ?");
replace("clientDataHash omits install","src/index.js","concat(unbase64(issued.challenge, 32), utf8(install))","unbase64(issued.challenge, 32)");
replace("key uniqueness removed","schema.sql","key_id TEXT NOT NULL UNIQUE","key_id TEXT NOT NULL");
replace("unknown key check removed","src/index.js",'if (!stored) return reply(409, "assertion failed");',"");
replace("wrapper/event install match removed","src/index.js","rows.some((r) => r.install !== signed.install)","false");
replace("counter trigger removed","schema.sql","WHEN NEW.counter <= OLD.counter","WHEN 0");
replace("counter update moved after inserts","src/index.js","if (signed) statements.unshift(","if (signed) statements.push(");
replace("attested insertion flag removed","src/index.js","row.to_mal, row.to_anilist, row.attrs, signed ? 1 : 0","row.to_mal, row.to_anilist, row.attrs, 0");
replace("v1 path removed","src/index.js","let signed = null;","let signed = null; if (json?.v !== 2) return reply(409, \"assertion failed\");");
replace("body cap only applies to wrapper","src/index.js","if (bytes.length > MAX_BODY_BYTES) fail();","if (!signed && bytes.length > MAX_BODY_BYTES) fail();");
replace("request cap doubled","src/index.js","export const MAX_REQUEST_BYTES = 131072;","export const MAX_REQUEST_BYTES = 262144;");
replace("DELETE leaves key behind","src/index.js",'["events", "attested_keys", "challenges"]','["events", "challenges"]');
replace("DELETE leaves challenge behind","src/index.js",'["events", "attested_keys", "challenges"]','["events", "attested_keys"]');
replace("nightly purge leaves challenges behind","src/index.js",'await env.DB.prepare("DELETE FROM challenges WHERE expires <= ?").bind(Math.floor(+now / 1000)).run();',"");
replace("nightly purge leaves keys behind","src/index.js",'await env.DB.prepare("DELETE FROM attested_keys WHERE last_used < ?").bind(cutoff).run();',"");
replace("attested filter removed from pair rows","src/index.js","WHERE attested = 1 AND name IN","WHERE name IN");
replace("attested filter removed from maturity","src/index.js","SELECT install FROM events WHERE attested = 1 GROUP BY install","SELECT install FROM events GROUP BY install");
replace("CBOR ai > 27 changed to ai > 31","src/cbor.js","if (ai > 27)","if (ai > 31)",
  "Reserved/indefinite additional information still fails bounds or the non-minimal/safe-integer length checks; no newly accepted input.");
replace("DER width === 0 guard removed","src/der.js","width === 0 || width > 4","width > 4",
  "An indefinite length with width zero computes length zero and is still refused by length < 128 (non-minimal length).");
replace("certificate validity restricted to leaf","src/appattest.js","[leaf, intermediate, root].every((c)","[leaf].every((c)",
  "Fixture-equivalent only: Apple's genuine sample leaf validity is contained within the intermediate/root validity, so no request time distinguishes them; modifying signed dates fails chain signatures. Full chain validity remains in production.");

const baseline=spawnSync("npm",["test"],{cwd:root,encoding:"utf8"});
if(baseline.status!==0) throw new Error(`Baseline failed: ${baseline.stdout}\n${baseline.stderr}`);
const rows=[];
for(const mutation of mutations) {
  const path=resolve(root,mutation.file),original=readFileSync(path,"utf8");
  const change=mutation.apply(original);
  let result;
  try {
    writeFileSync(path,change.source);
    result=spawnSync("node",["--test","--test-reporter=tap","test/*.test.mjs"],{cwd:root,encoding:"utf8",timeout:30000});
  } finally { writeFileSync(path,original); }
  const names=[...result.stdout.matchAll(/^\s*not ok \d+ - (.+)$/gm)].map((m)=>m[1]);
  const failed=result.status!==0 && names.length>0 && !result.error && !/SyntaxError/.test(result.stdout+result.stderr);
  const equivalent=mutation.equivalentReason && result.status===0 && !result.error;
  const evidence=failed ? names.slice(0,3).join("; ") : equivalent ? `EQUIVALENT (suite green): ${mutation.equivalentReason}` : `SURVIVED / invalid run: status=${result.status} ${result.error ?? ""}`;
  rows.push(`| ${mutation.name} | ${mutation.file}:${change.line} | ${evidence.replaceAll("|","\\|")} |`);
  process.stdout.write(`${failed?"KILLED":equivalent?"EQUIVALENT":"SURVIVED"}: ${mutation.name}\n`);
}
mkdirSync(dirname(resolve(report)),{recursive:true});
writeFileSync(report,`# App Attest slice 1 mutation audit\n\nEach mutation was applied individually, the entire node test suite was run, and the original source was restored in finally. Baseline: green; optional owner capture absent and skipped. A killed mutation requires a failing named test, not a syntax error or timeout.\n\n| Mutation | File:line (baseline) | Failing test(s) |\n|---|---|---|\n${rows.join("\n")}\n`);
if(rows.some((r)=>r.includes("SURVIVED"))) process.exitCode=1;
