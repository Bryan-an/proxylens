# Proxyman feature investigation

**Snapshot:** 2026-07-31  
**Product version used as the current reference:** Proxyman macOS 6.14.0, released 2026-07-23  
**Purpose:** establish the product context and a practical parity target for ProxyLens.

**Roadmap scope:** P0, P1, and P2 are authorized product targets. Delivery remains staged: the
macOS desktop data plane comes first, followed by richer protocols/tools and then companion,
automation, and collaboration surfaces.

This is a public-surface investigation based on Proxyman's official website, user manual, pricing page, and changelog. It describes what the product exposes to users; it does not claim to reproduce Proxyman's private implementation.

## Executive summary

Proxyman is a local network-debugging platform centered on a man-in-the-middle proxy. Its core loop is:

```text
capture -> decrypt/parse -> inspect -> filter -> modify/replay/mock -> compare/export/share
```

The important product insight is that Proxyman is not only a request viewer. It combines five products in one workspace:

1. A proxy and TLS interception engine.
2. A searchable, persistent traffic notebook.
3. A rule engine for rewriting, blocking, mocking, throttling, and pausing traffic.
4. A protocol-aware inspector and API client.
5. A set of local and cloud integrations for automation, sharing, and team workflows.

The desktop app presents a three-part workspace: a source tree for apps/domains/devices, a flow list, and a request/response inspector. Almost every advanced tool follows the same pattern: define a URL/domain/app/protocol matcher, choose request or response phase, and apply a transformation or control action.

## Product surface and platform matrix

| Surface | What it provides | Clone implication |
| --- | --- | --- |
| macOS desktop | Primary native debugging workspace; HTTP/HTTPS capture, SSL decryption, rule tools, protocol viewers, sessions, exports, CLI, and MCP | Best first target for full parity |
| Windows/Linux desktop | Desktop Proxyman distribution; the official overview describes this surface as Electron-based | Can follow the same engine/UI contracts later |
| iOS app | Standalone local-VPN capture on iPhone/iPad; inspection, filtering, local rules, and log sharing without a Mac | Separate mobile capture product, not merely a remote desktop client |
| Android app | Standalone local-VPN capture on Android 30+; no root required; inspect, compose/replay, filter, and export | Separate Android VPN/certificate workstream |
| Remote iOS/iPadOS/tvOS/watchOS/Vision Pro | Physical-device proxy setup and certificate trust; simulators can be automated with Apple tooling | Device onboarding and certificate lifecycle matter as much as proxying |
| Android devices/emulators | Manual proxy/certificate setup plus an ADB-based automatic emulator script; Flutter/React Native emulator capture is supported in newer releases | Emulator automation is a major quality-of-life feature |
| Development environments | Automatic/manual setup for Node.js, Ruby, Python, Go, cURL, HTTPie, Java VMs, Rust, React Native, Flutter, Docker, Electron, browsers, and HTTP clients | Provide environment adapters instead of requiring every library to be configured manually |

Proxyman's official overview describes the macOS application as native and built around Swift NIO, while the current product site emphasizes Apple Silicon/macOS performance. The public product pages also advertise Windows, Linux, iOS, and Android distributions.

## Complete feature inventory

### 1. Capture, proxying, and transport

- Captures HTTP and HTTPS traffic from the local computer, apps, browsers, iOS devices/simulators, Android devices/emulators, and supported development environments.
- Acts as a man-in-the-middle server to decrypt TLS traffic after the generated CA is installed and trusted.
- Displays traffic grouped by client/app and domain, with remote devices represented in the source list.
- Starts/stops recording independently from the proxy state and can clear the current session without quitting.
- Can override the system HTTP/HTTPS proxy and restore the previous setting when the app exits.
- Includes a privileged Proxy Helper Tool for system proxy changes and related setup tasks.
- Supports an additional SOCKS5 listener for clients that do not respect ordinary HTTP proxy settings. HTTPS over SOCKS can still use Proxyman's debugging tools.
- Supports reverse proxy entries: a local HTTP server forwards to a remote host and the traffic becomes inspectable even when the client cannot be configured to use an HTTP proxy.
- Supports an upstream external proxy in HTTP, HTTPS, SOCKS, or PAC mode, with optional HTTP/HTTPS authentication and bypassed hosts.
- Includes DNS Spoofing rules that send a domain to another address while preserving the request URL and Host semantics; this is intentionally different from Map Remote.
- Parses SNI from TLS handshakes so traffic can be labeled with a hostname instead of only an IP address.
- Has experimental HTTP/2 support in the current release history. HTTP/3 is not advertised in the reviewed official material.
- Handles streaming/long-lived traffic, including WebSockets and Server-Sent Events. Large session bodies can be spilled to disk to reduce memory pressure.

### 2. TLS, certificates, and trust setup

