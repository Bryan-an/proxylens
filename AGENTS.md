# ProxyLens repository guidance

ProxyLens is a free, local-first macOS alternative to Proxyman: a native desktop HTTP/HTTPS proxy and debugging workspace. This file is the compact operating guide for contributors and coding agents. Keep it below the default Codex project-instruction limit of 32 KiB; put detailed explanations in `docs/` instead.

## Source documents

Read the relevant section before making architectural or product changes:

- `docs/PROXYMAN_FEATURE_INVESTIGATION.md` — researched product surface, behavior, and staged feature roadmap.
- `docs/TECH_STACK.md` — technology choices, security posture, distribution, and implementation order.
- `docs/ARCHITECTURE.md` — runtime architecture, package boundaries, data flow, concurrency, and repository structure.

These documents are complementary. The feature investigation defines product context; the tech-stack and architecture documents define implementation direction. Update the relevant document when a durable decision changes.

## Product scope

Current product decisions:

- macOS-first native desktop experience, followed by the authorized P2 companion/mobile and
  integration surfaces.
- Desktop proxying first so later protocol, device, automation, and collaboration work shares a
  reliable data plane.
- Free and local-first; no required account, server, cloud, or subscription.
- Raw request/response bytes are authoritative; decoded views are derived.
- Implement behavior independently. Do not copy Proxyman proprietary code, assets, branding, or implementation details.

The primary workflow is:

```text
capture → decrypt/parse → inspect → filter → modify/replay/mock → compare/export
```

### Roadmap

P0 is a reliable local desktop debugger:

- HTTP/1.1 forwarding proxy.
- HTTPS `CONNECT` and TLS interception with a local CA.
- Request/response capture, raw inspection, and derived JSON views.
- Three-pane traffic console, search, and filters.
- Map Local, Map Remote, Breakpoint, Block/Allow, and no-cache rules.
- HAR and cURL export.
- Session persistence and offline inspection.
- Signed and notarized direct-download macOS build.

P1 follows as the desktop data plane becomes reliable:

- WebSocket inspection, HTTP/2, throttling, scripting, richer decoders, request builders, replay, annotations, and advanced search.

P2 is an authorized expansion milestone after the relevant P0/P1 foundations:

- Mobile capture, transparent/VPN routing, HTTP/3/QUIC, cloud sync, collaboration, team accounts, hosted telemetry, MCP/Raycast integrations, and App Store distribution.

Remote device onboarding was pulled forward from that P2 line by explicit decision: a device on the
local network can point at the forward listener, be admitted by the user, and install the CA from a
local page. It adds no Network Extension, no VPN, and no second target — on-device capture is still
P2 and still deferred.

P0, P1, and P2 are all in product scope. Preserve the staged dependency order and land thin,
tested vertical slices rather than mixing unrelated milestone work into one change.

## Technology decisions

- Swift 6.x language mode, Xcode, and Swift Package Manager.
- SwiftUI for the app shell, onboarding, settings, forms, alerts, and lightweight panels.
- AppKit for the main traffic console: split views, outline grouping, sortable flow table, raw editor, keyboard commands, and high-volume updates.
- SwiftNIO for the proxy data plane: `NIOCore`, `NIOPosix`, `NIOHTTP1`, `NIOWebSocket`, and `NIOSSL` initially.
- `swift-certificates`/`X509` for certificate construction; Apple `Security` and Keychain Services for private key and certificate storage.
- GRDB.swift over SQLite for metadata, headers, timing, rules, annotations, migrations, WAL, and search indexes.
- Filesystem-backed body storage for large request/response bodies and WebSocket frames.
- SwiftNIO event loops for socket/channel state; Swift actors for application coordination and persistence; `AsyncSequence` for flow events; `@MainActor` for UI state.
- `OSLog` with redaction for diagnostics.
- Developer ID signing, Hardened Runtime, notarization, `.dmg`/`.zip`, and direct distribution initially.
- Target macOS 14+ initially.

Do not use URLSession as the core proxy engine: interception requires direct control over CONNECT, streaming, upgrades, partial messages, and pause/transform behavior. Do not introduce Network Extension for P0.

## Architecture

Use a modular monolith with ports and adapters. Keep P0 in one application process.

```text
ProxyLensApp (SwiftUI/AppKit + composition root)
        ↓
ProxyLensApplication (use cases, coordination, flow events)
        ↓
ProxyLensCore (domain models, rules, ports, typed errors)
        ↑                 ↑                  ↑
Capture/NIO       Persistence/GRDB       Platform/Keychain/macOS
```

