# Pulse AI — Security Model

This document is the threat model and hardening checklist for Pulse
AI. It states what is enforced, how, and — with equal weight — what
is **not yet done**. Anything not listed as done here is not done.

## Threat model

Pulse runs **unsandboxed** (direct distribution): reading other
processes and the folders where models and launch plists live is the
product. An unsandboxed monitor is a high-value target, so the design
assumes:

- **A malicious or compromised local AI engine** on loopback serving
  hostile JSON/text (the engine clients are parsers of untrusted
  input).
- **Malformed on-disk data**: corrupt plists, symlinked model
  directories, misleading process names.
- **A network attacker** is mostly out of scope precisely because
  Pulse initiates no non-loopback connections except the single HTTPS
  licensing endpoint — but redirect and DNS tricks against the
  loopback clients are in scope and handled.
- **A curious or hostile local process** attempting to use Pulse's
  privileged helper as a privilege-escalation trampoline (helper
  ships disabled in v1; validation design is documented in
  `Helper/README.md`).
- **Serial theft/forgery**: serials are bearer credentials by fleet
  design (mirroring FileRadar); the server stores only SHA-256
  hashes, so a store leak does not leak usable serials.

## Enforced in v1

- **Hardened runtime**: `ENABLE_HARDENED_RUNTIME = YES` (Debug and
  Release), with `com.apple.security.cs.allow-jit = false` and
  `com.apple.security.cs.disable-library-validation = false` in
  `PulseAI.entitlements` — no JIT, no unsigned dylib loading.
- **No sandbox, stated plainly**: `com.apple.security.app-sandbox =
  false`, justified in the entitlements header; compensated by the
  controls in this list.
- **Loopback-only engine networking**:
  - URL allow-list is hardcoded — scheme `http`, host `127.0.0.1`,
    each engine's fixed port; no user-configurable endpoints.
  - Redirects are rejected unless the target is still loopback on the
    same port (`URLSessionTaskDelegate`).
  - 2-second timeouts; **256 KB response cap** enforced in the
    delegate, not after the fact.
  - Defensive `Codable` structs: unknown fields tolerated, every
    numeric optional, every failure degrades to
    `EngineStatus.offline` — the engine layer cannot crash the app.
  - The llama.cpp Prometheus parser matches gauges by name-contains
    and treats all text as untrusted.
- **Licensing endpoint**: the only non-loopback URL in the codebase
  is the `https://api.metaphasic.net` constant in
  `LicenseService.swift`; the call is stubbed behind
  `LicenseServerChecking` so it can be faked in tests and audited in
  one place.
- **Keychain**: serial + license state stored with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; never synced, never
  in UserDefaults or files.
- **Local deactivation requires the serial itself**; server-side
  deactivation is serial-as-credential (fleet design, documented in
  `server/licensing-server.mjs`).
- **No shell execution anywhere**: no `Process`, no `NSTask`, no
  `popen` in the app, helper, or server. Process termination uses
  `kill(2)` on a pid the user selected, behind a confirmation, and
  reports errno honestly.
- **No telemetry or analytics**: no third-party code at all (zero
  dependencies), no crash reporters, no phone-home beyond the
  optional license check described in README.md.
- **History is local-only**: append-only JSONL under Application
  Support with 10 MB rotation (`HistoryStore.swift`); the file has
  no network path.
- **Model library is read-only and symlink-safe**: depth-capped
  walks, symlinks never followed, zero deletions — Pulse reports
  reclaimable bytes; only the user deletes.
- **Startup inventory is read-only in v1**: plist parsing via
  `PropertyListSerialization` with malformed-input tolerance; the
  disable action is gated behind the disabled helper.
- **Helper client validation** (for when it is enabled): audit-token
  based `SecCodeCheckValidity` against a Team-ID-pinned requirement;
  validator **fails closed** while the Team ID placeholder is
  unreplaced; allow-listed protocol of exactly three calls;
  one-shot intent tokens for root termination; SIGTERM only.
- **Server hardening** (`server/licensing-server.mjs`): Stripe
  webhook HMAC-SHA256 over the raw body with constant-time compare;
  only SHA-256(serial) + email stored; per-IP rate limiting
  (60/min); 64 KB request caps; structured JSON errors; store file
  written mode 0600.

## Not yet done (explicit)

- **Notarization**: no Developer ID certificate has been applied to
  a Pulse build; no `notarytool` submission or stapling has run.
  Builds from this tree are unsigned/un-notarized until the user
  performs the release step.
- **No build has been run**: this source tree has never been
  compiled on a Mac by this project (grammar-parse verification
  only). Xcode build verification is a scheduled fleet task.
- **Update channel**: no Sparkle (or any) auto-update mechanism
  exists yet. When added, it must use EdDSA-signed appcasts over
  HTTPS only — plain-HTTP appcasts are prohibited by this document.
- **Helper enablement**: the helper is compiled code in `Helper/`
  but is not bundled, not registered, and not reachable in v1.
  Enablement requires the fleet security review sign-off and the
  steps in `Helper/README.md`.
- **Notarization assessment in Verdicts is a heuristic**: it reads
  the designated requirement for the notarization ticket OID plus a
  Gatekeeper validity check on the executable. It is labelled
  "heuristic" in code and "Not detected" (never a false "No") in UI
  copy where the signal is absent.
- **Licensing server is a reference implementation**: JSON-file
  store, no TLS termination, no process supervision. Production
  deployment (hosting, TLS, secrets management, backups) is a user
  step, checked against this file and the server header.
- **No penetration test or external audit** has been performed.
  This document is a design/hardening record, not a certification.