- SSL Proxying List with include and exclude rules.
- SSL rules can match an app, domain, wildcard, or regular expression.
- One-click actions can enable SSL proxying for a selected app, domain, or flow.
- Bypass Proxy List prevents selected domains from using the Proxyman proxy; this is useful for noisy traffic and SSL-pinned hosts.
- Automatically generates a local root CA and provides installation/export flows for macOS, iOS, iOS simulators, Android, and other supported runtimes.
- Supports custom root, server, and client certificates in PEM/DER and PKCS#12 formats, including encrypted private keys.
- Client certificates can be selected for specific hosts/ports; server certificates are useful for clients that use SSL pinning in a controlled development environment.
- Provides TLS key logging for use with Wireshark.
- Stores certificate passphrases in the OS keychain according to the official certificate manual.
- Serves a local certificate-download page to mobile devices.
- Offers automatic iOS Simulator setup using `simctl`, manual drag-and-drop installation, and an Android emulator script that can override/revert proxy settings and install a system-level CA where supported.
- The iOS standalone app and Android standalone app each create a local VPN and keep captured data on-device. They do not require the desktop app for capture.
- Atlantis is an optional iOS framework for inspecting HTTP/HTTPS and WebSocket traffic without manually configuring a proxy or trusting a certificate. The official manual positions it as an inspection path; some desktop debugging tools require a normal proxy instead.

### 3. Main workspace and session navigation

- Three-pane layout: source list, flow list, and request/response content panel.
- Source categories for all apps, domains, clients/devices, pinned domains/apps, and saved folders.
- Pin working domains or apps to keep them visible and hide noisy traffic.
- Saved folders, including subfolders in newer releases, for organizing flows.
- Multiple workspace tabs with Safari-like keyboard navigation.
- Auto-follow behavior for new flows and a recording toggle.
- Clear Session removes current flows, domains, and clients and is also a memory-management action.
- Select, delete, duplicate, export, and operate on single or multiple flows.
- Highlight flows with red, yellow, green, blue, purple, or gray; add comments; apply strikethrough; filter by color/comment; and preserve those annotations in Proxyman log exports.
- A Tools column shows which debugging tools affected a flow.
- App details popover can expose codesign information, bundle ID, and app path.
- Custom table columns can be derived from request/response headers. Columns support sorting, resizing, reordering, visibility, and persistence.
- Custom GraphQL query/operation name column.
- Customizable toolbar with buttons for proxy, block/allow list, breakpoint, Map Local/Remote, reverse proxy, throttling, and scripting.
- Horizontal, vertical, or detachable request/response panels; source-list collapse/expand.
- Light/dark appearance, monospaced font setting, localization, and persistent workspace settings.
- Command Palette with fuzzy search, keyboard execution, and pinned favorite actions.
- Quick Preview for selected text: inline JSON beautification, Base64 decoding, key/value table display, and JWT decoding.
- Chart View for timing analysis with zooming.
- Timing breakdown including connection and TLS-handshake phases.
- Response-failure popovers, searchable body panels, copy actions, and external-editor opening.

### 4. Request and response inspection

The standard inspector exposes separate views for:

- Request/response headers as key-value tables.
- Cookies, `Set-Cookie`, and authentication values.
- Query parameters and form fields.
- Body content with automatic formatting based on content type.
- Raw HTTP message, including trailers when present.
- JSON and native JSON Tree View.
- Hex and binary data.
- Images such as PNG/GIF/JPG, including image metadata and inline Base64 images.
- HTML rendered in a web view.
- XML prettification with indentation and expand/collapse.
- CSS, JavaScript, HLS/M3U8, and other text syntax highlighting/beautification.
- URL-encoded and multipart/form-data bodies; multipart parts can be displayed in a table and edited in scripting/breakpoint flows.
- JWT decoding and human-readable timestamp helpers.
- Protocol Buffers and MessagePack.
- GraphQL query prettification.
- Server-Sent Events in realtime.
- An SSE/OpenAI tab that prettifies event JSON and can accumulate OpenAI-style streamed content into a final readable view.
- Rendered Markdown in custom preview tabs.

Custom Previewer Tabs can force a decoder regardless of the HTTP `Content-Type`, create persistent per-workspace tabs, and use a script to render a custom view. This is an important extensibility point rather than just a UI preference.

JSON-specific inspection includes text search, regular expressions, JSONPath, key-path lookup, all-key/all-value search, and `jq` expressions.

### 5. Filtering and matching

The filter system has a fast primary filter plus composable secondary filters.

Primary categories include:

- All, HTTP, HTTPS, WebSocket, JSON, XML, form, JavaScript, CSS, document/HTML, media, font, other, and GraphQL.
- Status ranges: 1xx, 2xx, 3xx, 4xx, and 5xx.

Secondary filter fields include:

- URL, host, query string, method, request headers, response headers, request/response body, status code, comment, color, duration, and body size.
- Header/value filtering, for example `Content-Type: application/json`.
- Contains, not contains, starts with, ends with, equals, not equals, and regular expression matching.
- AND/OR combinations across multiple filters, with saved/custom filter buttons.
- Full-text search and match highlighting inside content views.
- Case-sensitive filtering in newer releases.
- Header, query, auth, and form filters inside the selected flow's content panels.
- GraphQL query-name matching.