The runtime has two domains:

- **Data plane:** SwiftNIO listener, HTTP/1.1 pipeline, CONNECT/TLS interception, upstream connection, streaming body recorder, and WebSocket handling.
- **Control plane:** `CaptureCoordinator` actor, rule configuration, `SessionStore` actor, body storage, flow event stream, and UI models.

### Dependency rules

- `ProxyLensCore` may use Foundation/value types but must not import AppKit, SwiftUI, SwiftNIO, GRDB, or concrete macOS adapters.
- `ProxyLensApplication` depends on core protocols and owns use cases; it must not contain SQL, channel handlers, or view controllers.
- `ProxyLensCapture`, `ProxyLensPersistence`, and `ProxyLensPlatform` implement core ports and may not depend on UI.
- `ProxyLensApp` is the composition root and wires concrete adapters. It may depend on all local packages.
- Never create a cyclic package dependency.
- NIO handlers must not mutate UI or perform blocking database, filesystem, certificate, or decoder work.
- UI view models must not access sockets or repositories directly.
- Individual NIO channel state belongs to its event loop. `CaptureCoordinator` owns capture lifecycle and configuration, not mutable channel internals.
- Use immutable flow snapshots and rule snapshots across boundaries.

### Recommended repository structure

```text
ProxyLens/
├── ProxyLens.xcodeproj
├── ProxyLensApp/
│   ├── App/                  # ProxyLensApp, AppDelegate, Environment, CompositionRoot
│   ├── UI/
│   │   ├── Shell/
│   │   ├── TrafficConsole/   # AppKit workspace, outline, table, inspector
│   │   ├── Settings/         # SwiftUI
│   │   └── Onboarding/       # SwiftUI
│   └── Resources/
├── Packages/
│   ├── ProxyLensCore/
│   │   ├── Sources/ProxyLensCore/Domain/{Flow,Message,Session,Timing,Rules}
│   │   ├── Sources/ProxyLensCore/Ports
│   │   └── Tests/ProxyLensCoreTests
│   ├── ProxyLensApplication/
│   │   ├── Sources/ProxyLensApplication/{CaptureCoordinator,FlowEventBus,RuleEngine,SessionService,ReplayService,ExportService}
│   │   └── Tests/ProxyLensApplicationTests
│   ├── ProxyLensCapture/
│   │   ├── Sources/ProxyLensCapture/{Listener,HTTP,Connect,Upstream,TLS,WebSocket}
│   │   └── Tests/ProxyLensCaptureTests
│   ├── ProxyLensPersistence/
│   │   ├── Sources/ProxyLensPersistence/{Database,Migrations,Repositories,Bodies,SessionStore}
│   │   └── Tests/ProxyLensPersistenceTests
│   └── ProxyLensPlatform/
│       ├── Sources/ProxyLensPlatform/{TLS,SystemProxy,Logging,LoginItems}
│       └── Tests/ProxyLensPlatformTests
├── Tests/{ProxyLensIntegrationTests,ProxyLensUITests}
├── docs/
├── scripts/
└── .github/workflows/
```

Create only the directories needed for the feature being implemented. This tree describes ownership and dependency boundaries; it is not a requirement to create empty folders.

## Domain and data rules

Core concepts include `Session`, `Flow`, `HTTPRequest`, `HTTPResponse`, `HTTPHeaders`, `FlowTiming`, `BodyReference`, `Rule`, `RulePhase`, `RuleAction`, and `RuleTrace`.

- A flow may be incomplete because of cancellation, disconnect, timeout, or upstream failure; preserve it with an explicit state.
- Keep large payloads out of normal in-memory models and SQLite rows.
- Store body size, hash, encoding, truncation state, and file reference with flow metadata.
- Preserve raw bytes before decoding. JSON, XML, forms, GraphQL, Protobuf, pretty printing, and syntax highlighting are derived representations.
- A decoder failure must not prevent raw inspection, export, replay, or session persistence.
- Treat HAR/session imports and decoded content as untrusted input.

## Capture lifecycle

The normal flow is:

```text
accept client
→ parse HTTP/1.1
→ establish CONNECT/TLS interception when needed
→ create FlowID and emit request metadata
→ evaluate request rules
→ stream/record request body or buffer only when required
→ connect upstream and forward
→ capture response and evaluate response rules
→ forward response
→ persist metadata and raw body references
→ emit final immutable flow snapshot to the UI
```

