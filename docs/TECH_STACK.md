# ProxyLens technical stack

**Status:** Recommended architecture
**Scope:** macOS-first native desktop product; complete staged P0/P1/P2 roadmap
**Date:** 2026-08-02

## Executive decision

ProxyLens should be a Swift-first macOS application with a native AppKit traffic console, SwiftUI for application shell and settings, and a SwiftNIO-based local HTTP/HTTPS proxy engine.

The initial product should be distributed directly as a signed and notarized macOS application. It should use SQLite through GRDB for flow metadata and a filesystem-backed body store for large payloads. Swift actors should own application state at the boundaries between SwiftNIO and the UI.

The first implementation target is **macOS 14 or later**. The minimum version can be revisited after the first working proxy, but starting with a current macOS baseline keeps the native API surface and signing/distribution workflow manageable.

The resulting stack is:

```text
Swift 6.x + Xcode + Swift Package Manager
                    |
        SwiftUI shell + AppKit debugger
                    |
     SwiftNIO HTTP/1.1 + CONNECT + WebSocket
                    |
       NIOSSL + swift-certificates + Keychain
                    |
        GRDB/SQLite + filesystem body store
                    |
       Signed, notarized direct macOS distribution
```

## Product constraints this stack optimizes for

- A native macOS experience rather than a cross-platform UI abstraction.
- A local debugging workflow with low latency and reliable traffic inspection.
- HTTP and HTTPS interception before mobile capture, VPN routing, or cloud collaboration.
- Raw request and response bytes remaining recoverable and authoritative.
- A desktop application that can handle many flows without making the UI or proxy loop block.
- A free, local-first product with no required account, server, or subscription.
- A codebase that can add the authorized HTTP/2, scripting, mobile-capture, automation, and
  collaboration milestones without replacing the core domain model.

The product feature inventory and staged roadmap are documented in [PROXYMAN_FEATURE_INVESTIGATION.md](PROXYMAN_FEATURE_INVESTIGATION.md).

## Stack at a glance

| Area | Recommendation | Why |
| --- | --- | --- |
| Language | Swift 6.x, Swift 6 language mode | Native macOS APIs, strong typing, structured concurrency, and compiler-assisted data-race checking. |
| Build | Xcode + Swift Package Manager | First-party macOS tooling and a simple dependency graph. |
| Application UI | SwiftUI for shell, onboarding, settings, and lightweight panels | Fast native composition and good fit for application-level screens. |
| Traffic console | AppKit | Mature table, outline, split-view, keyboard, selection, and large-list behavior. |
| Proxy engine | SwiftNIO 2.x | Nonblocking event loops, explicit HTTP pipelines, streaming `ByteBuffer`s, and protocol modules. |
| HTTP/TLS | `NIOHTTP1`, `NIOSSL`, `swift-certificates`, Apple `Security` | Covers HTTP/1.1 interception, CONNECT tunneling, dynamic leaf certificates, and Keychain storage. |
| WebSocket | `NIOWebSocket` | Required for inspecting, composing, reconnecting, and replaying WebSocket upgrades and frames. |
| Local database | SQLite through GRDB.swift | Migrations, WAL mode, observation, FTS5, and a Swifty persistence layer. |
| Large payloads | Content-addressed or flow-scoped files on disk | Avoids placing multi-megabyte bodies and frame streams in SQLite rows. |
| Concurrency | Swift actors at application boundaries; SwiftNIO event loops in the proxy | Keeps I/O responsive while preventing unsynchronized state changes. |
| Logging | `OSLog` / unified logging | Native subsystem/category filtering without making request bodies part of normal logs. |
| Testing | Swift Testing or XCTest, NIO embedded channels, local integration fixtures, XCUITest | Exercises protocol fragmentation, rules, persistence, and native UI behavior. |
| Distribution | Developer ID signing, Hardened Runtime, notarization, `.dmg` and `.zip` | Best fit for a free direct-download developer tool. |
| Initial OS target | macOS 14+ | Reduces compatibility cost while the product is being built. |

## Why Swift and native macOS

Swift is the best fit for this product because the hard parts are macOS integration and a long-lived, high-throughput local proxy rather than cross-platform UI delivery.

The application needs first-class access to:

- Keychain identities and certificates.
- System proxy configuration.
- Native menus, keyboard shortcuts, windows, tables, and split views.
- Login-item or helper-process registration when the product eventually needs it.
- Code signing, hardened runtime, notarization, and macOS privacy behavior.

Swift 6 language mode should be enabled early. The compiler's strict concurrency checking is useful for finding races between proxy capture, persistence, rule evaluation, and UI updates while the architecture is still inexpensive to change.

The trade-off is that this is not the shortest path to a cross-platform product. That is intentional: cross-platform support is outside the current product decision, and a native macOS debugger is the primary differentiator.

## UI architecture: SwiftUI plus AppKit

### SwiftUI owns the application shell

Use SwiftUI for:

- The app entry point and scene wiring.
- Onboarding and first-run setup.
- Preferences and proxy configuration.
- Certificate installation guidance.
- Filter-builder and rule-editor forms.
- Empty states, alerts, status banners, and simple inspectors.
- Future licensing, update, and diagnostics screens if they become necessary.