Rule matching is shared across tools. It supports exact values, simple wildcards (`*` and `?`), regular expressions, and a rule-testing window. Matching can target URL components, apps, domains, headers, methods, protocols, and GraphQL operation names.

### 6. Traffic transformation and control tools

#### SSL Proxying

Decrypt only selected apps/domains or exclude selected traffic. This is a gate for readable HTTPS content and for many later tools.

#### Breakpoint

Pause an in-flight request, an incoming response, or both. The editor can change:

- Scheme, host, port, path, query, and HTTP method.
- Request/response headers.
- Authorization, Cookie, and Set-Cookie values.
- Form and JSON fields.
- Request/response bodies, multipart content, and raw messages.
- Response status code.

Breakpoint actions are Continue/Cancel, Abort, and Execute. The rule can be matched by URL or GraphQL query name, and breakpoint templates can be reused for request method/URL/headers or response status/headers.

#### Map Local

Return a local file or an inline response instead of the server response. It supports text, JSON, binary, and images, plus custom status code, headers, and body. A rule can be generated from an existing flow. Directory mapping resolves URL paths into a local directory and can fall back to the real server when a local file is absent.

#### Map Remote

Rewrite the destination scheme, host, port, path, or query. It supports HTTP-to-HTTPS, HTTPS-to-HTTP, WebSocket-to-secure-WebSocket mappings, nested folders, GraphQL operation matching, wildcard/regex rules, and an option to preserve the original Host header.

#### Scripting / Rewrite

Run JavaScript on request and response phases. A script can implement Map Local, Map Remote, Breakpoint, mock APIs, abort/block behavior, header/query/body changes, file-backed responses, GraphQL matching, and annotations. The current scripting surface includes:

- `onRequest` and `onResponse` handlers.
- JSON, form, plain-text, binary, `Uint8Array`, and multipart body handling.
- Shared state between scripts and environment variables.
- Built-in snippets and addons for Base64, hashing, UUID, JWT, compression, encryption, regex, URL handling, file I/O, logging, and response delay.
- Async HTTP requests from scripts.
- Custom JavaScript addons and npm-style `require(...)`/package installation in newer versions.
- VS Code editing support, a scripting console, and custom preview tabs.
- Optional mock mode where the upstream server is never called.
- WebSocket URL and header rewriting; the reviewed manual explicitly says WebSocket message payload rewriting is not supported by scripting.

#### Block List

Rules can block or hide by domain, wildcard, URL, or app. Actions are:

- Block and hide.
- Block and display.
- Hide without blocking.

Blocked traffic can be shown as gray flows in newer versions, and an app-wide block rule is supported.

#### Allow List

Only matching domains/requests are allowed through Proxyman; unmatched traffic bypasses the proxy. This keeps a session focused on a small set of debugging targets.

#### No Caching

Modify caching headers to force fresh traffic. Request validators such as `If-Modified-Since` and `If-None-Match` are removed; `Pragma`/`Cache-Control: no-cache` are added; response cache headers are replaced with no-cache equivalents.

#### Network Conditions

Apply presets such as lost connection, very bad, slow, medium, 2G, 3G, 4G, Wi-Fi, and fast Wi-Fi. Conditions can simulate upload/download bandwidth, latency, and packet loss, system-wide or for selected domains. Recent releases add saved custom throttling profiles.

### 7. Replay and request composition

- Repeat a captured HTTP/HTTPS request with its headers and body; multiple requests can be repeated, and recent releases allow batches up to 20.
- Edit & Repeat a captured request while preserving its URL, query, headers, and body.
- Compose requests from scratch with presets for empty, GET/query, JSON POST, form POST, and multipart POST.
- Edit method, URL, query, headers, JSON/form/multipart body, and raw message.
- Import cURL to populate a composed request.
- Keep request history and reuse previous request/response entries.
- Bulk-edit/paste multiple headers and parameters.
- Configure request timeout and redirect-following behavior.
- Compose WebSocket connections, edit/send messages, resize the compose panel, and inspect the response without changing tools.

### 8. WebSocket and realtime debugging

- Capture WS and WSS from browsers, desktop apps, Node.js, Python, Go, Ruby, iOS, and Android.
- Show realtime frames and separate sent/received/all message views.
- Display frame number, length, data, and time columns.
- Prettify JSON; show Tree and HEX views; auto-decode binary JSON where possible.
- Handle Socket.IO and continuous frames.
- Decode WebSocket Protobuf in raw mode or with a descriptor/message type.
- Decompress supported compressed payloads such as gzip/deflate/zstd.
- Export WebSocket messages.
- Map WebSocket destinations with Map Remote.
- Breakpoint WebSocket responses in newer releases.
- Script WebSocket URLs and headers; message payload mutation is explicitly not part of the current scripting manual.

### 9. GraphQL and Protobuf

