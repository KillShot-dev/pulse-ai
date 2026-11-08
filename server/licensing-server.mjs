#!/usr/bin/env node
// Pulse AI licensing server — REFERENCE IMPLEMENTATION.
//
// Mirrors the FileRadar fleet licensing design (see SECURITY.md):
//   - Serials are PU-XXXX-XXXX-XXXX-XXXX with a weighted mod-31
//     checksum (alphabet shared with the Swift LicenseService — any
//     change must land in both).
//   - The store keeps ONLY a SHA-256 hash of each serial + the email
//     it was issued to. The raw serial exists in exactly two places:
//     the customer's mailbox and this process's webhook log line
//     (which the operator pipes to the mailer step).
//   - Deactivation is serial-as-credential: presenting the serial is
//     the authorization, matching the fleet's deliberate design —
//     anyone holding a serial can already use it, so gating
//     deactivation adds friction without adding security.
//   - Stripe webhooks are verified with HMAC-SHA256 over the RAW
//     body using STRIPE_WEBHOOK_SECRET, compared in constant time.
//
// Dependency-free Node 20. JSON-file store. Per-IP rate limiting.
// Production deployment (hosting, TLS, process supervision, secret
// provisioning) is a USER step — this file is the reference the
// production deployment is checked against.
//
// Env: PORT (default 8787), STORE_PATH (default ./licenses.json),
//      STRIPE_WEBHOOK_SECRET (required for the webhook endpoint),
//      PRODUCT_PREFIX (default "PU"; use "FR" for the FileRadar instance),
//      MACHINE_LIMIT (default 2 for Pulse; FileRadar terms are 1).
// One codebase serves both products: run one instance per product.

import { createServer } from "node:http";
import { createHash, createHmac, randomInt, timingSafeEqual } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, renameSync } from "node:fs";

const PORT = Number(process.env.PORT || 8787);
const STORE_PATH = process.env.STORE_PATH || "./licenses.json";
const WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || "";
const PRODUCT_PREFIX = (process.env.PRODUCT_PREFIX || "PU").toUpperCase();
const MAX_BODY_BYTES = 64 * 1024;
const MACHINE_LIMIT = Number(process.env.MACHINE_LIMIT || 2);

// ---------------------------------------------------------------- serials

const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no 0/O/1/I/L

function checksumChar(payload15) {
  // CANONICAL fleet algorithm (FileRadar licensing/serials.py is the
  // spec; both Swift apps implement exactly this): weights are the
  // 1-based positions (i + 1), summed mod 31 (the alphabet length).
  // A (i + 3) weighting shipped in this file's first port and made
  // server-issued serials fail the apps' local validation — fixed
  // Nov 6, 2026; the test suite pins a cross-implementation vector.
  let sum = 0;
  for (let i = 0; i < payload15.length; i++) {
    sum += ALPHABET.indexOf(payload15[i]) * (i + 1);
  }
  return ALPHABET[sum % ALPHABET.length];
}

export function validateSerialFormat(serial) {
  const normalized = String(serial || "").trim().toUpperCase();
  const body = normalized.replace(new RegExp(`^${PRODUCT_PREFIX}-`), "").replaceAll("-", "");
  if (body.length !== 16) return false;
  for (const ch of body) if (!ALPHABET.includes(ch)) return false;
  return checksumChar(body.slice(0, 15)) === body[15];
}

function generateSerial(store) {
  // Re-roll on the (astronomically unlikely) hash collision so an
  // issued serial never overwrites an existing license record.
  for (;;) {
    let payload = "";
    for (let i = 0; i < 15; i++) payload += ALPHABET[randomInt(ALPHABET.length)];
    const body = payload + checksumChar(payload);
    const serial = `${PRODUCT_PREFIX}-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 12)}-${body.slice(12)}`;
    if (!store || !store.serials[hashSerial(serial)]) return serial;
  }
}

const hashSerial = (serial) =>
  createHash("sha256").update(String(serial).trim().toUpperCase()).digest("hex");

// ---------------------------------------------------------------- store

function loadStore() {
  if (!existsSync(STORE_PATH)) return { serials: {} };
  try {
    return JSON.parse(readFileSync(STORE_PATH, "utf8"));
  } catch {
    return { serials: {} };
  }
}