### AppKit owns the traffic console

Use AppKit for the main debugging workspace:

- `NSSplitViewController` for the three-pane layout.
- `NSOutlineView` for source/application/domain grouping.
- `NSTableView` for the flow list and sortable columns.
- `NSTextView` for raw headers, bodies, and editable replay content.
- Custom `NSTableCellView` or view-based cells for method, status, timing, size, and tags.
- Native responder-chain handling for search, focus, copy, repeat, breakpoint actions, and keyboard navigation.

The traffic console is a high-density, stateful workspace. It needs selection stability, column resizing, multi-selection, fast incremental updates, keyboard-first operation, and predictable behavior with thousands of flows. AppKit is the lower-risk choice for this surface.

SwiftUI and AppKit should share view models and domain types rather than duplicate business logic. The UI layer must not know how a socket, TLS pipeline, or SQLite transaction works.

## Proxy engine: SwiftNIO

Use SwiftNIO as the foundation of the capture engine. Its event-loop model and protocol modules expose the control needed for a debugging proxy: connection phases, CONNECT handling, TLS upgrades, streaming bodies, backpressure, and WebSocket frame boundaries.

Initial SwiftNIO modules:

- `NIOCore` — buffers, channels, handlers, promises, and event loops.
- `NIOPosix` — macOS socket transport.
- `NIOHTTP1` — HTTP/1.1 parsing and serialization.
- `NIOHTTP2` — downstream and upstream HTTP/2 ALPN negotiation, frame/state validation, per-stream
  channels, and origin connection multiplexing inside intercepted TLS.
- `NIOWebSocket` — WebSocket upgrade and frame handling.
- `NIOSSL` — TLS client/server channels and certificate configuration.

Potential later transport additions now that the HTTP/1.1 capture path is stable:

- `SwiftNIOTransportServices` if Network.framework-backed transport is useful for a particular macOS integration.
- A higher-level client built on SwiftNIO only where it reduces code without hiding the interception boundary.

### First proxy milestone

The first capture engine should support:

1. Listening on a local TCP port.
2. HTTP/1.1 forward proxy requests.
3. HTTPS `CONNECT` tunnels.
4. Dynamic per-host leaf certificates for MITM inspection.
5. Upstream TLS connections.
6. Request and response header/body streaming.
7. WebSocket upgrades and frame capture.
8. Correct cancellation, backpressure, timeouts, and connection teardown.
9. Flow events emitted independently of the UI.

The downstream and upstream HTTP/2 milestones are now implemented for ordinary requests inside
intercepted HTTPS. Generated server TLS contexts advertise `h2` and `http/1.1`; NIOHTTP2 validates
the client connection and creates one bounded channel per request stream. An engine-owned upstream
pool separately advertises `h2` and `http/1.1`, shares the first ALPN negotiation, and multiplexes
eligible requests over one origin connection per proxy event loop. HTTP/1.1-only origins are cached
for the capture run and continue through the stable dedicated transport. WebSocket upgrades bypass
the pool. H2c, server push, connection coalescing, and RFC 8441 extended `CONNECT` remain later
milestones. HTTP/3/QUIC, transparent VPN capture, and mobile-device routing remain staged
separately so they do not weaken the desktop proxy.

### Why not URLSession as the core proxy

`URLSession` is useful for ordinary application HTTP requests, but it is too high-level for the core capture path. ProxyLens needs direct control over CONNECT, raw streaming, protocol upgrades, partial messages, interception pauses, and replay transformations. SwiftNIO makes those boundaries explicit.

## TLS interception and macOS integration

TLS is a product subsystem, not an implementation detail. It should be isolated behind protocols so that certificate generation, trust installation, and connection interception can be tested independently.

### Certificate components

- `swift-certificates` / `X509` for creating and serializing the local root CA and per-host leaf certificates.
- `NIOSSL` for configuring the server-side client connection and the client-side upstream connection.
- Apple `Security` and Keychain Services for protecting the root private key and certificate material.
- A leaf-certificate cache keyed by hostname and relevant certificate parameters, with bounded lifetime and invalidation.

The root CA private key must never be written to normal logs, SQLite, exported session files, or crash reports. The certificate store should expose only the minimum operations needed by the TLS subsystem.

For P0, the root uses a permanent P-256 `SecKey` marked sensitive and non-extractable, while its public certificate is stored as a native Keychain certificate item. Per-host P-256 leaf keys are short-lived, generated only in memory, and held in a bounded cache. Only leaf certificate/key PEM crosses the certificate-provider boundary into NIOSSL; root private-key bytes are never serialized. Both intercepted client channels and upstream channels require TLS 1.2 or newer, and upstream verification remains enabled against the system trust store plus explicitly configured additional roots used by local tests.

### Trust and system proxy setup

The first release should provide explicit onboarding and a reversible setup flow:

- Generate a local CA on first use.
- Store it in the Keychain.
- Install trust into the macOS user domain with `SecTrustSettings`, prompting for the login password. Saving the PEM remains available as a manual Keychain Access fallback.
- Configure the macOS HTTP/HTTPS proxy through a narrow integration wrapper.
- Restore the previous proxy configuration when the user disables capture, subject to clear user consent and failure-safe behavior.