GraphQL support is based on recognizing an operation/query name inside a request rather than relying only on a shared endpoint URL. The name can be displayed as a column and used by Breakpoint, Map Local, Map Remote, Block/Allow List, and Scripting. GraphQL query text can be beautified.

Protobuf support includes:

- HTTP/HTTPS and WebSocket payload decoding.
- `.desc` descriptor files, proto2/proto3, Google common types, and message-type autocomplete.
- Raw decode without a schema and typed decode with a schema/message type.
- Single-message and length-delimited/multiple-message payloads.
- Separate request and response message types.
- Content-Type parameters such as message type and delimited mode.
- Improved gRPC/Protobuf reliability in recent releases.

### 10. Compare, generate, and document APIs

- Diff two requests or responses, including URL, method, status, headers, and text bodies.
- Side-by-side or unified diff layout, light/dark GitHub-style themes, unified export, comments/highlights, and external diff tools such as FileMerge/Kaleidoscope.
- Code Generator for cURL, HTTPie, HAR, Postman Collection 2, Axios, Go, Java HttpClient, JavaScript/jQuery, Node HTTP, Node Fetch, Python Requests, Objective-C `NSURLSession`, Swift URLSession, Swift Alamofire, Swift Moya, and newer Dart/Flutter formats.
- Export captured traffic to OpenAPI 3.0 YAML or built-in Swagger-style HTML.
- Copy URL, cURL, cell value, cookies, headers, body, and Markdown table representations.
- Publish selected traffic to a private or public GitHub Gist using a keychain-protected GitHub authorization.

### 11. Persistence and interchange

Import:

- Proxyman Log and Proxyman Session files.
- HAR 1.2.
- Charles `.chls`, `.chlsj`, and newer `.chlz` files.
- CSV and Postman Collection 2 where applicable.

Export:

- Selected flows, all traffic, a client/app/domain/device node, or an entire session.
- Proxyman Log v2, Proxyman Session v2, HAR, CSV, raw request/response, body-only, and Postman/OpenAPI artifacts.
- WebSocket message files.

Import/export also exists for debugging-tool settings. Settings can be moved between Proxyman installations and imported from Charles for SSL Proxying, Block/Allow List, Map Local, Map Remote, Breakpoint, Network Conditions, and Scripting where supported.

The session model includes flows, apps/domains, and remote devices. Current releases also compress log files more efficiently and spill large bodies to disk.

### 12. CLI, Raycast, MCP, and team features

#### `proxyman-cli`

The official CLI can export/import rule configuration, append or replace rules, activate/unlink a license, toggle the system proxy, clear sessions, toggle tools, install the helper tool, export logs as Proxyman/HAR/raw, export from a flow ID onward, install/manage custom certificates, toggle external proxy/PAC modes, and report the current listening IP/port. Newer releases also expose tool open/on/off commands.

#### Raycast

The Raycast extension can toggle system proxy, Map Local, Breakpoint, Block/Allow List, Map Remote, Scripting, External Proxy, SOCKS Proxy, Network Conditions, SSL Proxying List, recording, and Clear Session.

#### MCP

Proxyman MCP has two local components: an HTTP server inside the app and a stdio CLI server for MCP clients. The documented tools can:

- Read version, proxy status, flows, flow details, rules, SSL lists, and certificate status.
- Create Breakpoint, Map Local, Map Remote, Block List, and SSL Proxying rules.
- Clear sessions and toggle recording.
- Filter flows and export cURL.
- Open/quit the app.
- In newer releases, manage rules for all debugging tools, install/uninstall certificates, launch injected terminals, and export HAR/Proxyman logs.

The documented security model binds to localhost, uses a per-session cryptographic token, stores the handshake file owner-only, and redacts sensitive values in tool responses.

#### Team Workspace

Team/cloud features are separate from the local capture engine:

- Sign-in, seat/license management, and role-based access.
- Backup/sync of app settings and debugging-tool settings across devices.
- Upload `.proxymanlogv2`, `.proxymansessionv2`, and `.har` files for browser review.
- Notes with Markdown, renaming, download/delete, and share links.
- Private, team, specific-user, and public sharing.
- Sensitive-data redaction for cookies and Authorization headers before upload.
- Admin/developer/viewer-style permissions and team management.
- Current product pages advertise 10 GB of team log storage; the sharing manual documents a 50 MB per-upload limit.
- Rule synchronization and SSO are listed as future/team roadmap items in the reviewed pricing page, so they should not be treated as core local parity.

## How the product behaves as a system

The following architecture is an inference from the public feature behavior, not a claim about Proxyman's private code:

```text
client / device / app
          |
          v
proxy listeners (HTTP, HTTPS CONNECT, SOCKS, reverse proxy, local VPN adapters)
          |
          v
TLS termination + certificate manager + protocol parsers
          |
          v
normalized Flow / Request / Response / Stream model
          |
          +--> request rule pipeline: SSL gate, allow/block, breakpoint,
          |    map remote, scripting, throttling, no-cache
          |
          v
upstream server or local mock/file
          |
          +--> response rule pipeline: breakpoint, map local, scripting,
          |    throttling, decoders, annotations
          |
          v
streaming session store --> UI, exporters, CLI, MCP, workspace sharing
```

