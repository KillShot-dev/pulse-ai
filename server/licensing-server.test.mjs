#!/usr/bin/env node
// End-to-end test suite for licensing-server.mjs — dependency-free.
// Boots real server processes and exercises the full purchase ->
// activation -> move -> refund lifecycle over HTTP, plus the
// cross-implementation checksum parity check (Swift/Python spec).
// Run: node licensing-server.test.mjs   (exit 0 = all green)

import { spawn } from "node:child_process";
import { createHmac, createHash } from "node:crypto";
import { readFileSync, existsSync, rmSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = join(HERE, "licensing-server.mjs");
const TMP = join(HERE, ".test-tmp");
rmSync(TMP, { recursive: true, force: true });
mkdirSync(TMP, { recursive: true });

const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
// Canonical checksum, transcribed independently from
// FileRadar licensing/serials.py and both Swift apps: weights (i+1).
const checkCharSwiftSpec = (payload) => {
  let total = 0;
  for (let i = 0; i < 15; i++) total += (i + 1) * ALPHABET.indexOf(payload[i]);
  return ALPHABET[total % 31];
};
// The drifted variant that shipped in the first JS port: weights (i+3).
const checkCharDrifted = (payload) => {
  let total = 0;
  for (let i = 0; i < 15; i++) total += (i + 3) * ALPHABET.indexOf(payload[i]);
  return ALPHABET[total % 31];
};
const fmt = (prefix, payload, check) => {
  const body = payload + check;
  return `${prefix}-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 12)}-${body.slice(12)}`;
};

let failures = 0;
const ok = (name, cond, extra = "") => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${cond ? "" : "  " + extra}`);
  if (!cond) failures += 1;
};

function boot(env, port) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [SERVER], {
      env: { ...process.env, ...env, PORT: String(port) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => {
      out += d.toString();
      if (out.includes("listening")) resolve({ child, getOut: () => out });
    });
    child.stderr.on("data", (d) => process.stderr.write(`[server] ${d}`));
    child.on("exit", (code) => reject(new Error(`server exited early (${code})`)));
    setTimeout(() => reject(new Error("server boot timeout")), 8000);
  });
}

const post = async (port, path, body, headers = {}) => {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
  return { status: res.status, json: await res.json().catch(() => null) };
};

const stripeHeader = (secret, rawBody, ts = Math.floor(Date.now() / 1000)) => {
  const sig = createHmac("sha256", secret).update(`${ts}.`).update(rawBody).digest("hex");
  return `t=${ts},v1=${sig}`;
};

const SECRET = "whsec_test_licensing_suite";
const checkoutEvent = (id, pi, email) =>
  JSON.stringify({
    id: `evt_${id}`,
    type: "checkout.session.completed",
    data: { object: { id, payment_intent: pi, customer_details: { email } } },
  });

// ---------------------------------------------------------------- PU flow
const pu = await boot(
  { STRIPE_WEBHOOK_SECRET: SECRET, STORE_PATH: join(TMP, "pu.json"), PRODUCT_PREFIX: "PU", MACHINE_LIMIT: "2" },
  18787
);
try {
  const health = await fetch("http://127.0.0.1:18787/healthz").then((r) => r.json());
  ok("healthz answers", health.ok === true);

  const evt1 = checkoutEvent("cs_test_1", "pi_test_1", "buyer@example.com");
  let r = await post(18787, "/v1/checkout/webhook", evt1, { "stripe-signature": "t=1,v1=deadbeef" });
  ok("webhook rejects a bad signature", r.status === 400);

  r = await post(18787, "/v1/checkout/webhook", evt1, {
    "stripe-signature": stripeHeader(SECRET, evt1, Math.floor(Date.now() / 1000) - 3600),
  });
  ok("webhook rejects a stale (replayed) signature", r.status === 400);

  r = await post(18787, "/v1/checkout/webhook", evt1, { "stripe-signature": stripeHeader(SECRET, evt1) });
  ok("valid checkout webhook issues a serial", r.status === 200 && r.json.issued === true, JSON.stringify(r.json));

  const issuedLine = pu.getOut().split("\n").find((l) => l.includes("serial_issued"));
  const serial = issuedLine ? JSON.parse(issuedLine).serial : "";
  ok("serial was emitted on the mailer log line", /^PU-/.test(serial), serial);

  const payload = serial.replace(/^PU-/, "").replaceAll("-", "").slice(0, 15);
  ok(
    "issued serial's check char matches the Swift/Python (i+1) spec",
    serial.endsWith(checkCharSwiftSpec(payload)),
    `serial check=${serial.slice(-1)} spec=${checkCharSwiftSpec(payload)} drifted=${checkCharDrifted(payload)}`
  );

  r = await post(18787, "/v1/checkout/webhook", evt1, { "stripe-signature": stripeHeader(SECRET, evt1) });
  ok("replayed webhook does not mint a second serial", r.status === 200 && r.json.issued === false && r.json.duplicate === true);

  const storeRaw = readFileSync(join(TMP, "pu.json"), "utf8");
  const store = JSON.parse(storeRaw);
  ok("store holds exactly one license after replay", Object.keys(store.serials).length === 1);
  ok("raw serial never touches the store file", !storeRaw.includes(serial));
  ok(
    "store keys the record by the serial's SHA-256 hash",
    Object.keys(store.serials)[0] === createHash("sha256").update(serial).digest("hex")
  );

  r = await post(18787, "/v1/serials/validate", { serial, machineId: "mac-A" });
  ok("validate machine A", r.json.valid === true, JSON.stringify(r.json));
  r = await post(18787, "/v1/serials/validate", { serial, machineId: "mac-B" });
  ok("validate machine B (2-Mac limit)", r.json.valid === true);
  r = await post(18787, "/v1/serials/validate", { serial, machineId: "mac-C" });
  ok("third machine hits the limit", r.json.valid === false && r.json.reason === "machine_limit");

  const driftedSerial = fmt("PU", payload, checkCharDrifted(payload));
  if (driftedSerial !== serial) {
    r = await post(18787, "/v1/serials/validate", { serial: driftedSerial, machineId: "mac-A" });
    ok("a serial checksummed with the drifted (i+3) weights is a format reject", r.json.valid === false && r.json.reason === "format");
  }
  const unknownSerial = fmt("PU", "ZZZZZZZZZZZZZZZ".slice(0, 15), checkCharSwiftSpec("ZZZZZZZZZZZZZZZ".slice(0, 15)));
  r = await post(18787, "/v1/serials/validate", { serial: unknownSerial, machineId: "mac-A" });
  ok("well-formed but unissued serial is unknown", r.json.valid === false && r.json.reason === "unknown");
  r = await post(18787, "/v1/serials/validate", { serial: "PU-XXXX-XXXX", machineId: "mac-A" });
  ok("malformed serial is a format reject", r.json.valid === false && r.json.reason === "format");

  r = await post(18787, "/v1/serials/deactivate", { serial, machineId: "mac-A" });
  ok("deactivate machine A (serial as credential)", r.status === 200 && r.json.ok === true);
  r = await post(18787, "/v1/serials/validate", { serial, machineId: "mac-C" });
  ok("freed slot lets machine C attach", r.json.valid === true);
  r = await post(18787, "/v1/serials/deactivate", { serial, machineId: "mac-B" });
  r = await post(18787, "/v1/serials/validate", { serial, machineId: "mac-A" });
  ok("deactivated machine can re-attach when a slot is free (move-Macs flow)", r.json.valid === true, JSON.stringify(r.json));

  const refundEvent = JSON.stringify({
    id: "evt_refund_1",
    type: "charge.refunded",
    data: { object: { id: "ch_test_1", payment_intent: "pi_test_1" } },
  });
  r = await post(18787, "/v1/checkout/webhook", refundEvent, { "stripe-signature": stripeHeader(SECRET, refundEvent) });
  ok("refund webhook revokes the license", r.status === 200 && r.json.revoked === 1, JSON.stringify(r.json));
  r = await post(18787, "/v1/serials/validate", { serial, machineId: "mac-C" });
  ok("revoked serial no longer validates", r.json.valid === false && r.json.reason === "revoked");

  const big = "x".repeat(70 * 1024);
  r = await post(18787, "/v1/serials/validate", big);
  ok("oversized body is refused", r.status === 413, `status=${r.status}`);
} finally {
  pu.child.kill();
}

// ---------------------------------------------------------------- FR flow
const fr = await boot(
  { STRIPE_WEBHOOK_SECRET: SECRET, STORE_PATH: join(TMP, "fr.json"), PRODUCT_PREFIX: "FR", MACHINE_LIMIT: "1" },
  18788
);
try {
  const evt = checkoutEvent("cs_fr_1", "pi_fr_1", "radar@example.com");
  let r = await post(18788, "/v1/checkout/webhook", evt, { "stripe-signature": stripeHeader(SECRET, evt) });
  ok("FR instance issues an FR serial", r.status === 200 && r.json.issued === true);
  const line = fr.getOut().split("\n").find((l) => l.includes("serial_issued"));
  const frSerial = line ? JSON.parse(line).serial : "";
  ok("FR serial format + prefix", /^FR-/.test(frSerial), frSerial);
  r = await post(18788, "/v1/serials/validate", { serial: frSerial, machineId: "mac-1" });
  ok("FR validate first machine", r.json.valid === true);
  r = await post(18788, "/v1/serials/validate", { serial: frSerial, machineId: "mac-2" });
  ok("FR 1-Mac terms enforced on its own instance", r.json.valid === false && r.json.reason === "machine_limit");
} finally {
  fr.child.kill();
}

console.log(failures === 0 ? "\nALL TESTS PASSED" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
