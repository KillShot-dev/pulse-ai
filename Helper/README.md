# Pulse AI Helper — ships DISABLED in v1

This folder contains the privileged XPC helper for Pulse AI. It is
**not part of the PulseAI app target**, is **not bundled** in v1
builds, and nothing in the app attempts to contact it. The Startup
view's disable action and the root-owned-process terminate path are
visible in the UI as explicitly unavailable for this reason.

## Why it exists

Three capabilities genuinely need root on macOS, and only three:

1. `powerSample` — powermetrics-grade CPU/GPU/ANE package power.
2. `thermalDetail` — full die-temperature and fan detail.
3. `terminateProcessOwnedByRoot` — SIGTERM a root-owned runaway
   (one-shot intent token required; SIGTERM only, never SIGKILL).

Everything else Pulse does — process enumeration, signing verdicts,
system metrics, the entire AI cockpit, the model library — is
user-space. The research behind the spec is blunt: ~90% of the
product's value needs no privilege, so the helper is an optional
component, never the core.

## Security design (review before enabling)

- **Allow-listed protocol** (`XPCProtocol.swift`): exactly the three
  calls above. No shell, no file access, no generic RPC.
- **Client validation**: every connection is checked via its audit
  token + `SecCodeCheckValidity` against a designated requirement
  pinned to the app's Team ID. The requirement string contains a
  `TEAMIDPLACEHOLDER` constant; the validator **fails closed** while
  the placeholder is unreplaced.
- **One-shot intent tokens** for termination: minted per user
  confirmation, replay-rejected.
- **Registration**: `SMAppService.daemon(...)` from the app at
  enablement time; no self-install, no setuid anything.
- Review gate: the fleet's helper/XPC security review (MP-013) must
  sign off before any of this ships enabled.

## Files

- `XPCProtocol.swift` — the @objc protocol, Mach service name, and
  the client requirement constant.
- `PulseAIHelper.swift` — listener, validator, service, daemon main.
  Build as a separate command-line/daemon target when enabling;
  v1's `powerSample`/`thermalDetail` reply with explicit
  "disabled" errors rather than fabricated values.