ProxyLens should treat these as first-class domain objects:

- `Session`: recording state, flows, source tree, saved folders, annotations, and settings.
- `Source`: app, process, domain, device, or virtual source.
- `Flow`: one HTTP transaction or WebSocket/SSE stream, with timing and rule metadata.
- `Message`: request/response headers, body, raw bytes, trailers, and decoded representations.
- `Rule`: tool type, enabled state, matcher, phase, priority, and action.
- `Matcher`: URL components, method, headers, body, app/device, protocol, wildcard/regex, GraphQL name.
- `Decoder`: JSON, XML, HTML, image, form, multipart, MessagePack, Protobuf, GraphQL, SSE, Markdown, and raw/hex.
- `Artifact`: HAR, session, log, cURL, OpenAPI, code-generated request, diff, or shared log.
- `CertificateProfile`: generated/custom root, client, and server certificates plus trust/install state.

The most important boundary is between raw bytes and decoded views. The raw message must remain authoritative; every JSON/tree/Protobuf/GraphQL/SSE view should be a derived representation. This prevents a decoder or formatter from corrupting the bytes that are later exported or replayed.

## Free clone strategy for ProxyLens

The commercial product has a large surface area. ProxyLens targets the complete staged roadmap
below while prioritizing the workflow that creates daily value. “P0,” “P1,” and “P2” describe
dependency order, not excluded scope or paid feature tiers.

### P0: useful local desktop proxy

- Local HTTP/HTTPS MITM proxy with explicit start/stop/recording state.
- Generated root CA, install/export instructions, and per-domain SSL Proxying rules.
- Three-pane flow workspace with app/domain grouping, a persistent Source List visibility toggle,
  and persistent pinned domains.
- Request/response headers, query, cookies, raw message, body, bounded captured-byte Hex, native
  image Preview with metadata, JSON pretty/tree view, and search.
- Primary URL/status/content-type filters plus full-text search.
- HAR import/export and a native local session format.
- Clear/save session, pin/folder organization, comments, and flow annotations.
- Map Local, Map Remote, Breakpoint, Block/Allow List, and No Caching.
- cURL copy and Repeat/Edit & Repeat.

### P1: differentiated debugger

- Compose tool with cURL import, JSON/form/multipart/raw editing, reusable local presets, bounded
  recent history, and WebSocket compose. ProxyLens provides the HTTP/HTTPS composer plus a native
  live WebSocket composer for UTF-8 text and Base64 binary frames in either direction. Historical
  WebSocket flows can open a fresh `ws://` or verified `wss://` connection, optionally replay one
  bounded reconstructed text/binary message toward the server, and continue composing on the new
  replay flow without changing the original capture.
- WebSocket frame capture and inspection now covers HTTP and intercepted HTTPS upgrades, live
  sent/received frame metadata, bounded latest-frame presentation, and lazy formatted JSON, text,
  Protobuf, or hex payload display. Auto and Protobuf reconstruct complete text/binary messages
  across continuation frames and interleaved control frames. Negotiated `permessage-deflate`
  messages are decompressed with direction-specific context/window parameters and explicit input,
  history, and output limits. Binary messages apply request/response descriptor selections by
  direction, while Hex always shows the authoritative bytes of the selected frame. The Frames view
  now filters All/Sent/Received traffic, searches bounded text payloads, exports the complete flow
  history in versioned local JSON, and composes bounded text or binary frames on the selected live
  connection. Closed/imported flows switch that action to Reconnect; the native editor seeds URL,
  headers, and a safe complete selected message, while explicit Connect, Connect & Replay, and
  Disconnect controls preserve every authored and received frame in the normal session history.
  WebSocket response breakpoints can pause incoming data frames before they reach the client. The
  Frames inspector permits bounded UTF-8 edits only for complete, uncompressed text frames;
  binary, fragmented, compressed, invalid UTF-8, and oversized payloads remain pauseable but
  read-only. Continue preserves transport-owned frame metadata, Abort closes both peers, control
  frames remain live, and the original upstream bytes remain authoritative in capture.
- Server-Sent Event capture and inspection now covers identity, gzip, x-gzip, and deflate
  `text/event-stream` responses with bounded incremental decoding and parsing, persisted
  event type/ID/retry/data, live latest-event
  presentation, bounded metadata/data search, lazy JSON formatting, and complete versioned export.
  The Events inspector can also build a searchable, copyable accumulated-text preview from
  recognized OpenAI Chat Completions and Responses API deltas. It derives only from the visible
  latest-500 history, reports omitted/ignored/safety-limited events, and bounds input to 8 MiB,
  each event to 256 KiB, and output to 1 MiB. Raw response bytes remain authoritative and unknown
  schemas remain available as individual events. Decoding failures and unsupported or stacked
  codings, including Brotli, leave the authoritative raw response inspectable and stop only the
  derived Events path.