The main app should remain unprivileged. If a privileged action is eventually unavoidable, isolate it in a small signed helper and communicate over a narrow XPC interface. Do not make the entire proxy engine run with elevated privileges.

Use `ServiceManagement.SMAppService` later for a login item or launch-agent style helper if background startup becomes a product requirement. It is not required for the first capture milestone.

### Deliberately deferred: Network Extension

`NetworkExtension` is reserved for a later transparent-capture or mobile-device architecture. It introduces a different permission, entitlement, lifecycle, and debugging model. It is unnecessary for a user-configured desktop HTTP/HTTPS proxy and should not be a P0 dependency.

## Storage architecture: GRDB and SQLite

Use GRDB.swift over SQLite for structured local data. SQLite is a good fit because the first product is local-first, needs durable sessions, benefits from indexed filtering, and should work without a server or account.

Enable WAL mode and use migrations from the first schema. The database should contain searchable metadata and references to payloads, not unlimited raw body blobs.

### SQLite stores

- Sessions and session metadata.
- Flow identity, timestamps, source, host, method, URL, status, sizes, and timing summaries.
- Request and response headers.
- Body references, sizes, MIME types, hashes, and truncation state.
- WebSocket frame metadata and body references.
- Server-Sent Event metadata and bounded derived data references.
- Tags, comments, folders, and user annotations.
- Rule definitions and rule execution results where persistence is needed.
- Saved filters and view preferences.
- FTS5 indexes for URLs, headers, and selected text fields.

### Filesystem stores

Use a managed application-data directory for:

- Request and response bodies above a small inline threshold.
- WebSocket frame payloads.
- Server-Sent Event data payloads.
- HAR export staging files and portable `.proxylens` session packages.
- Optional decoded artifacts if they are expensive to recompute.

Each body reference should include size, content hash, encoding information, and a cleanup policy. The database record is authoritative for metadata; the file is authoritative for the corresponding raw bytes.

### Raw bytes are authoritative

The capture path should preserve raw bytes before decoding. ImageIO thumbnails, JSON trees, XML views, form fields, GraphQL views, Protobuf decodes, Server-Sent Events, pretty printing, search indexes, and syntax highlighting are derived representations.

A decoder must never replace the captured bytes. If a decoder fails, the user should still be able to inspect, export, replay, or save the original message.

## Concurrency and ownership model

The application should use two concurrency domains with an explicit boundary:

```text
SwiftNIO event loops
        |
        v
CaptureCoordinator actor
        |
        v
SessionStore actor
        |
        v
AsyncSequence of flow events
        |
        v
@MainActor UI models and views
```

Responsibilities:

- **SwiftNIO event loops:** socket I/O, protocol handlers, pipeline state, streaming, and backpressure. Keep handlers small and avoid blocking work.
- **`CaptureCoordinator` actor:** owns capture lifecycle, active connections, pause/resume decisions, and handoff to rules/storage.
- **`SessionStore` actor:** serializes database writes, body-file operations, cleanup, and session lifecycle.
- **`AsyncSequence` flow events:** the UI-facing stream of immutable snapshots or deltas. Events must be safe to drop or coalesce for display without changing captured data.
- **`@MainActor` UI models:** selection, sorting, filtering, panel state, and presentation.

Rules that protect this boundary:

- Never mutate AppKit or SwiftUI state from an NIO event loop.
- Never perform SQLite, filesystem, certificate generation, or body decoding synchronously in a protocol handler.
- Do not pass mutable `ByteBuffer`s across actors without an explicit ownership decision.
- Prefer immutable flow snapshots and body references over sharing large mutable payloads.
- Apply UI backpressure by coalescing display updates, not by dropping captured traffic.

## Domain and module boundaries

The codebase should be organized as a small number of feature-oriented Swift packages or targets. Keep protocol code, product rules, persistence, and UI separable from the beginning.

```text
ProxyLens/
├── App/
│   ├── ProxyLensApp
│   ├── MainWindow
│   ├── Preferences
│   └── Onboarding
├── Core/
│   ├── Flow
│   ├── Message
│   ├── Source
│   ├── Timing
│   ├── BodyReference
│   └── Identifiers
├── Capture/
│   ├── Listener
│   ├── HTTPProxy
│   ├── ConnectTunnel
│   ├── UpstreamConnection
│   ├── TLSUpgrade
│   └── WebSocket
├── TLS/
│   ├── CertificateAuthority
│   ├── LeafCertificateCache
│   ├── KeychainStore
│   └── TrustSetup
├── Rules/
│   ├── Matcher
│   ├── RulePipeline
│   ├── Breakpoint
│   ├── MapLocal
│   ├── MapRemote
│   ├── BlockAllow
│   └── Throttling
├── Storage/
│   ├── SQLiteStore
│   ├── BodyStore
│   ├── Migrations
│   └── SessionStore
├── Decoders/
│   ├── Raw
│   ├── JSON
│   ├── XML
│   ├── Form
│   └── Multipart
├── Formats/
│   ├── HAR
│   ├── CURL
│   └── SessionExport
├── UI/
│   ├── SwiftUIShell
│   ├── TrafficConsole
│   ├── FlowTable
│   ├── FlowOutline
│   └── Inspector
├── CLI/
└── Tests/
```