function saveStore(store) {
  // Write-then-rename so a crash mid-write can never leave a torn
  // store behind (a torn store would fail every paying customer's
  // validation as "unknown" until restored).
  const tmp = `${STORE_PATH}.tmp`;
  writeFileSync(tmp, JSON.stringify(store, null, 2), { mode: 0o600 });
  renameSync(tmp, STORE_PATH);
}

// ---------------------------------------------------------------- helpers

function json(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, { "content-type": "application/json" });
  res.end(body);
}

const error = (res, status, code, message) =>
  json(res, status, { ok: false, error: { code, message } });

// Per-IP fixed-window rate limit: 60 requests / minute / IP.
const rateBuckets = new Map();
function rateLimited(ip) {
  const now = Date.now();
  const bucket = rateBuckets.get(ip) || { count: 0, windowStart: now };
  if (now - bucket.windowStart > 60_000) {
    bucket.count = 0;
    bucket.windowStart = now;
  }
  bucket.count += 1;
  rateBuckets.set(ip, bucket);
  return bucket.count > 60;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let overflow = false;
    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        // Keep draining (discarding) so the connection survives and
        // the handler can answer a clean 413 instead of a dropped
        // socket.
        overflow = true;
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () =>
      overflow ? reject(new Error("body_too_large")) : resolve(Buffer.concat(chunks))
    );
    req.on("error", reject);
  });
}

function verifyStripeSignature(rawBody, signatureHeader, secret) {
  if (!secret || !signatureHeader) return false;
  // Header form: t=TIMESTAMP,v1=HEX[,v1=HEX...]
  const parts = Object.fromEntries(
    signatureHeader.split(",").map((kv) => {
      const idx = kv.indexOf("=");
      return [kv.slice(0, idx), kv.slice(idx + 1)];
    })
  );
  const timestamp = parts.t;
  // Replay bound: reject signatures whose timestamp is more than
  // 5 minutes from now (Stripe's own tolerance), when it parses.
  const tsNum = Number(timestamp);
  if (Number.isFinite(tsNum) && Math.abs(Date.now() / 1000 - tsNum) > 300) {
    return false;
  }
  const expected = createHmac("sha256", secret)
    .update(`${timestamp}.`)
    .update(rawBody)
    .digest("hex");
  const candidates = signatureHeader
    .split(",")
    .filter((kv) => kv.startsWith("v1="))
    .map((kv) => kv.slice(3));
  return candidates.some((candidate) => {
    const a = Buffer.from(candidate, "hex");
    const b = Buffer.from(expected, "hex");
    return a.length === b.length && timingSafeEqual(a, b);
  });
}

// ---------------------------------------------------------------- routes

async function handleValidate(req, res) {
  const raw = await readBody(req);
  let body;
  try {
    body = JSON.parse(raw.toString("utf8"));
  } catch {
    return error(res, 400, "bad_json", "Request body must be JSON.");
  }
  const serial = String(body.serial || "");
  if (!validateSerialFormat(serial)) {
    return json(res, 200, { valid: false, reason: "format" });
  }
  const store = loadStore();
  const record = store.serials[hashSerial(serial)];
  if (!record) return json(res, 200, { valid: false, reason: "unknown" });
  if (record.revoked) return json(res, 200, { valid: false, reason: "revoked" });
  const machines = record.machines || [];
  if (body.machineId && !machines.includes(body.machineId)) {
    if (machines.length >= MACHINE_LIMIT) {
      return json(res, 200, { valid: false, reason: "machine_limit" });
    }
    machines.push(body.machineId);
    record.machines = machines;
    // Re-attaching a machine that was deactivated earlier is the
    // normal move-Macs flow, not an attack: the serial is the
    // credential and machineIds are client-supplied, so a permanent
    // ban bought no security and only trapped legitimate owners.
    // The deactivation stays in the audit list until re-attach.
    if (record.deactivatedMachines?.includes(body.machineId)) {
      record.deactivatedMachines = record.deactivatedMachines.filter(
        (m) => m !== body.machineId
      );
    }
    saveStore(store);
  }
  return json(res, 200, { valid: true, email: record.email });
}

