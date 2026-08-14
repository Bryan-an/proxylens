# ProxyLens technical stack

**Status:** Recommended architecture
**Scope:** macOS-only native experience; desktop proxying first
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
- A codebase that can later add HTTP/2, scripting, mobile capture, and collaboration without replacing the core domain model.

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
| WebSocket | `NIOWebSocket` | Required for inspecting and eventually replaying WebSocket upgrades and frames. |
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
- `NIOWebSocket` — WebSocket upgrade and frame handling.
- `NIOSSL` — TLS client/server channels and certificate configuration.

Add later, when the product has a stable HTTP/1.1 capture path:

- `NIOHTTP2` for HTTP/2 inspection and proxying.
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

HTTP/2, HTTP/3/QUIC, transparent VPN capture, and mobile-device routing are later milestones. They should not complicate the first reliable desktop proxy.

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
- Explain how to trust it in macOS Keychain Access, or automate the supported step only after the security and UX behavior is understood.
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
- Tags, comments, folders, and user annotations.
- Rule definitions and rule execution results where persistence is needed.
- Saved filters and view preferences.
- FTS5 indexes for URLs, headers, and selected text fields.

### Filesystem stores

Use a managed application-data directory for:

- Request and response bodies above a small inline threshold.
- WebSocket frame payloads.
- HAR/session export staging files.
- Optional decoded artifacts if they are expensive to recompute.

Each body reference should include size, content hash, encoding information, and a cleanup policy. The database record is authoritative for metadata; the file is authoritative for the corresponding raw bytes.

### Raw bytes are authoritative

The capture path should preserve raw bytes before decoding. JSON trees, XML views, form fields, GraphQL views, Protobuf decodes, pretty printing, search indexes, and syntax highlighting are derived representations.

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

Map Local, Map Remote, Breakpoint, Block/Allow, throttling, and no-cache behavior should share one rule pipeline instead of becoming separate special-case features.

Represent a rule as:

```text
Matcher + phase + action
```

Where:

- **Matcher** selects by host, path, method, query, headers, source, status, content type, or a composed expression.
- **Phase** identifies request headers, request body, response headers, response body, connection, or WebSocket frame processing.
- **Action** transforms, pauses, redirects, replaces, blocks, allows, throttles, or annotates the message.

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
- OSLog.
- ServiceManagement only when a helper or login item is introduced.

### Add only when a feature earns it

- HTTP/2 support through `NIOHTTP2`.
- Mobile/transparent routing through `NetworkExtension`.
- Protobuf/GraphQL decoders.
- JavaScript scripting runtime.
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
9. Add HAR and cURL export.
10. Package a Hardened Runtime Release zip; notarized GitHub Releases wait on a Developer ID.

### P1 — serious daily-driver debugging features

- WebSocket frame inspector and controls.
- HTTP/2.
- Throttling.
- Script hooks.
- Richer decoders and request builders.
- Repeat/Edit & Repeat workflows.
- Session organization, annotations, and improved search.

### P2 — expansion beyond desktop proxying

- Mobile device capture.
- Transparent proxy or VPN-based routing.
- HTTP/3/QUIC investigation.
- Collaboration and cloud synchronization.
- Team accounts, hosted storage, and optional telemetry.
- App Store distribution if the entitlement and sandbox model are acceptable.

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