The exact target layout can remain a single app target plus Swift packages initially. The important constraint is dependency direction:

```text
UI -> application services -> Core
Capture -> Core, TLS, Rules, Storage interfaces
Storage -> Core
Decoders -> Core
Formats -> Core
Core -> no UI, no AppKit, no SwiftUI
```

## Rule engine design

Map Local, Map Remote, Breakpoint, Block/Allow, DNS Spoofing, throttling, and no-cache behavior
should share one rule pipeline instead of becoming separate special-case features.

Represent a rule as:

```text
Matcher + phase + action
```

Where:

- **Matcher** selects by host, path, method, query, headers, source, status, content type, or a composed expression.
- **Phase** identifies request headers, request body, response headers, response body, connection, or WebSocket frame processing.
- **Action** transforms, pauses, redirects, replaces, blocks, allows, routes to a physical
  destination, throttles, or annotates the message.

The rule engine should produce a trace for each applied rule. The trace is useful for debugging the debugger: users should be able to see why a flow was mapped, paused, blocked, or changed.

P0 rules:

- Filter/display matching.
- Map Local.
- Map Remote.
- Breakpoint for request and response editing.
- Block/Allow.
- No-cache response behavior.

P1 rules:

- Throttling profiles.
- Script hooks.
- Rich body matchers.
- Advanced protocol-specific transformations.

## Dependency policy

Keep the initial dependency set intentionally small:

### Initial dependencies

- SwiftNIO.
- NIOSSL.
- GRDB.swift.
- swift-certificates.

### Apple frameworks

- SwiftUI.
- AppKit.
- Foundation.
- Security.
- CryptoKit where cryptographic primitives are needed outside X.509 construction.
- JavaScriptCore for the process-isolated P1 request/response scripting runtime.
- OSLog.
- ServiceManagement only when a helper or login item is introduced.

### Add only when a feature earns it

- HTTP/2 support through `NIOHTTP2`.
- Mobile/transparent routing through `NetworkExtension`.
- Protobuf/GraphQL decoders.
- Broader JavaScript capabilities such as modules, async networking, and controlled local files.
- Cloud sync, authentication, team workspaces, or hosted telemetry.

Avoid adding a large cross-platform UI framework, embedded browser shell, server database, cloud account system, or general-purpose ORM. Each would increase the surface area without helping the desktop proxy milestone.

## Distribution and security posture

The first public build should use direct distribution:

1. Build an optimized macOS app.
2. Sign it with Developer ID.
3. Enable the Hardened Runtime.
4. Package a `.dmg` and/or `.zip`.
5. Submit the release for Apple notarization.
6. Publish the artifact and checksums on GitHub Releases.

Hardened Runtime and `scripts/package.sh` are in place. Default packaging is an ad-hoc signed `.zip` plus SHA-256 checksum; `scripts/notarize.sh` fails closed without a Developer ID. GitHub Releases wait on a paid Apple Developer Program membership. See [DISTRIBUTION.md](DISTRIBUTION.md).

This avoids App Store constraints while the product needs system proxy setup, Keychain interaction, local session files, and possibly a narrowly scoped helper. App Store distribution can be evaluated later; it should not drive the first architecture.

Security requirements for every release:

- Do not log authorization headers, cookies, request bodies, private keys, or full URLs by default.
- Make capture status and CA trust status visible to the user.
- Provide a clear stop-capture action that closes or drains active proxy connections safely.
- Make certificate generation, trust installation, and proxy configuration explicit and reversible.
- Treat imported HAR/session files as untrusted input.
- Bound body sizes, decoded output, decompression, and retained history to prevent accidental resource exhaustion.
- Keep the helper, if introduced, smaller and more privileged than the main application.
- Document how to remove the local CA and restore system settings.

## Testing strategy

### Unit tests

- URL, host, path, query, header, and method matchers.
- Rule ordering and phase transitions.
- HTTP message normalization.
- Body references and cleanup policies.
- Certificate subject/SAN generation and cache invalidation.
- HAR and cURL serialization.
- JSON/XML/form/multipart decoder fallbacks.

### Protocol tests

Use SwiftNIO embedded channels and local fixtures to test:

- Fragmented headers and bodies.
- Large streaming bodies.
- CONNECT success and failure.
- TLS handshake failures and upstream certificate errors.
- Client disconnects during request or response streaming.
- WebSocket upgrades and fragmented frames.
- Breakpoint pause/resume and rule transformations.
- Backpressure and timeout behavior.

These tests must not depend on the public internet.

### Persistence tests

- Fresh database migration.
- Upgrade through every migration.
- WAL behavior under concurrent reads and writes.
- Crash/restart recovery for a session.
- Orphaned body-file cleanup.
- Search index updates and removal.

### UI tests

- Onboarding and proxy start/stop.
- Flow selection and inspector updates.
- Search/filter behavior.
- Keyboard navigation and copy/export actions.
- Breakpoint editing.
- Map Local/Remote configuration.
- Large-flow-list scrolling and incremental updates.