- Intercepted HTTPS now negotiates downstream HTTP/2 with ALPN. Each HTTP/2 stream becomes an
  independent captured flow and uses the same rules, body storage, breakpoints, throttling, SSE,
  inspector, search, and export paths as HTTP/1.1. The connection advertises explicit concurrent-
  stream and header-list bounds, while clients that negotiate `http/1.1` or omit ALPN retain the
  existing TLS pipeline. Eligible HTTPS requests now negotiate `h2` upstream and multiplex through
  one origin connection per proxy event loop; concurrent first use shares one ALPN negotiation,
  closed parents are evicted, and capture shutdown closes every retained parent before its event
  loops. HTTP/1.1-only origins incur one probe per capture run and then use the existing dedicated
  transport from cached fallback knowledge. Client-facing protocol metadata remains independent of
  the upstream transport, while each flow records the observed upstream HTTP version and whether
  its HTTP/2 parent was newly established or reused. The Timing inspector presents those values
  explicitly and older/imported captures degrade to Unknown. WebSocket upgrades retain their
  dedicated HTTP/1.1 path; h2c, server push, connection coalescing, and RFC 8441 extended `CONNECT`
  remain later increments.
- GraphQL operation-name matching.
- Network throttling and request timing breakdown. ProxyLens currently provides removable,
  host-scoped latency-only presets plus Lost Connection, Very Bad Network, Slow 3G, Fast 3G, and
  Wi-Fi presets. Profiles can shape upload/download throughput with bounded backpressure and can
  deterministically fail a percentage of whole requests without corrupting HTTP framing. A native
  Custom editor creates one-off bounded host profiles for latency, bandwidth, and request loss; an
  optional profile name persists the settings locally for reuse from any flow, and saved profiles
  can be removed from the same menu. The bottom inspector now has a native
  Timing waterfall for request, connection, TLS, waiting, response, and finalization milestones,
  including truthful partial views for incomplete flows. Its Connection summary distinguishes
  client and upstream HTTP versions plus new/reused upstream sockets. Lower-level packet/segment
  loss is intentionally deferred because dropping arbitrary bytes would corrupt HTTP framing; DNS
  instrumentation and the zoomable cross-flow Chart View remain staged increments.
- Rule management. A compact header action opens a native table of the ordered live rule set with
  enabled state, action, phase, priority, and matcher scope. Any rule can be toggled without losing
  its identity or removed immediately. A native New Rule form creates Block, Allow, Breakpoint, and
  No Cache rules with compatible phases and all-traffic, host, path, method, content-type, or source
  matching using exact, wildcard, or regular-expression comparisons. Those native rule shapes can
  also be edited in place without changing stable rule identity or action-specific data. Rule shapes
  the form cannot represent remain visible but deliberately non-editable to prevent lossy rewrites.
  File-backed rule actions stay in contextual flow menus so their resources are validated and
  preloaded. The Rules sheet can save the complete active set as a durable named profile, apply a
  profile later, or delete it without changing the active rules. Profile archives include embedded
  Map Local resources, use stable identities for same-name updates, and are bounded to 50 local
  profiles and 64 MiB each. Portable `.proxylensrules` import and export use native file panels;
  imports validate schema and bounds and update local storage without silently applying live rules.
- DNS Spoofing is implemented as a connection-phase rule that maps an exact, wildcard, or regular-
  expression logical host to a validated IPv4 or IPv6 literal. HTTP/1.1, intercepted HTTPS,
  WebSocket, and upstream HTTP/2 sockets use the physical address while the original URL, `Host`
  header, TLS SNI, certificate validation identity, capture metadata, and exports remain logical.
  HTTP/2 connection identity includes both logical and physical destinations so differently routed
  rules cannot share a parent connection. The native Rules editor supports creation and editing,
  profiles/import/export preserve the action, and the flow context menu can seed an exact-host rule.
  ProxyLens does not modify macOS DNS settings or accept hostnames as spoof destinations.
- Reverse Proxy is available from the main toolbar as a native route manager. Each enabled route
  binds a numeric IPv4 or IPv6 loopback listener and forwards origin-form HTTP requests to one
  validated HTTP or HTTPS base URL. Routes persist locally, can be added, edited, enabled, disabled,
  or removed only while capture is stopped, and apply on the next capture start. Starting capture
  binds the forward proxy and all enabled reverse listeners atomically; any bind failure closes the
  listeners already opened. Reverse traffic is labelled by route and inherits the shared capture,
  rules, body storage, WebSocket upgrade, SSE, scripting, breakpoint, throttling, and upstream
  HTTP/2 paths while preserving the configured upstream `Host`, TLS SNI, and certificate identity.
  Current listeners are intentionally loopback-only and HTTP-facing; LAN exposure, local listener
  TLS, dynamic upstream selection, and load balancing remain later increments.