async function handleDeactivate(req, res) {
  const raw = await readBody(req);
  let body;
  try {
    body = JSON.parse(raw.toString("utf8"));
  } catch {
    return error(res, 400, "bad_json", "Request body must be JSON.");
  }
  const serial = String(body.serial || "");
  // Serial-as-credential: the serial IS the authorization.
  if (!validateSerialFormat(serial)) {
    return error(res, 403, "invalid_serial", "Serial does not validate.");
  }
  const store = loadStore();
  const record = store.serials[hashSerial(serial)];
  if (!record) return error(res, 404, "unknown_serial", "No such license.");
  if (body.machineId) {
    record.machines = (record.machines || []).filter((m) => m !== body.machineId);
    record.deactivatedMachines = record.deactivatedMachines || [];
    if (!record.deactivatedMachines.includes(body.machineId)) {
      record.deactivatedMachines.push(body.machineId);
    }
  } else {
    record.machines = [];
  }
  saveStore(store);
  return json(res, 200, { ok: true, deactivated: true });
}

async function handleWebhook(req, res) {
  const raw = await readBody(req);
  const signature = req.headers["stripe-signature"];
  if (!verifyStripeSignature(raw, signature, WEBHOOK_SECRET)) {
    return error(res, 400, "bad_signature", "Webhook signature verification failed.");
  }
  let event;
  try {
    event = JSON.parse(raw.toString("utf8"));
  } catch {
    return error(res, 400, "bad_json", "Webhook body must be JSON.");
  }
  if (event.type === "checkout.session.completed") {
    const session = event.data?.object || {};
    const email =
      session.customer_details?.email || session.customer_email || null;
    if (!email) return error(res, 422, "no_email", "Checkout session has no email.");
    const store = loadStore();
    // Idempotency: Stripe delivers webhooks at-least-once, so a
    // retry of the same checkout session must never mint a second
    // serial for one payment.
    if (
      session.id &&
      Object.values(store.serials).some((r) => r.stripeSession === session.id)
    ) {
      return json(res, 200, { received: true, issued: false, duplicate: true });
    }
    const serial = generateSerial(store);
    store.serials[hashSerial(serial)] = {
      email,
      issuedAt: new Date().toISOString(),
      machines: [],
      stripeSession: session.id || null,
      paymentIntent: session.payment_intent || null,
    };
    saveStore(store);
    // The ONLY place the raw serial is emitted: the operator log line
    // the mailer step consumes. It is never written to the store.
    console.log(JSON.stringify({ type: "serial_issued", email, serial }));
    return json(res, 200, { received: true, issued: true });
  }
  if (event.type === "charge.refunded") {
    // A refunded purchase must not keep a working license. The
    // charge carries the payment_intent stored at issuance.
    const charge = event.data?.object || {};
    const store = loadStore();
    let revoked = 0;
    for (const record of Object.values(store.serials)) {
      if (
        charge.payment_intent &&
        record.paymentIntent === charge.payment_intent &&
        !record.revoked
      ) {
        record.revoked = true;
        record.revokedAt = new Date().toISOString();
        record.revokeReason = "refunded";
        revoked += 1;
      }
    }
    if (revoked) saveStore(store);
    return json(res, 200, { received: true, revoked });
  }
  return json(res, 200, { received: true, issued: false });
}

// ---------------------------------------------------------------- server

const server = createServer(async (req, res) => {
  try {
    const ip = req.socket.remoteAddress || "unknown";
    if (rateLimited(ip)) {
      return error(res, 429, "rate_limited", "Too many requests.");
    }
    const url = new URL(req.url, "http://localhost");
    if (req.method === "POST" && url.pathname === "/v1/serials/validate") {
      return await handleValidate(req, res);
    }
    if (req.method === "POST" && url.pathname === "/v1/serials/deactivate") {
      return await handleDeactivate(req, res);
    }
    if (req.method === "POST" && url.pathname === "/v1/checkout/webhook") {
      return await handleWebhook(req, res);
    }
    if (req.method === "GET" && url.pathname === "/healthz") {
      return json(res, 200, { ok: true });
    }
    return error(res, 404, "not_found", "Unknown route.");
  } catch (err) {
    if (err && err.message === "body_too_large") {
      return error(res, 413, "body_too_large", "Request body too large.");
    }
    console.error("handler error", err);
    return error(res, 500, "internal", "Internal error.");
  }
});

server.listen(PORT, () => {
  console.log(
    `${PRODUCT_PREFIX}-licensing listening on :${PORT} (store: ${STORE_PATH}, machine limit: ${MACHINE_LIMIT})`
  );
});