## Observability and diagnostics

Use `OSLog` with categories such as:

- `capture`
- `tls`
- `rules`
- `storage`
- `ui`
- `distribution`

Log identifiers, counts, durations, and error categories by default. Redact or hash sensitive values. Add an opt-in diagnostics export that contains configuration and sanitized error information, never private keys or captured traffic unless the user explicitly selects a session export.

Useful internal metrics include:

- Active client connections.
- Active upstream connections.
- Flows captured, displayed, persisted, and dropped from the display buffer.
- Bytes streamed and stored.
- TLS handshake success/failure counts.
- Rule matches by rule identifier.
- Persistence queue depth and write latency.
- UI update latency and visible-flow count.

## Implementation order

### P0 — reliable desktop proxy and debugger

1. Create the Swift macOS app and package boundaries.
2. Add SwiftNIO, NIOSSL, GRDB, and swift-certificates.
3. Build a local HTTP/1.1 listener and forward proxy.
4. Add HTTPS CONNECT and dynamic CA/leaf certificate handling.
5. Persist flow metadata and raw bodies.
6. Build the AppKit three-pane traffic console.
7. Add filtering, search, and flow inspection.
8. Add Map Local, Map Remote, Breakpoint, Block/Allow, and no-cache rules.
9. Add HAR import/export and cURL export.
10. Package a Hardened Runtime Release zip; notarized GitHub Releases wait on a Developer ID.

### P1 — serious daily-driver debugging features

- WebSocket frame inspection is implemented for HTTP and intercepted HTTPS upgrades. The NIO bridge
  relays text, binary, continuation, ping, pong, and close frames in both directions; frame metadata
  is stored in GRDB while payloads use bounded inline or filesystem-backed body references. The
  native inspector streams a bounded latest-500 chronological list and lazily renders the selected
  payload as formatted JSON, text, Protobuf, or hex. Auto and Protobuf reconstruct the complete
  message containing any selected text/binary fragment, ignore interleaved control frames, and
  decode negotiated `permessage-deflate` with direction-specific context/window parameters. Input,
  history, and displayed output are explicitly bounded; invalid, incomplete, or truncated messages
  fail with a reason. Request and response descriptor choices apply according to frame direction.
  Hex remains the authoritative selected-frame bytes. All/Sent/Received filtering and bounded
  payload search are available in the Frames view.
  Complete persisted frame histories can be exported as versioned local JSON with UTF-8 text and
  base64 binary payloads. The Frames view can also send bounded text or Base64 binary messages toward
  the server or client while the selected connection is open; authored frames use the same capture
  and persistence path. Closed and imported WebSocket flows expose a Reconnect editor seeded with
  the captured URL, validated request headers, and an optional reconstructed complete text or binary
  message. A dedicated SwiftNIO client opens a fresh `ws://` or system-verified `wss://` connection,
  records it as a separate replay flow, masks authored/control frames, answers Ping, completes a
  bounded Close handshake, and keeps the new flow available for further Compose and Disconnect.
  Incoming WebSocket data frames can also enter the shared Breakpoint pipeline. The bridge records
  authoritative upstream bytes before pausing, allows the native Frames inspector to edit only a
  complete uncompressed UTF-8 text payload up to 1 MiB, and resumes on the owning event loop with
  transport metadata unchanged. Binary, fragmented, compressed, invalid UTF-8, and oversized
  payloads remain read-only; control frames bypass breakpoints, and Abort closes both peers.
- Server-Sent Event capture and inspection is implemented for identity, gzip, x-gzip, and deflate
  `text/event-stream` responses. A streaming zlib adapter handles compressed chunks, including
  zlib-wrapped and legacy raw deflate, while bounding lifetime decoded output to the response
  capture limit. Corrupt, truncated, over-limit, unsupported, or stacked codings stop only derived
  event capture; the compressed response bytes remain authoritative. The incremental parser handles
  CR, LF, CRLF, an initial UTF-8 BOM,
  comments, multi-line `data`, `event`, `id`, and valid `retry` fields while bounding individual
  lines and normalized event data. Event metadata is stored in GRDB and data uses the body store;
  the native Events inspector streams a bounded latest-500 list, searches bounded metadata/data,
  lazily formats JSON, and exports complete persisted histories in versioned JSON. The original
  response body remains authoritative. A searchable and copyable Accumulated presentation derives
  text from recognized OpenAI Chat Completions and Responses API events within an 8 MiB total,
  256 KiB per-event, and 1 MiB output budget; omissions, ignored events, and truncation are visible.
  Brotli and other unsupported stream codings remain available through Raw/Body inspection.
- HTTP/2 interception is implemented in both directions for ordinary HTTPS requests: downstream
  `CONNECT` tunnels provide independent bounded stream flows, while an engine-owned upstream pool
  multiplexes each origin per event loop, shares in-flight ALPN negotiation, caches HTTP/1.1
  fallback, evicts closed parents, and closes retained channels during capture shutdown. Rules,
  body capture, inspectors, and client-facing version metadata are transport-independent. Optional
  connection metadata records the observed upstream HTTP version and whether the HTTP/2 parent was
  new or reused; older snapshots decode with unknown diagnostics. WebSocket upgrades use dedicated
  HTTP/1.1; h2c, server push, coalescing, and RFC 8441 remain staged.
