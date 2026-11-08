# Pulse AI

**Your Mac's mission control — built for the AI era.**

Pulse AI is a commercial macOS system monitor by metaPhasic Group
(support@metaphasic.net). It does everything a vitals app does —
processes, CPU, memory pressure, swap, thermal state — and adds the
layer no competitor ships: a live view of the local AI engines an
AI-box Mac actually runs (Ollama, LM Studio, llama.cpp, MLX,
ComfyUI), with throughput numbers that always state how they were
obtained.

- Bundle ID: `com.metaphasicgroup.pulseai`
- macOS 14+, Swift 5, SwiftUI. **Zero third-party dependencies.**
- Direct distribution (Developer ID), hardened runtime, no sandbox.
- Price: $8 one-time for the first 60 days after launch, then $19.
  One Mac per license. Serials are `PU-XXXX-XXXX-XXXX-XXXX`.

## Build

1. Open `PulseAI.xcodeproj` in Xcode 15+.
2. Select the PulseAI target → Signing & Capabilities → set your
   Team (the project ships with automatic signing and the team left
   blank on purpose).
3. Build & Run. The Guard build phase fails the build if
   `PulseAI.entitlements` or `Resources/Info.plist` goes missing.

If the hand-written project ever misbehaves, the fallback is the
fleet-standard one: create a fresh macOS App project (SwiftUI,
bundle id above), delete its template sources, and add every `.swift`
file in this tree (except `Helper/`) to the single app target, with
`Resources/Info.plist` as the Info.plist and `PulseAI.entitlements`
as the entitlements file.

Notarization (Developer ID signing, `notarytool`, stapling) is a
release step performed by the user — see SECURITY.md's
"not yet done" list.

## Architecture

```
PulseAIApp.swift            @main — window, MenuBarExtra, settings
Models/
  Models.swift              Value types: ProcessSnapshot,
                            SystemSnapshot, EngineStatus, LoadedModel,
                            ModelFile (+ DuplicateGroup), StartupItem,
                            LicenseState, HistoryEvent
  Theme.swift               Design tokens (health palette, type scale)
Services/
  ProcessEngine.swift       proc_listallpids/proc_pidinfo sampler;
                            CPU deltas; parent-chain (genealogy)
  SigningService.swift      SecCode signing info → plain-English
                            Verdict (signer, Team ID, notarization
                            heuristic, safe-to-quit reasoning)
  SystemMetrics.swift       host_statistics64 memory, vm.swapusage,
                            thermal state, IOAccelerator GPU %
  AIEngines.swift           Engine clients: Ollama, LM Studio,
                            llama.cpp, MLX, ComfyUI — loopback-only
                            (@127.0.0.1), redirects rejected, 2s
                            timeout, 256 KB cap, Provenance enum on
                            every throughput value
  ModelLibrary.swift        Ollama / Hugging Face / LM Studio /
                            loose-GGUF inventory + duplicate groups
  StartupInventory.swift    LaunchAgents/Daemons plist inventory
  LicenseService.swift      PU- serials (weighted mod-31 checksum),
                            Keychain (ThisDeviceOnly), local-first
                            validation, server check behind a protocol
  HistoryStore.swift        Append-only JSONL under Application
                            Support/PulseAI, 10 MB rotation, local only
Views/                      Dashboard, Processes (+ Verdict
                            inspector), AI Cockpit, Models, Startup,
                            Settings, MenuBar mini, ⌘K palette
Helper/                     Privileged XPC helper — SHIPS DISABLED
                            in v1; not in the app target (see
                            Helper/README.md)
server/
  licensing-server.mjs      Dependency-free Node 20 reference
                            licensing server (validate / deactivate /
                            Stripe webhook issuing PU- serials,
                            hash-only storage)
```

## Privacy stance

Pulse AI has no telemetry, no analytics, and no account. Its only
outbound traffic, ever:

1. Loopback HTTP to AI engines on 127.0.0.1 (fixed ports, hardcoded).
2. An optional license check to `https://api.metaphasic.net` on
   activation and roughly weekly thereafter — it sends the serial
   and a random per-install ID, nothing else.

History stays in a JSONL file on the machine. Verdicts are computed
from the Security framework locally. Nothing is uploaded, synced, or
shared.
