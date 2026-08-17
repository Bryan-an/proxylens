---
name: add-console-feature
description: Use when adding or changing anything the ProxyLens traffic console displays or controls — a new column, filter, inspector tab, source-list group, toolbar action, or piece of flow state. Covers the snapshot-and-render path that spans TrafficConsoleModels, TrafficConsoleViewModel, an AppKit controller, and the integration tests.
---

# Add a Traffic Console Feature

Every console surface flows one direction: **service → view model state → immutable snapshot → `render(_:)` → AppKit view**. Controllers never query services and never hold state the snapshot doesn't carry. New UI that skips a step works until the next snapshot arrives and silently reverts.

## The four edits

### 1. Snapshot — `TrafficConsoleModels.swift`

Add the field to `TrafficConsoleSnapshot` (it is `Equatable, Sendable` — keep the new type both). If the value derives from captured flows, compute it in `TrafficConsoleStore.snapshot(...)` alongside `domainSummaries`/`visibleRows`. If it is view-model-owned state (capture status, certificate trust, a warning), pass it into that call instead — see how `capture:` and `certificateTrust:` are threaded.

Extend `TrafficConsoleSnapshot.initial` so an empty console still renders.

### 2. View model — `TrafficConsoleViewModel.swift`

- State lives on the view model or in `TrafficConsoleStore`; mutators end by calling `publishSnapshot()`. Display-filter changes go through `updateDisplayFilter { $0.field = value }` so selection and body tasks are reconciled.
- A new service dependency is declared as a narrow `Traffic*` protocol in this file, with the concrete `ProxyLensApplication` type conformed by `extension` right beside it, and injected through `init` as an optional. This is what lets tests build the console without a proxy or database — never import and call a service type directly.
- Async work goes in a `Task` you store and cancel on flow reselection, following `bodyTask` / `webSocketFrameTask`.

### 3. Controller — the matching file in `UI/TrafficConsole/`

Render inside that controller's existing `render(_ snapshot:)`; `TrafficConsoleViewController.render(_:)` already fans the snapshot out to the source list, flow table, inspector, and filter bar. Add child controllers there if the surface is new.

Every control gets `setAccessibilityIdentifier(_:)` using the dotted convention (`traffic.filter.method`, `inspector.summary.url`, `inspector.split.messages`) plus `setAccessibilityLabel(_:)` when the identifier isn't self-describing. Tests find views only by identifier.

Layout: an axis chain must have exactly one view that absorbs slack. Give fixed rows `setHuggingPriority(.defaultHigh, for: .vertical)` (stack views) or `setContentHuggingPriority` so the content view stretches instead of a one-line bar.

### 4. Integration test — `Tests/ProxyLensIntegrationTests/ProxyLensIntegrationTests.swift`

Build the view model with the existing private actor doubles at the bottom of the file — `RecordingCaptureController`, `FinishedEventSource`, `InlineBodyReader`, `StaticWebSocketFrameLoader`, `RecordingSessionService`, `TrackingTrafficBodyReader`. Add a new double only when no existing one fits.

```swift
let viewModel = TrafficConsoleViewModel(
    captureController: RecordingCaptureController(),
    eventSource: FinishedEventSource(),
    bodyReader: InlineBodyReader(),
    captureConfiguration: Self.captureConfiguration,
    eventBatchDelay: .seconds(60)          // batching never fires on its own
)
await viewModel.prepare()

let flow = try Self.makeFlow(index: 1, host: "example.com", statusCode: 200)
viewModel.receive(.finished(flow))
viewModel.flushPendingEvents()             // publish deterministically
viewModel.selectFlow(flow.id)
```

Then assert on rendered AppKit state, locating views with `Self.descendant(of:in:matching:)` and the accessibility identifier. For anything geometric, put the controller in a real window first:

```swift
window.contentViewController = controller
controller.view.frame = NSRect(origin: .zero, size: frame.size)
window.makeKeyAndOrderFront(nil)
try await Task.sleep(for: .milliseconds(100))
window.contentView?.layoutSubtreeIfNeeded()
```

Values that arrive asynchronously (decoded bodies, frame payloads) need `try await waitUntil { ... }` rather than a fixed sleep.

## Finish

New file under `ProxyLensApp/` or `Tests/`? Run `xcodegen generate` and commit the regenerated project — the pbxproj lists sources individually.

Then verify with `/verify`, and consider `appkit-layout-reviewer` for constraint-heavy changes.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Controller keeps its own copy of state | Reverts on the next snapshot; the two disagree under filtering |
| Controller calls a service directly | Untestable, and reintroduces the dependency the `Traffic*` seam removes |
| New control without an accessibility identifier | Cannot be asserted on; the surface ships untested |
| Renaming an existing identifier | Breaks integration tests that look it up — grep the test file first |
| Default `eventBatchDelay` in a test | 40 ms batching makes the test time-dependent and flaky |
| Field added to the snapshot but not to `.initial` | Empty-console render breaks or the type won't compile |