- DNS Spoofing is implemented as a connection-phase rule with bounded IPv4/IPv6-literal targets.
  The capture layer separates the logical request authority from the physical socket destination:
  HTTP/1.1, WebSocket, and HTTP/2 transports connect to the spoof address while HTTP `Host`, TLS
  SNI, certificate validation, captured metadata, and exports keep the logical host. HTTP/2 pool
  identity includes both destinations to prevent unsafe connection reuse. The native rule editor,
  profiles, portable rule import/export, and selected-flow shortcut share the typed action. No
  system DNS or trust configuration is changed.
- Reverse Proxy uses additional `ServerBootstrap` listeners on the capture engine's existing event-
  loop group. A validated route maps one numeric loopback endpoint to one HTTP or HTTPS base URL;
  the handler converts the client's origin-form target into the logical upstream URL before the
  normal rule and transport pipeline runs. The forward listener and all enabled reverse listeners
  form one atomic capture start: a failed bind closes every listener and the upstream HTTP/2 pool
  before the event-loop group shuts down. Reverse routes share body capture, rules, scripts,
  WebSocket upgrades, SSE, and upstream HTTP/2, but reject `CONNECT` and never accept credentials,
  queries, or fragments in the configured base URL. A versioned `UserDefaults` document holds at
  most 32 routes; the native manager locks listener mutations while capture is active and injects
  the saved snapshot only on the next start.
- SOCKS5 uses a separate optional `ServerBootstrap` listener on the same event-loop group. A
  bounded 512-byte negotiation state machine accepts no-auth CONNECT for IPv4, IPv6, and domain
  destinations, rejects unsupported authentication, BIND, UDP, and malformed requests with SOCKS5
  replies, then removes itself before replaying preserved application bytes into the normal HTTP or
  intercepted-TLS pipeline. Listener configuration is numeric-loopback-only, versioned in local
  `UserDefaults`, disabled by default, and injected at capture start. Forward, SOCKS5, and reverse
  binds form one atomic operation, and every failure closes opened channels plus the shared upstream
  HTTP/2 pool. The native Listeners sheet owns stopped-state editing without adding another toolbar
  control.
- Throttling. Removable, host-scoped latency-only presets plus Slow 3G, Fast 3G, and Wi-Fi presets
  are implemented through the shared rule pipeline. Connection latency and upload/download
  transfer deadlines are scheduled without blocking a NIO event loop; bounded queues coordinate
  channel `autoRead` for backpressure. A native Custom editor validates bounded one-off host
  profiles. Optionally naming a custom profile stores it in local `UserDefaults`; saved profiles
  can be applied to another host or removed from the flow menu. Profiles also support deterministic
  request-level loss, including Lost Connection and Very Bad Network presets. The proxy closes a
  sampled request before opening an upstream connection and records an explicit failed flow; it
  does not drop arbitrary HTTP bytes. A native AppKit Rules sheet lists the ordered live rule set,
  shows action/phase/matcher/priority details, and supports immediate enable/disable and removal.
  Its validated rule form creates and edits Block, Allow, Breakpoint, and No Cache rules with
  action-compatible phases and native matcher fields. Edits retain rule identity and hidden action
  details; unsupported complex or file-backed shapes remain read-only instead of being rewritten
  incompletely. The same sheet saves, applies, and deletes durable named rule profiles. Versioned
  JSON archives atomically persist the complete rule set plus referenced Map Local resources under
  Application Support, with bounded count and archive size. Same-name saves preserve stable profile
  identity. The sheet also imports and exports bounded `.proxylensrules` JSON documents through
  native file panels. Import validates the file, schema, profile name, and embedded Map Local
  resource references before updating local storage and never silently applies the imported rules.
- Timing inspection. The AppKit bottom pane derives a proportional waterfall from persisted
  request, connect, TLS, first-byte, response, and completion milestones. It omits unavailable
  phases for partial flows. A compact Connection summary presents the client HTTP version, observed
  upstream HTTP version, and new/reused upstream socket state without changing captured protocol
  metadata. DNS timing and zoomable cross-flow charts need deeper capture instrumentation and
  remain future increments.
- Flow comparison. A two-row table selection opens a native side-by-side Request/Response diff with
  aligned line numbers, synchronized scrolling, and restrained red/green change backgrounds.
  Comparison reads immutable bodies through the body-reader port, decodes supported content
  encodings for UTF-8 presentation, and bounds both body loading and line-alignment work. Binary,
  oversized, and unavailable bodies remain explicit placeholders. The comparison can switch to a
  syntax-colored unified representation with standard line ranges, copy the selected message diff,
  or atomically export it as `.diff`; external diff-tool handoff remains a future increment.
- Request code generation. A native captured-flow sheet produces syntax-highlighted, copy-ready
  cURL, HTTPie, JavaScript `fetch`, Axios, Python `requests`, Swift `URLSession`, Go `net/http`, and
  Java `HttpClient` snippets. Generation
  reads the authoritative request body once, bounds interactive payloads to 8 MiB, reconstructs
  binary bodies from base64, and leaves transport-owned headers to the destination client. More
  language and library targets remain future increments.