- A local SOCKS5 listener is available from the same compact Listeners manager. It is disabled by
  default, persists a numeric IPv4 or IPv6 loopback endpoint, locks while capture is active, and
  applies on the next capture start. The bounded no-auth negotiation accepts CONNECT destinations
  expressed as IPv4, IPv6, or domain names, then classifies the application bytes as HTTP or TLS.
  Both paths reuse the ordinary capture, rules, body storage, WebSocket, SSE, scripting,
  breakpoint, and upstream HTTP/2 pipeline while retaining the requested destination for URL,
  `Host`, SNI, certificate, and source identity. The forward, SOCKS5, and reverse listeners start
  atomically. Authentication, BIND, UDP ASSOCIATE, opaque TCP forwarding, and LAN exposure remain
  separate security-scoped increments.
- Custom Filters are available directly in the traffic filter bar. A preset stores the complete
  search, method, status, content-type, source, and annotation combination, then reapplies every
  facet atomically through the existing display-filter path. Presets can be saved, updated by name,
  renamed, applied, or deleted; stable identities and ordering survive same-name updates. The local
  versioned preference is bounded to 50 presets, validates names and search size, and fails closed
  for corrupt or unknown documents without changing captured sessions.
- Diff is available from a two-row traffic selection. The native comparison sheet aligns request
  or response start lines, headers, and decoded UTF-8 bodies side by side, keeps both panes scrolled
  together, and marks removals/changes in red and additions/changes in green. Body loading and the
  line-alignment matrix are bounded; oversized, binary, or unreadable payloads remain explicit
  metadata placeholders. The same sheet can switch to a syntax-colored unified diff, copy it, or
  atomically export the selected request/response comparison as a standard `.diff` file. External
  diff-tool handoff remains a future increment.
- Request code generation is available from a captured flow for cURL, HTTPie, JavaScript `fetch`,
  Axios, Python `requests`, Swift `URLSession`, Go `net/http`, and Java `HttpClient`. The native sheet switches among syntax-highlighted,
  copy-ready snippets while preserving text or binary request bodies and omitting transport-owned
  headers. Selected flows can also be exported as bounded, deterministic OpenAPI 3.0 YAML. The
  export describes observed paths, methods, query names, response statuses, media types, and
  inferred JSON shapes without copying header values or body examples. The inspector now includes
  a compact JSONPath/jq query surface over the derived JSON view. The in-process jq evaluator is a
  documented, side-effect-free subset for traversal, iteration, pipelines, and scalar `select`
  comparisons; input, query complexity, expansion, and rendered output are bounded. Remaining
  Proxyman generator targets and the wider jq language remain staged increments.
- The captured-flow context menu provides a Proxyman-style Copy submenu for URL, request/response
  headers, bodies, cookies, and cURL. Unavailable values are disabled, body reads are bounded, and
  binary bodies copy as base64 instead of lossy text. The bottom request/response selectors also
  preserve full tab names, independently falling back to a compact native menu when a split pane is
  too narrow. Both message panes expose a read-only Hex tab with offsets, grouped 16-byte rows, and
  printable ASCII over the authoritative captured bytes; output is capped at 64 KiB with an explicit
  omission notice. Both panes also expose a native read-only image Preview. ImageIO recognizes the
  raster formats supported by macOS (including PNG, JPEG, GIF, WebP, TIFF, and HEIC), builds only a
  bounded 2,048-pixel first-frame thumbnail from at most 16 MiB of decoded content, and shows format,
  dimensions, frame count, and capture metadata. Truncated, oversized, unsupported, or malformed
  bodies fail closed in Preview while Body, Hex, Raw, export, and replay retain the authoritative
  captured bytes.
- External upstream proxy configuration remains staged.
- Protobuf wire decoding is implemented for declared Protobuf bodies. The inspector keeps a
  schema-less mode and can also import a compiled `FileDescriptorSet`, restore it locally, and use
  independently selected request and response message types to render field names, scalar types,
  enum labels, nested messages, and packed repeated values. Descriptor parsing, decoded input, field
  counts, nesting, and rendered output are bounded; a failed import preserves the last valid local
  descriptor. Protobuf Content-Type values with `delimited=true` decode multiple varint-length-
  prefixed messages. Native gRPC bodies decode repeated 5-byte-framed Protobuf messages, including
  explicit gzip/deflate per-message compression; unsupported compression stays visible and does not
  trigger codec guessing. Binary and text gRPC-Web bodies decode data and terminal trailer frames,
  including independently padded base64 chunks in text mode; compressed frames are summarized
  without guessing. Complete binary WebSocket messages can also be explicitly decoded schema-less
  or with the direction's selected descriptor after bounded fragmentation and negotiated
  `permessage-deflate` decoding. Groups, Google well-known-type presentation, and MessagePack remain
  future increments.