Default to streaming and teeing bytes to the body store. Buffer only for Breakpoint, body transformation, replay, or another feature that explicitly needs complete content. Respect NIO writability, timeouts, cancellation, and bounded memory.

## Rule system

All traffic transformations use a shared pipeline:

```text
Matcher + phase + action
```

- Matchers select host, path, method, query, headers, source, status, content type, or composed expressions.
- Phases cover connection, request headers/body, response headers/body, and WebSocket frames.
- Actions transform, pause, map, redirect, replace, block, allow, throttle, or annotate.
- Every applied rule should produce a trace containing the rule identity, phase, result, and error if applicable.

Keep matching and rule planning deterministic and side-effect-free in core. Put file reads, breakpoint waits, and other asynchronous work in the application layer or an adapter.

## Security requirements

- Keep the main application and proxy unprivileged.
- Store the root CA private key in Keychain; never log or export it.
- Do not log authorization headers, cookies, request/response bodies, private keys, or full URLs by default.
- Make capture state, CA trust state, and system proxy changes visible to the user.
- Save and restore the previous system proxy configuration safely.
- If a privileged helper becomes necessary, make it a separate signed target with a narrow XPC interface; do not move the whole proxy into it.
- Bound body sizes, decompression, decoded output, retained history, and diagnostics exports.
- Do not add Network Extension, mobile entitlements, or cloud authentication to P0.
- Only the forward listener may bind beyond loopback, only while the user has enabled remote access,
  and only with every non-loopback client admitted through `RemoteAccessGate`. Reverse-proxy and
  SOCKS5 listeners stay loopback-only.
- Serve the public root certificate to devices; never the root private key.

## Testing and verification

Tests must not depend on the public internet.

- Core: matchers, rule ordering, flow states, headers, timing, and body references.
- Capture: SwiftNIO embedded channels and local fixtures for fragmentation, CONNECT, TLS failures, disconnects, backpressure, timeouts, WebSockets, and Breakpoint pause/resume.
- Persistence: migrations, WAL/concurrent access, body cleanup, search indexes, and restart recovery.
- Integration/UI: start/stop capture, system proxy restoration, local HTTP/HTTPS fixtures, inspection, export, rules, and large flow lists.

When code exists:

- Run `swift test` for package changes.
- Run the relevant `xcodebuild` build/test command for app and UI changes.
- Run focused tests first, then the full suite before handing off.
- For documentation-only changes, verify links/paths and check the instruction file remains below 32 KiB.

## Quality workflow

- Run `./scripts/setup-hooks.sh` once per clone to enable the versioned hooks in `.githooks/`.
- `pre-commit` checks staged whitespace and staged Swift formatting; `pre-push` runs the full local quality script.
- Use `./scripts/quality.sh format` for explicit formatting and `./scripts/quality.sh ci` to reproduce the GitHub Actions quality job locally.
- Keep GitHub Actions and protected-branch status checks as the authoritative merge gate because local hooks can be bypassed.

## Implementation order

1. Define core flow/message/body/rule types and ports.
2. Implement HTTP/1.1 local listener and forwarding.
3. Add CA, Keychain storage, CONNECT, and TLS interception.
4. Add GRDB migrations, metadata persistence, and filesystem bodies.
5. Add `CaptureCoordinator`, `SessionStore`, and flow event stream.
6. Build the native three-pane traffic console.
7. Add filters, Map Local, Map Remote, Breakpoint, Block/Allow, and no-cache.
8. Add HAR/cURL export and signed/notarized packaging.

Defer HTTP/3, mobile/VPN capture, cloud, collaboration, and team features until P0 is reliable or
the user explicitly changes the roadmap. Remote device onboarding is such a change and has landed;
on-device capture has not.

## Working agreements

- Inspect existing files and preserve unrelated user changes before editing.
- Use `apply_patch` for source and documentation edits.
- Prefer small, feature-oriented files named after domain concepts or use cases; avoid catch-all `Managers`, `Helpers`, and `Utils` directories.
- Keep implementation decisions aligned with the three source documents. If a change intentionally diverges, explain why and update the appropriate documentation.
- Add dependencies only when a P0/P1 feature requires them; prefer Apple frameworks and the already selected stack.
- Use official documentation when verifying current Swift, Apple, SwiftNIO, GRDB, signing, or security APIs.
- Never commit secrets, captured credentials, private keys, generated session data, or local macOS configuration.
- Do not change product scope, entitlements, distribution model, or architecture boundaries silently.