- OpenAPI export. Selected flows can be exported as deterministic OpenAPI 3.0 YAML. The bounded
  document records observed servers, paths, methods, query names, response statuses, media types,
  and inferred JSON schemas while omitting header values and body examples. Unsupported methods
  fail explicitly; raw bodies remain available through the existing HAR/session exports.
- Inspector clipboard and responsive navigation. The native flow menu copies URL, request/response
  headers, bounded text-or-base64 bodies, cookies, or cURL from immutable flow data. Request and
  response section controls use full segmented labels when they fit and compact native popup menus
  when they do not, without forcing asymmetric message panes.
- Custom Filter presets remain in the app/UI boundary. `TrafficDisplayFilter` is a codable value,
  while a native `UserDefaults` adapter stores a versioned document with at most 50 validated
  presets. Applying a preset replaces the complete display-filter value through the existing view
  model, so row projection and selection invalidation remain deterministic. These preferences do
  not enter GRDB sessions, portable captures, or the Core domain.
- Script runtime foundation. `ProxyLensCore` defines bounded request/response execution values and
  the `ScriptExecutor` port. `ProxyLensPlatform` evaluates synchronous `onRequest(context)` and
  `onResponse(context)` handlers with JavaScriptCore in a short-lived worker mode of the signed app
  executable. Every invocation gets a fresh context; the only injected capability is bounded
  logging. Source, headers, body, logs, input/output files, and execution time are explicitly
  limited, worker files are owner-only, and malformed or oversized output is rejected by native
  validation. No file, network, module, environment, Keychain, or native-object bridge is exposed.
  Matching request/response header and body script rules execute serially and apply the final valid
  mutation before forwarding. Header scripts run away from the event loop with no body access,
  preserve native framing headers, validate rewritten targets, and reject returned bodies. Request
  forwarding stays inside the existing pending-request bound; response reads pause and use a bounded
  queue until normal backpressure resumes. WebSocket handshakes reuse those header phases and expose
  semantic `ws`/`wss` URLs plus ordinary headers while the native bridge retains upgrade-critical
  method, status, Host, key/accept, subprotocol, extension, and Connection/Upgrade fields. Invalid
  handshake mutations fail open per script. Body scripts continue to require bounded,
  identity-encoded UTF-8 content. Execution failures, unsupported encodings, non-UTF-8 or oversized
  bodies, and streaming responses fail open and add explicit rule traces; captured client/upstream
  bytes remain authoritative. Successful bounded `context.log(...)` output is stored only on the
  owning local rule trace, is searchable, and is shown in the flow's Rules inspector without
  entering global diagnostics. The Rules window creates and edits all four HTTP script phases with
  phase-aware templates, muted JavaScript highlighting, accessible source-size feedback, and the
  runtime's existing 64 KiB source limit. A standalone streaming console remains a future increment.
- Richer decoders and request builders. Bounded JSON/Tree, XML, URL-encoded Form, multipart
  form-data, GraphQL request inspection, and bounded GraphQL operation discovery are implemented.
  Request and response panes also provide a 64 KiB-bounded offset/hex/ASCII view of authoritative
  captured bytes, independent of content type or content encoding. A native ImageIO Preview also
  recognizes macOS-supported raster formats from identity/gzip/deflate bodies, caps encoded and
  decoded input at 16 MiB, and creates a first-frame thumbnail no larger than 2,048 pixels away from
  the main actor. It displays format, dimensions, frame count, and capture metadata without changing
  raw bytes or the behavior of Body, Hex, Raw, export, and replay.
  The traffic table, search, and content filter consume persisted GraphQL operation metadata;
  shared rules can match operation kind/name and create request-body GraphQL breakpoints, local
  block rules, Map Local fixtures, or Map Remote destinations from the flow table. Operation-aware
  Map Remote keeps the captured client URL authoritative while updating the displayed connection to
  the actual mapped upstream. Replace Body can target a selected host/path or a discovered GraphQL
  operation, preload a bounded local file, and replace request or response bytes with corrected
  framing headers. Request replacement keeps the captured client request authoritative; response
  replacement keeps the captured upstream response authoritative while returning the selected body
  to the client. Client-visible Redirect rules can also be created from a selected host/path; they
  return a local 307 with an absolute HTTP or HTTPS `Location` and never open the original upstream.
  The inspector also includes a compact JSONPath/jq query surface over the derived JSON
  representation. JSONPath supports root, object-key, array-index, quoted-key, and wildcard
  selectors. The jq mode uses a purpose-built in-process parser rather than an external executable;
  its documented subset supports traversal, iteration, pipelines, and scalar `select` comparisons.
  Both modes enforce explicit input, query-complexity, expansion, depth, and rendered-output limits;
  captured bytes remain authoritative. Declared
  Protobuf bodies have a read-only schema-less wire view for varint, fixed32, fixed64, string,
  nested-message, and bounded byte-preview values. Users can import a compiled
  `google.protobuf.FileDescriptorSet` and choose request and response root message types to add
  field names, declared scalar types, enum labels, nested schemas, and packed repeated values. The
  Foundation-only descriptor reader avoids executing generated code and rejects malformed,
  duplicate, oversized, or excessively nested untrusted schemas. The last valid descriptor and
  selections are stored locally in Application Support; failed replacements do not damage them.
  Payload decoding runs away from the main actor with 1 MiB input and rendered UTF-8 limits,
  10,000 decoded fields or packed elements, and 16 nested levels. Native `application/grpc` and
  `application/grpc+proto` bodies decode repeated length-prefixed messages, cap inspection at 1,000
  messages, and honor explicit gzip/deflate `grpc-encoding` per message; unsupported compression is
  shown without guessing. Declared Protobuf bodies with `delimited=true` decode one or more
  varint-length-prefixed messages using the same selected schema. Binary and text gRPC-Web media
  types decode 5-byte data frames and terminal trailer frames; text mode accepts standard whole-body
  base64 and concatenated independently padded chunks. Compressed gRPC-Web frames are summarized
  without guessing message compression. All framed modes share the 1,000-message cap and malformed
  frames fail closed while raw bytes remain available. The WebSocket inspector can explicitly
  decode a complete binary message as one schema-less or descriptor-backed message after bounded
  fragmentation and negotiated `permessage-deflate` decoding, choosing the request/response schema
  from message direction. Groups and Google well-known-type presentation remain future increments.