- The constrained JavaScript scripting foundation is implemented with process-isolated,
  synchronous request/response handlers, a fresh context per invocation, bounded logging and I/O,
  a parent-enforced timeout, and native validation. It deliberately exposes no filesystem, network,
  module, environment, Keychain, or native-object bridge. Matching request/response header and body
  script rules now run serially before their corresponding message is forwarded, preserve the
  authoritative captured bytes, and fail open with a rule trace. Header scripts receive no body,
  preserve native framing fields, validate rewritten targets, and run within bounded request and
  response gates. WebSocket upgrades reuse those phases: request scripts receive a semantic
  `ws://`/`wss://` URL and may rewrite it plus ordinary headers, while response scripts may rewrite
  ordinary `101` headers. Method, status, Host, upgrade/security, subprotocol, and extension fields
  remain transport-owned, and invalid edits fail open per script without discarding prior valid
  mutations. WebSocket frame payload scripting remains unsupported. Body scripts can rewrite
  eligible bounded text messages; streaming, non-UTF-8,
  encoded, oversized, and invalid messages remain unmodified. Successful bounded
  `context.log(...)` entries now stay on the owning local rule trace, appear in the selected flow's
  Rules inspector, and participate in traffic search without entering global diagnostics. A native
  Rules editor supports all four HTTP script phases with safe templates, restrained JavaScript
  highlighting, edit round-tripping, and the runtime's 64 KiB source validation. A standalone
  streaming console, controlled local files, shared state, async HTTP, addons, and packages remain
  later capabilities.
- CLI for session/rule export and automation.

### P2: platform and collaboration expansion

- iOS and Android local-VPN apps.
- iOS Simulator and Android Emulator automatic onboarding.
- Runtime adapters for Node, Python, Ruby, Go, Java, Flutter, React Native, Electron, and Docker.
- Raycast/command-palette integrations.
- Local MCP server with strict redaction and opt-in write actions.
- Optional team log sharing, settings sync, and browser review.

### Recommended product principles

- Local-first: no traffic leaves the machine/device unless the user explicitly exports or shares it.
- Free by default: do not gate core capture, inspection, rules, or exports behind a license system.
- Explicit safety: show when TLS interception, recording, a rewrite rule, a block rule, or an upstream proxy is active.
- Reversible rules: every modified flow should show which rule ran and provide the original message where possible.
- Raw-byte fidelity: preserve encoded/compressed bodies and metadata alongside decoded previews.
- Streaming-aware storage: do not buffer an unbounded WebSocket/SSE/large response in memory.
- Testable engine: the rule pipeline and protocol parsers should run without the UI.
- Avoid shipping Proxyman branding, assets, or source code. Reproduce the user value and interoperable formats, while giving ProxyLens its own identity.

## Open product decisions

These decisions will materially affect implementation:

1. **First desktop target:** decided — macOS-first native experience; additional platforms remain
   separate follow-on products rather than a reason to weaken the native console.
2. **Core engine language:** choose based on TLS interception, async I/O, certificate tooling, and binary protocol libraries—not only UI convenience.
3. **Mobile scope:** decided — reliable desktop proxying first, then the P2 local-VPN companion
   apps and device onboarding.
4. **Scripting trust model:** no scripting initially, sandboxed JavaScript, or a fully extensible local runtime.
5. **Native session format:** use HAR as the first interchange format and add a richer local format only when annotations, rules, raw bytes, and streaming frames require it.
6. **Privacy posture:** define redaction, secret handling, retention, and export behavior before adding cloud or MCP features.

## Source map

All sources below are official Proxyman pages, reviewed for this snapshot:

- [Product overview](https://proxyman.com/)
- [Documentation overview](https://docs.proxyman.com/)
- [Pricing and feature comparison](https://proxyman.com/pricing)
- [Current macOS changelog](https://proxyman.com/changelog)
- [Request/response previewer](https://docs.proxyman.com/basic-features/request-response-viewer)
- [Content filters](https://docs.proxyman.com/basic-features/content-filter)
- [Import/export](https://docs.proxyman.com/basic-features/import-export)
- [SSL Proxying](https://docs.proxyman.com/basic-features/ssl-proxying)
- [Breakpoint](https://docs.proxyman.com/advanced-features/breakpoint)
- [Map Local](https://docs.proxyman.com/advanced-features/map-local)
- [Map Local directory](https://docs.proxyman.com/advanced-features/map-local-directory)
- [Map Remote](https://docs.proxyman.com/advanced-features/map-remote)
- [Compose](https://docs.proxyman.com/advanced-features/compose)
- [WebSocket](https://docs.proxyman.com/advanced-features/websocket)
- [GraphQL](https://docs.proxyman.com/advanced-features/graphql)
- [Protobuf](https://docs.proxyman.com/advanced-features/protobuf)
- [Scripting](https://docs.proxyman.com/scripting/script)
- [Automatic setup](https://docs.proxyman.com/automatic-setup)
- [Command line](https://docs.proxyman.com/command-line)
- [MCP](https://docs.proxyman.com/mcp)
- [iOS app](https://proxyman.com/ios)
- [Android app](https://proxyman.com/android)
- [Team log sharing](https://docs.proxyman.com/team-workspace/share-log-online)