- Request-composer workflows; raw HTTP/HTTPS Compose, Repeat, Edit & Repeat, bounded clipboard cURL
  import, local named presets, and bounded recent history are implemented. Composer entries are
  stored as a UserDefaults convenience cache rather than authoritative session data. Live
  WebSocket text/binary composition is also implemented, including reconnecting a historical flow
  and optionally replaying one bounded reconstructed message to a fresh upstream connection.
- Session organization, annotations, and improved search.

### P2 — expansion beyond desktop proxying

- Mobile device capture.
- Transparent proxy or VPN-based routing.
- HTTP/3/QUIC investigation.
- Collaboration and cloud synchronization.
- Team accounts, hosted storage, and optional telemetry.
- App Store distribution if the entitlement and sandbox model are acceptable.

P0, P1, and P2 are all product targets. Delivery remains staged so protocol and platform expansion builds on a reliable local desktop data plane instead of weakening it.

## P0 definition of done

The first architecture milestone is complete when a developer can:

- Start ProxyLens and configure a local desktop proxy.
- Install or trust the generated local CA with clear guidance.
- Capture HTTP and HTTPS traffic from a macOS application.
- See flows in a responsive three-pane native console.
- Inspect headers, raw bodies, and derived JSON views without losing bytes.
- Search and filter flows.
- Map a request to a local file or another remote URL.
- Pause and edit a request or response.
- Block or allow traffic with a rule.
- Export a flow as HAR or cURL.
- Stop capture and restore the previous proxy state safely.
- Reopen a saved session and inspect its raw data without a network connection.

## Alternatives considered

### Electron or Tauri

These could accelerate a cross-platform UI, but they add a browser/webview layer to a product whose primary UX is a dense native debugger. They also complicate native system integration and increase runtime footprint. They remain viable only if cross-platform support becomes a first-class requirement.

### Rust core with a Swift UI

Rust could provide an excellent proxy core, but it creates a cross-language FFI boundary exactly where certificate handling, event streams, storage, and debugging need to move quickly. It is a possible later optimization, not the right default for the first product slice.

### Network Extension as the starting point

It would support more transparent routing scenarios, but it adds entitlements and lifecycle complexity before the basic desktop proxy workflow is proven. Start with an explicit local proxy and revisit it for mobile or transparent capture.

### URLSession or a high-level HTTP client

These are appropriate for ordinary outbound requests, not for the interception boundary. The proxy needs raw protocol control and streaming semantics, so the core should stay on SwiftNIO.

## Source references

- [SwiftNIO](https://github.com/apple/swift-nio) — asynchronous networking foundation and protocol modules.
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite toolkit, migrations, WAL, observation, and FTS support.
- [Swift 6 migration guidance](https://www.swift.org/migration/) — language-mode and concurrency-safety direction.
- [swift-certificates](https://github.com/apple/swift-certificates) — X.509 certificate creation and serialization.
- [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services/) — secure storage for keys and certificates.
- [Apple Network Extension](https://developer.apple.com/documentation/networkextension) — deferred transparent/VPN capture surface.
- [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) — future login-item/helper integration.
- [Apple macOS distribution preparation](https://developer.apple.com/documentation/Xcode/preparing-your-app-for-distribution) — signing, Hardened Runtime, sandbox, and distribution constraints.
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — direct-distribution trust workflow.
- [Protocol Buffers `MessageLite`](https://protobuf.dev/reference/java/api-docs/com/google/protobuf/MessageLite.html) — varint-length-prefixed delimited-message contract.
- [gRPC over HTTP/2 framing](https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html) — native 1-byte flag plus 4-byte length envelope.
- [gRPC-Web protocol](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md) — binary/text media types, trailer-frame flag, and base64 transport behavior.
