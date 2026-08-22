import AppKit
import Foundation
import ProxyLensApplication
import ProxyLensCore
import ProxyLensPlatform
import XCTest

@testable import ProxyLens

@MainActor
final class ProxyLensIntegrationTests: XCTestCase {
    func testIsolatedScriptWorkerExecutesAndTerminatesInfiniteLoops() async throws {
        let executableURL = try XCTUnwrap(Bundle.main.executableURL)
        let temporaryRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProxyLensScriptIntegration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRootURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryRootURL) }
        let finiteExecutor = ProcessJavaScriptExecutor(
            workerExecutableURL: executableURL,
            temporaryRootURL: temporaryRootURL
        )
        let finiteRequest = try ScriptExecutionRequest(
            hook: .request,
            source: """
                function onRequest(context) {
                  context.request.headers.push({ name: "X-Isolated", value: "true" });
                }
                """,
            message: ScriptHTTPMessage(method: "GET", url: "https://example.test/")
        )

        let finiteResult = try await finiteExecutor.execute(finiteRequest)

        XCTAssertEqual(finiteResult.message.headers.last?.name, "X-Isolated")

        let boundedExecutor = ProcessJavaScriptExecutor(
            workerExecutableURL: executableURL,
            timeoutMilliseconds: 75,
            temporaryRootURL: temporaryRootURL
        )
        let infiniteRequest = try ScriptExecutionRequest(
            hook: .request,
            source: "function onRequest() { while (true) {} }",
            message: ScriptHTTPMessage(method: "GET", url: "https://example.test/")
        )

        do {
            _ = try await boundedExecutor.execute(infiniteRequest)
            XCTFail("Expected the isolated script to time out")
        } catch {
            XCTAssertEqual(error as? ScriptExecutionError, .timedOut(milliseconds: 75))
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temporaryRootURL.path), [])
    }

    func testLineDiffAlignsModifiedAndAddedLines() {
        let rows = TrafficLineDiff.rows(
            left: "first\nsecond\nthird",
            right: "first\nchanged\nthird\nfourth"
        )

        XCTAssertEqual(
            rows,
            [
                TrafficDiffRow(
                    leftLineNumber: 1,
                    rightLineNumber: 1,
                    leftText: "first",
                    rightText: "first",
                    kind: .unchanged
                ),
                TrafficDiffRow(
                    leftLineNumber: 2,
                    rightLineNumber: 2,
                    leftText: "second",
                    rightText: "changed",
                    kind: .modified
                ),
                TrafficDiffRow(
                    leftLineNumber: 3,
                    rightLineNumber: 3,
                    leftText: "third",
                    rightText: "third",
                    kind: .unchanged
                ),
                TrafficDiffRow(
                    leftLineNumber: nil,
                    rightLineNumber: 4,
                    leftText: nil,
                    rightText: "fourth",
                    kind: .added
                )
            ]
        )
    }

    func testLineDiffFallsBackToBoundedPositionalComparison() {
        let rows = TrafficLineDiff.rows(
            left: "one\ntwo\nthree",
            right: "one\ninserted\ntwo\nthree",
            maximumMatrixCellCount: 1
        )

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].kind, .unchanged)
        XCTAssertEqual(rows[1].kind, .modified)
        XCTAssertEqual(rows[3].kind, .added)
    }

    func testNetworkConditionDraftBuildsBoundedProfileAndSupportsUnlimitedBandwidth() throws {
        let profile = try TrafficNetworkConditionDraft(
            latencyMilliseconds: " 250 ",
            downloadKibibytesPerSecond: "512",
            uploadKibibytesPerSecond: "128.5"
        ).profile()

        XCTAssertEqual(profile.latency, 0.25)
        XCTAssertEqual(profile.downloadBytesPerSecond, 524_288)
        XCTAssertEqual(profile.uploadBytesPerSecond, 131_584)
        XCTAssertEqual(profile.packetLossPercentage, 0)

        let lossy = try TrafficNetworkConditionDraft(
            latencyMilliseconds: "",
            downloadKibibytesPerSecond: "",
            uploadKibibytesPerSecond: "",
            packetLossPercentage: "12.5"
        ).profile()
        XCTAssertEqual(lossy, ThrottleProfile(packetLossPercentage: 12.5))

        let unlimited = try TrafficNetworkConditionDraft(
            latencyMilliseconds: "10",
            downloadKibibytesPerSecond: " ",
            uploadKibibytesPerSecond: ""
        ).profile()
        XCTAssertEqual(unlimited, ThrottleProfile(latency: 0.01))
    }

    func testNetworkConditionDraftRejectsInvalidLatencyAndBandwidth() {
        XCTAssertThrowsError(
            try TrafficNetworkConditionDraft(
                latencyMilliseconds: "60001",
                downloadKibibytesPerSecond: "512",
                uploadKibibytesPerSecond: "128"
            ).profile()
        ) { error in
            XCTAssertEqual(
                error as? TrafficNetworkConditionDraftError,
                .invalidLatency("60001")
            )
        }

        XCTAssertThrowsError(
            try TrafficNetworkConditionDraft(
                latencyMilliseconds: "10",
                downloadKibibytesPerSecond: "zero",
                uploadKibibytesPerSecond: "128"
            ).profile()
        ) { error in
            XCTAssertEqual(
                error as? TrafficNetworkConditionDraftError,
                .invalidBandwidth(field: "Download", value: "zero")
            )
        }

        XCTAssertThrowsError(
            try TrafficNetworkConditionDraft(
                latencyMilliseconds: "0",
                downloadKibibytesPerSecond: "",
                uploadKibibytesPerSecond: "",
                packetLossPercentage: "101"
            ).profile()
        ) { error in
            XCTAssertEqual(
                error as? TrafficNetworkConditionDraftError,
                .invalidPacketLoss("101")
            )
        }

        XCTAssertThrowsError(
            try TrafficNetworkConditionDraft(
                latencyMilliseconds: "0",
                downloadKibibytesPerSecond: "",
                uploadKibibytesPerSecond: "",
                packetLossPercentage: "0"
            ).profile()
        ) { error in
            XCTAssertEqual(error as? TrafficNetworkConditionDraftError, .emptyProfile)
        }
    }

    func testNetworkConditionProfilesPersistUpdateAndRemoveByStableIdentity() throws {
        let suiteName = "ProxyLensIntegrationTests.NetworkConditions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficNetworkConditionProfileStore(defaults: defaults)

        let original = try store.save(
            name: " Slow VPN ",
            profile: ThrottleProfile(
                latency: 0.5,
                downloadBytesPerSecond: 128_000,
                uploadBytesPerSecond: 64_000
            )
        )
        let updated = try store.save(
            name: "slow vpn",
            profile: ThrottleProfile(latency: 0.8)
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.name, "slow vpn")
        XCTAssertEqual(store.profiles, [updated])
        XCTAssertEqual(
            UserDefaultsTrafficNetworkConditionProfileStore(defaults: defaults).profiles,
            [updated]
        )

        store.remove(id: updated.id)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(
            UserDefaultsTrafficNetworkConditionProfileStore(defaults: defaults).profiles.isEmpty
        )
    }

    func testNetworkConditionProfileStoreRejectsEmptyAndOversizedNames() {
        let store = InMemoryTrafficNetworkConditionProfileStore()

        XCTAssertThrowsError(
            try store.save(name: "  ", profile: ThrottleProfile(latency: 0.2))
        ) { error in
            XCTAssertEqual(
                error as? TrafficNetworkConditionProfileStoreError,
                .invalidName
            )
        }
        XCTAssertThrowsError(
            try store.save(
                name: String(repeating: "a", count: 81),
                profile: ThrottleProfile(latency: 0.2)
            )
        ) { error in
            XCTAssertEqual(
                error as? TrafficNetworkConditionProfileStoreError,
                .invalidName
            )
        }
    }

    func testRuleManagerPresentsTogglesAndRemovesCurrentRules() async {
        let engine = RuleEngine()
        let rule = await engine.blockHost("api.example.com")
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            ruleEngine: engine
        )

        var rows = await viewModel.currentRulePresentations()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, rule.id)
        XCTAssertEqual(rows[0].name, "Block api.example.com")
        XCTAssertEqual(rows[0].action, "Block")
        XCTAssertEqual(rows[0].phase, "Request Headers")
        XCTAssertEqual(rows[0].matcher, "Host api.example.com")
        XCTAssertTrue(rows[0].enabled)

        await viewModel.setRuleEnabled(false, id: rule.id)
        rows = await viewModel.currentRulePresentations()
        XCTAssertFalse(rows[0].enabled)

        await viewModel.removeRule(id: rule.id)
        rows = await viewModel.currentRulePresentations()
        XCTAssertTrue(rows.isEmpty)
    }

    func testTrafficRuleDraftBuildsValidatedNativeRules() throws {
        let rule = try TrafficRuleDraft(
            name: "Block staging APIs",
            priority: 12,
            action: .block,
            phase: .requestHeaders,
            matcher: .host,
            patternKind: .wildcard,
            matcherValue: "*.staging.example.com"
        ).makeRule()

        XCTAssertEqual(rule.name, "Block staging APIs")
        XCTAssertEqual(rule.priority, 12)
        XCTAssertEqual(rule.phase, .requestHeaders)
        XCTAssertEqual(rule.matcher, .host(.wildcard("*.staging.example.com")))
        XCTAssertEqual(rule.action, .block(reason: "Blocked by ProxyLens"))

        XCTAssertThrowsError(
            try TrafficRuleDraft(
                name: "Broken regex",
                priority: 0,
                action: .breakpoint,
                phase: .responseHeaders,
                matcher: .path,
                patternKind: .regularExpression,
                matcherValue: "["
            ).makeRule()
        ) { error in
            XCTAssertEqual(error as? TrafficRuleDraftError, .invalidRegularExpression)
        }

        XCTAssertThrowsError(
            try TrafficRuleDraft(
                name: "Invalid allow phase",
                priority: 0,
                action: .allow,
                phase: .responseHeaders,
                matcher: .any,
                patternKind: .exact,
                matcherValue: ""
            ).makeRule()
        ) { error in
            XCTAssertEqual(error as? TrafficRuleDraftError, .unsupportedPhase)
        }
    }

    func testTrafficRuleDraftBuildsAndRoundTripsDNSSpoofRules() throws {
        let rule = try TrafficRuleDraft(
            name: "Route local API",
            priority: 8,
            action: .dnsSpoof,
            phase: .connection,
            matcher: .host,
            patternKind: .exact,
            matcherValue: "api.example.com",
            actionValue: " 127.0.0.1 "
        ).makeRule()

        XCTAssertEqual(
            rule.action,
            .dnsSpoof(try DNSSpoofSpec(address: "127.0.0.1"))
        )
        let restored = try XCTUnwrap(TrafficRuleDraft(rule: rule))
        XCTAssertEqual(restored.action, .dnsSpoof)
        XCTAssertEqual(restored.actionValue, "127.0.0.1")
        XCTAssertEqual(try restored.makeRule(), rule)

        XCTAssertThrowsError(
            try TrafficRuleDraft(
                name: "Invalid DNS rule",
                priority: 8,
                action: .dnsSpoof,
                phase: .connection,
                matcher: .host,
                patternKind: .exact,
                matcherValue: "api.example.com",
                actionValue: "localhost"
            ).makeRule()
        ) { error in
            XCTAssertNotNil(error as? DNSSpoofSpecError)
        }
    }

    func testRuleEditorShowsAnAccessibleDNSSpoofAddressField() throws {
        let editor = TrafficRuleEditorViewController()
        editor.loadView()
        let action = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.action" }
            )
        )

        action.selectItem(withTitle: "DNS Spoof")
        action.sendAction(action.action, to: action.target)

        let address = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.actionValue" }
            )
        )
        XCTAssertFalse(address.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(address.accessibilityLabel(), "DNS spoof address")
        XCTAssertEqual(address.placeholderString, "127.0.0.1 or ::1")
    }

    func testTrafficRuleDraftBuildsAndRoundTripsBodyScripts() throws {
        let source = """
            function onRequest(context) {
              context.request.headers.push({ name: "X-Debug", value: "ProxyLens" });
              return context.request;
            }
            """
        let rule = try TrafficRuleDraft(
            name: "Tag API requests",
            priority: 4,
            action: .script,
            phase: .requestBody,
            matcher: .host,
            patternKind: .exact,
            matcherValue: "api.example.com",
            scriptSource: source
        ).makeRule()

        guard case .script(let spec) = rule.action else {
            return XCTFail("Expected a script rule")
        }
        XCTAssertEqual(spec.source, source)

        let draft = try XCTUnwrap(TrafficRuleDraft(rule: rule))
        XCTAssertEqual(draft.id, rule.id)
        XCTAssertEqual(draft.action, .script)
        XCTAssertEqual(draft.phase, .requestBody)
        XCTAssertEqual(draft.scriptSource, source)
        XCTAssertEqual(try draft.makeRule(), rule)

        XCTAssertThrowsError(
            try TrafficRuleDraft(
                name: "Empty script",
                priority: 0,
                action: .script,
                phase: .responseBody,
                matcher: .any,
                patternKind: .exact,
                matcherValue: "",
                scriptSource: "  \n"
            ).makeRule()
        ) { error in
            XCTAssertEqual(error as? TrafficRuleDraftError, .missingScriptSource)
        }

        XCTAssertThrowsError(
            try TrafficRuleDraft(
                name: "Oversized script",
                priority: 0,
                action: .script,
                phase: .requestBody,
                matcher: .any,
                patternKind: .exact,
                matcherValue: "",
                scriptSource: String(
                    repeating: "a",
                    count: ScriptExecutionLimits.maximumSourceByteCount + 1
                )
            ).makeRule()
        ) { error in
            XCTAssertEqual(
                error as? ScriptExecutionError,
                .sourceTooLarge(
                    maximumByteCount: ScriptExecutionLimits.maximumSourceByteCount
                )
            )
        }
    }

    func testRuleEditorShowsSourceAndPhaseTemplateForScriptRules() throws {
        let existingSource = "function onRequest(context) { return context.request; }"
        let existingRule = try TrafficRuleDraft(
            name: "Existing script",
            priority: 7,
            action: .script,
            phase: .requestBody,
            matcher: .any,
            patternKind: .exact,
            matcherValue: "",
            scriptSource: existingSource
        ).makeRule()
        let editor = TrafficRuleEditorViewController(
            draft: try XCTUnwrap(TrafficRuleDraft(rule: existingRule))
        )
        editor.loadView()

        let sourceEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.scriptSource" }
            )
        )
        XCTAssertEqual(sourceEditor.string, existingSource)
        XCTAssertFalse(sourceEditor.enclosingScrollView?.isHiddenOrHasHiddenAncestor ?? true)
        XCTAssertEqual(sourceEditor.accessibilityLabel(), "JavaScript source")

        let newEditor = TrafficRuleEditorViewController()
        newEditor.loadView()
        let action = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: newEditor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.action" }
            )
        )
        action.selectItem(withTitle: "Script")
        action.sendAction(action.action, to: action.target)

        let newSourceEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: newEditor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.scriptSource" }
            )
        )
        XCTAssertTrue(newSourceEditor.string.contains("function onRequest(context)"))
        XCTAssertFalse(newSourceEditor.enclosingScrollView?.isHiddenOrHasHiddenAncestor ?? true)

        let phase = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: newEditor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.phase" }
            )
        )
        phase.selectItem(withTitle: "Response Body")
        phase.sendAction(phase.action, to: phase.target)
        XCTAssertTrue(newSourceEditor.string.contains("function onResponse(context)"))

        let customSource =
            "function onResponse(context) { context.response.body = \"custom\"; return context.response; }"
        newSourceEditor.string = customSource
        newEditor.textDidChange(
            Notification(name: NSText.didChangeNotification, object: newSourceEditor)
        )
        phase.selectItem(withTitle: "Request Body")
        phase.sendAction(phase.action, to: phase.target)
        XCTAssertEqual(newSourceEditor.string, customSource)
    }

    func testBreakpointRuleEditorOffersWebSocketFramePhase() throws {
        let draft = TrafficRuleDraft(
            name: "Pause WebSocket responses",
            priority: 10,
            action: .breakpoint,
            phase: .webSocketFrame,
            matcher: .host,
            patternKind: .exact,
            matcherValue: "socket.example.com"
        )

        let rule = try draft.makeRule()
        XCTAssertEqual(rule.phase, .webSocketFrame)
        XCTAssertEqual(rule.action, .breakpoint)
        XCTAssertNotNil(TrafficRuleDraft(rule: rule))

        let editor = TrafficRuleEditorViewController()
        editor.loadView()
        let action = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.action" }
            )
        )
        action.selectItem(withTitle: "Breakpoint")
        action.sendAction(action.action, to: action.target)
        let phase = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.phase" }
            )
        )
        XCTAssertTrue(phase.itemTitles.contains("WebSocket Frame"))
    }

    func testTrafficRuleDraftBuildsAndRoundTripsHeaderScripts() throws {
        let phases: [RulePhase] = [
            .requestHeaders, .requestBody, .responseHeaders, .responseBody
        ]
        for phase in phases {
            let rule = try TrafficRuleDraft(
                name: "Script \(phase.rawValue)",
                priority: 7,
                action: .script,
                phase: phase,
                matcher: .any,
                patternKind: .exact,
                matcherValue: "",
                scriptSource: "function onRequest(context) { return context.request; }"
            ).makeRule()

            let restored = try XCTUnwrap(TrafficRuleDraft(rule: rule))
            XCTAssertEqual(restored.phase, phase)
            XCTAssertEqual(
                restored.scriptSource, "function onRequest(context) { return context.request; }")
        }

        let editor = TrafficRuleEditorViewController()
        editor.loadView()
        let action = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.action" }
            )
        )
        action.selectItem(withTitle: "Script")
        action.sendAction(action.action, to: action.target)
        let phase = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.phase" }
            )
        )
        XCTAssertEqual(
            phase.itemTitles,
            ["Request Headers", "Request Body", "Response Headers", "Response Body"]
        )
        let source = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.scriptSource" }
            )
        )
        XCTAssertTrue(source.string.contains("context.request.headers"))
        XCTAssertFalse(source.string.contains("context.request.body"))
        XCTAssertTrue(source.string.contains("WebSocket"))
        XCTAssertTrue(source.string.contains("protected"))

        phase.selectItem(withTitle: "Response Headers")
        phase.sendAction(phase.action, to: phase.target)
        XCTAssertTrue(source.string.contains("context.response.headers"))
        XCTAssertFalse(source.string.contains("context.response.body"))
        XCTAssertTrue(source.string.contains("WebSocket"))
        XCTAssertTrue(source.string.contains("protected"))
    }

    func testRuleManagerAddsValidatedDraftToLiveRules() async throws {
        let engine = RuleEngine()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            ruleEngine: engine
        )
        let rule = try TrafficRuleDraft(
            name: "Pause API responses",
            priority: 18,
            action: .breakpoint,
            phase: .responseHeaders,
            matcher: .host,
            patternKind: .exact,
            matcherValue: "api.example.com"
        ).makeRule()

        await viewModel.addRule(rule)

        let rows = await viewModel.currentRulePresentations()
        XCTAssertEqual(rows.map(\.name), ["Pause API responses"])
        XCTAssertEqual(rows.map(\.action), ["Breakpoint"])
        XCTAssertEqual(rows.map(\.phase), ["Response Headers"])
    }

    func testTrafficRuleDraftRoundTripsEditableRuleWithoutChangingIdentity() throws {
        let rule = Rule(
            name: "Block staging APIs",
            enabled: false,
            priority: 12,
            phase: .requestHeaders,
            matcher: .host(.wildcard("*.staging.example.com")),
            action: .block(reason: "Staging is offline")
        )

        let draft = try XCTUnwrap(TrafficRuleDraft(rule: rule))

        XCTAssertEqual(try draft.makeRule(), rule)
        XCTAssertNil(
            TrafficRuleDraft(
                rule: Rule(
                    name: "Map API",
                    phase: .requestHeaders,
                    action: .mapRemote(url: URL(string: "https://local.example.com")!)
                )
            )
        )
    }

    func testRuleManagerUpdatesExistingRuleWithoutChangingIdentity() async throws {
        let engine = RuleEngine()
        let original = await engine.blockHost("api.example.com", reason: "Old reason")
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            ruleEngine: engine
        )
        let replacement = try TrafficRuleDraft(
            id: original.id,
            name: "Pause API responses",
            priority: 18,
            action: .breakpoint,
            phase: .responseHeaders,
            matcher: .host,
            patternKind: .exact,
            matcherValue: "api.example.com"
        ).makeRule()

        let didUpdate = await viewModel.updateRule(replacement)
        XCTAssertTrue(didUpdate)

        let rules = await engine.currentRules().rules
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, original.id)
        XCTAssertEqual(rules[0].name, "Pause API responses")
        XCTAssertEqual(rules[0].action, .breakpoint)
    }

    func testRuleManagerSavesAppliesAndRemovesCompleteProfiles() async throws {
        let engine = RuleEngine()
        let profileStore = RecordingRuleProfileStore()
        let original = await engine.blockHost("api.example.com")
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            ruleEngine: engine,
            ruleProfileStore: profileStore
        )

        let profile = try await viewModel.saveRuleProfile(name: " Debug API ")
        XCTAssertEqual(profile.name, "Debug API")
        XCTAssertEqual(profile.rules.rules.map(\.id), [original.id])
        var savedProfiles = try await viewModel.currentRuleProfiles()
        XCTAssertEqual(savedProfiles, [profile])

        await viewModel.removeRule(id: original.id)
        var activeRules = await engine.currentRules().rules
        XCTAssertTrue(activeRules.isEmpty)

        try await viewModel.applyRuleProfile(id: profile.id)
        activeRules = await engine.currentRules().rules
        XCTAssertEqual(activeRules.map(\.id), [original.id])

        try await viewModel.removeRuleProfile(id: profile.id)
        savedProfiles = try await viewModel.currentRuleProfiles()
        XCTAssertTrue(savedProfiles.isEmpty)
    }

    func testRuleManagerImportsAndExportsPortableProfiles() async throws {
        let engine = RuleEngine()
        let profileStore = RecordingRuleProfileStore()
        _ = await engine.blockHost("tracker.example.com")
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            ruleEngine: engine,
            ruleProfileStore: profileStore
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-rules-\(UUID().uuidString).proxylensrules")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let saved = try await viewModel.saveRuleProfile(name: "Tracking blockers")
        try await viewModel.exportRuleProfile(id: saved.id, to: fileURL)
        try await viewModel.removeRuleProfile(id: saved.id)
        let profilesAfterRemoval = try await viewModel.currentRuleProfiles()
        XCTAssertTrue(profilesAfterRemoval.isEmpty)

        let imported = try await viewModel.importRuleProfile(from: fileURL)
        XCTAssertEqual(imported.id, saved.id)
        XCTAssertEqual(imported.name, "Tracking blockers")
        XCTAssertEqual(imported.rules, saved.rules)
        let profilesAfterImport = try await viewModel.currentRuleProfiles()
        XCTAssertEqual(profilesAfterImport, [imported])
    }

    func testRuleManagerRendersNativeRuleTableAndRemovesSelection() async throws {
        let engine = RuleEngine()
        await engine.blockHost("api.example.com")
        await engine.allowHost("assets.example.com")
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            ruleEngine: engine
        )
        let controller = RuleManagerViewController(viewModel: viewModel)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 480)
        controller.view.layoutSubtreeIfNeeded()

        await controller.reloadRules()

        let table = try XCTUnwrap(
            Self.descendant(
                of: NSTableView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "ruleManager.table" }
            )
        )
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(
            table.tableColumns.map(\.title),
            ["On", "Rule", "Action", "Phase", "Priority", "Matcher"]
        )
        let removeButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "ruleManager.remove" }
            )
        )
        XCTAssertFalse(removeButton.isEnabled)
        let editButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "ruleManager.edit" }
            )
        )
        XCTAssertFalse(editButton.isEnabled)
        XCTAssertNotNil(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "ruleManager.add" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "ruleManager.profile" }
            )
        )
        for identifier in [
            "ruleManager.saveProfile", "ruleManager.applyProfile", "ruleManager.deleteProfile",
            "ruleManager.importProfile", "ruleManager.exportProfile"
        ] {
            XCTAssertNotNil(
                Self.descendant(
                    of: NSButton.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == identifier }
                )
            )
        }

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(removeButton.isEnabled)
        XCTAssertTrue(editButton.isEnabled)
        removeButton.performClick(nil)
        try await waitUntil { table.numberOfRows == 1 }
        let remainingRules = await engine.currentRules().rules
        XCTAssertEqual(remainingRules.count, 1)
    }

    func testConsoleStoreProjectsFiltersAndRemovesSavedSessions() throws {
        var olderSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try olderSession.rename(to: "Checkout debugging")
        olderSession.stop(at: Date(timeIntervalSince1970: 1_100))
        let recordingSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        let olderFlow = try Self.makeFlow(
            index: 1,
            host: "old.example.com",
            statusCode: 200,
            sessionID: olderSession.id
        )
        let recordingFlow = try Self.makeFlow(
            index: 2,
            host: "live.example.com",
            statusCode: 202,
            sessionID: recordingSession.id
        )
        var store = TrafficConsoleStore()
        store.replaceSessions([olderSession, recordingSession])
        store.apply([.finished(olderFlow), .finished(recordingFlow)])

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.sessions.map(\.id), [recordingSession.id, olderSession.id])
        XCTAssertEqual(snapshot.sessions.map(\.flowCount), [1, 1])
        XCTAssertEqual(snapshot.sessions.last?.name, "Checkout debugging")

        store.selectSource(.session(olderSession.id))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [olderFlow.id])
        XCTAssertEqual(store.flows(in: olderSession.id).map(\.id), [olderFlow.id])

        store.removeSession(olderSession.id)
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.selectedSource, .allTraffic)
        XCTAssertEqual(snapshot.sessions.map(\.id), [recordingSession.id])
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [recordingFlow.id])
    }

    func testConsoleStoreGroupsFiltersSortsAndPreservesSelectionAcrossUpdates() throws {
        let first = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 204)
        let second = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 404)
        let third = try Self.makeFlow(index: 3, host: "api.example.com", statusCode: 200)
        var store = TrafficConsoleStore()

        store.apply([.started(first), .finished(second), .finished(third)])
        store.selectFlow(first.id)
        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)

        XCTAssertEqual(snapshot.allFlowCount, 3)
        XCTAssertEqual(
            snapshot.domains,
            [
                TrafficDomainSummary(host: "api.example.com", flowCount: 2),
                TrafficDomainSummary(host: "cdn.example.com", flowCount: 1)
            ]
        )
        XCTAssertEqual(snapshot.selectedFlowID, first.id)

        var updatedFirst = first
        updatedFirst.markTLSHandshakeCompleted(at: Date(timeIntervalSince1970: 1.1))
        store.apply([.updated(updatedFirst)])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.selectedFlowID, first.id)
        XCTAssertEqual(snapshot.visibleRows.first?.state, .completed)

        store.selectSource(.domain("api.example.com"))
        store.setSort(TrafficConsoleSort(key: .status, ascending: false))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [first.id, third.id])

        store.selectSource(.domain("cdn.example.com"))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [second.id])
    }

    func testConsoleStoreKeepsOrderedMultiSelectionAndDropsOnlyHiddenFlows() throws {
        let first = try Self.makeFlow(index: 1, host: "first.example.com", statusCode: 204)
        let second = try Self.makeFlow(index: 2, host: "second.example.com", statusCode: 404)
        let third = try Self.makeFlow(index: 3, host: "third.example.com", statusCode: 200)
        var store = TrafficConsoleStore()
        store.apply([.finished(first), .finished(second), .finished(third)])
        store.setSort(TrafficConsoleSort(key: .status, ascending: true))

        store.selectFlows([second.id, third.id], primary: second.id)
        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)

        XCTAssertEqual(snapshot.visibleRows.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(snapshot.selectedFlowIDs, [third.id, second.id])
        XCTAssertEqual(snapshot.selectedFlowID, second.id)

        store.selectSource(.domain("third.example.com"))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)

        XCTAssertEqual(snapshot.selectedFlowIDs, [third.id])
        XCTAssertEqual(snapshot.selectedFlowID, third.id)
    }

    func testConsoleStoreKeepsPinnedDomainsVisibleAcrossSessionChanges() throws {
        let api = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 200)
        let cdn = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 200)
        var store = TrafficConsoleStore()
        store.apply([.finished(api), .finished(cdn)])

        store.setPinnedDomain("cdn.example.com", isPinned: true)
        store.setPinnedDomain("api.example.com", isPinned: true)

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(
            snapshot.pinnedDomains,
            [
                TrafficDomainSummary(host: "api.example.com", flowCount: 1),
                TrafficDomainSummary(host: "cdn.example.com", flowCount: 1)
            ]
        )

        store.replaceAll([])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(
            snapshot.pinnedDomains,
            [
                TrafficDomainSummary(host: "api.example.com", flowCount: 0),
                TrafficDomainSummary(host: "cdn.example.com", flowCount: 0)
            ]
        )

        store.setPinnedDomain("api.example.com", isPinned: false)
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(
            snapshot.pinnedDomains,
            [TrafficDomainSummary(host: "cdn.example.com", flowCount: 0)]
        )
    }

    func testPinnedDomainsStorePersistsNormalizedSortedDomains() throws {
        let suiteName = "ProxyLensIntegrationTests.PinnedDomains.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficPinnedDomainsStore(defaults: defaults)

        store.save([" CDN.Example.com ", "api.example.com", ""])

        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsTrafficPinnedDomainsStore.defaultKey),
            ["api.example.com", "cdn.example.com"]
        )
        let restored = UserDefaultsTrafficPinnedDomainsStore(defaults: defaults)
        XCTAssertEqual(restored.domains, ["api.example.com", "cdn.example.com"])
    }

    func testSourceListVisibilityStoreDefaultsVisibleAndPersistsChanges() throws {
        let suiteName = "ProxyLensIntegrationTests.SourceListVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsTrafficSourceListVisibilityStore(defaults: defaults)
        XCTAssertTrue(store.isVisible)

        store.save(isVisible: false)
        XCTAssertFalse(
            UserDefaultsTrafficSourceListVisibilityStore(defaults: defaults).isVisible
        )

        store.save(isVisible: true)
        XCTAssertTrue(
            UserDefaultsTrafficSourceListVisibilityStore(defaults: defaults).isVisible
        )
    }

    func testRequestComposerStorePersistsNamedPresetsAndBoundsHistory() throws {
        let suiteName = "ProxyLensIntegrationTests.RequestComposer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficRequestComposerStore(defaults: defaults)

        let original = try store.savePreset(
            name: " Demo ",
            headersText: "GET https://example.com/ HTTP/1.1",
            bodyText: ""
        )
        let updated = try store.savePreset(
            name: "demo",
            headersText: "POST https://example.com/events HTTP/1.1",
            bodyText: "{\"enabled\":true}"
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.name, "demo")
        XCTAssertEqual(store.presets, [updated])
        XCTAssertEqual(
            UserDefaultsTrafficRequestComposerStore(defaults: defaults).presets,
            [updated]
        )

        for index in 0..<TrafficRequestComposerStoreLimits.maximumHistoryEntries + 5 {
            _ = store.recordHistory(
                headersText: "GET https://example.com/\(index) HTTP/1.1",
                bodyText: ""
            )
        }
        XCTAssertEqual(
            store.history.count,
            TrafficRequestComposerStoreLimits.maximumHistoryEntries
        )
        XCTAssertTrue(store.history[0].headersText.contains("/54"))
        XCTAssertTrue(store.history.allSatisfy { $0.kind == .history })
    }

    func testRequestComposerStoreRejectsInvalidPresetNamesAndOversizedEntries() {
        let store = InMemoryTrafficRequestComposerStore()

        XCTAssertThrowsError(
            try store.savePreset(
                name: "  ",
                headersText: "GET https://example.com/ HTTP/1.1",
                bodyText: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? TrafficRequestComposerStoreError,
                .invalidPresetName
            )
        }

        XCTAssertThrowsError(
            try store.savePreset(
                name: "Demo",
                headersText: String(
                    repeating: "x",
                    count: TrafficRequestComposerStoreLimits.maximumStoredBytes + 1
                ),
                bodyText: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? TrafficRequestComposerStoreError,
                .contentTooLarge
            )
        }

        XCTAssertNil(
            store.recordHistory(
                headersText: "\n",
                bodyText: ""
            )
        )
        XCTAssertTrue(store.history.isEmpty)
    }

    func testConsoleStoreReplaceAllResetsRowsAndKeepsFilters() throws {
        let first = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 200)
        let second = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 404)
        let replacement = try Self.makeFlow(index: 3, host: "api.example.com", statusCode: 201)
        var store = TrafficConsoleStore()
        store.apply([.finished(first), .finished(second)])
        store.selectFlow(first.id)
        store.setDisplayFilter(TrafficDisplayFilter(searchText: "api"))

        store.replaceAll([replacement])
        let snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.allFlowCount, 1)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [replacement.id])
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.displayFilter.searchText, "api")
    }

    func testConsoleStoreGroupsAndFiltersDesktopApplicationsWithUnknownFallback() throws {
        let safari = FlowSource(
            kind: .desktopProxy,
            label: "Safari",
            application: FlowApplication(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundlePath: "/System/Applications/Safari.app",
                executablePath: "/System/Applications/Safari.app/Contents/MacOS/Safari",
                processIdentifier: 101
            )
        )
        let curl = FlowSource(
            kind: .desktopProxy,
            label: "curl",
            application: FlowApplication(
                name: "curl",
                executablePath: "/usr/bin/curl",
                processIdentifier: 202
            )
        )
        let imported = FlowSource(kind: .importedSession, label: "Saved capture")
        let flows = try [
            Self.makeFlow(index: 1, host: "one.example.com", statusCode: 200, source: safari),
            Self.makeFlow(index: 2, host: "two.example.com", statusCode: 200, source: safari),
            Self.makeFlow(index: 3, host: "three.example.com", statusCode: 200, source: curl),
            Self.makeFlow(index: 4, host: "four.example.com", statusCode: 200),
            Self.makeFlow(index: 5, host: "five.example.com", statusCode: 200, source: imported)
        ]
        var store = TrafficConsoleStore()

        store.apply(flows.map(FlowEvent.finished))
        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)

        XCTAssertEqual(snapshot.applications.map(\.name), ["curl", "Safari", "Unknown App"])
        XCTAssertEqual(snapshot.applications.map(\.flowCount), [1, 2, 1])

        let safariID = try XCTUnwrap(snapshot.applications.first { $0.name == "Safari" }?.id)
        store.selectSource(.application(safariID))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [flows[0].id, flows[1].id])

        let unknownID = try XCTUnwrap(
            snapshot.applications.first { $0.name == "Unknown App" }?.id
        )
        store.selectSource(.application(unknownID))
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [flows[3].id])
    }

    func testDisplayFilterComposesSearchFacetsAndDomainSelection() throws {
        let matching = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 201,
            method: .post,
            responseContentType: "application/problem+json; charset=utf-8",
            requestHeaderValue: "Blue Café"
        )
        let wrongOrigin = try Self.makeFlow(
            index: 2,
            host: "api.example.com",
            statusCode: 201,
            method: .post,
            responseContentType: "application/json",
            source: FlowSource(kind: .importedSession, label: "Blue Cafe archive"),
            requestHeaderValue: "Blue Cafe"
        )
        let wrongStatus = try Self.makeFlow(
            index: 3,
            host: "api.example.com",
            statusCode: 404,
            method: .post,
            responseContentType: "application/json",
            requestHeaderValue: "Blue Cafe"
        )
        let wrongDomain = try Self.makeFlow(
            index: 4,
            host: "cdn.example.com",
            statusCode: 200,
            method: .post,
            responseContentType: "application/json",
            requestHeaderValue: "Blue Cafe"
        )
        var store = TrafficConsoleStore()
        store.apply([
            .finished(matching),
            .finished(wrongOrigin),
            .finished(wrongStatus),
            .finished(wrongDomain)
        ])
        store.selectSource(.domain("api.example.com"))
        store.setDisplayFilter(
            TrafficDisplayFilter(
                searchText: "blue cafe",
                method: .post,
                status: .success,
                contentType: .json,
                origin: .desktopProxy
            )
        )

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [matching.id])
        XCTAssertEqual(snapshot.allFlowCount, 4)
        XCTAssertTrue(snapshot.displayFilter.isActive)

        store.selectFlow(matching.id)
        store.setDisplayFilter(
            TrafficDisplayFilter(
                searchText: "missing",
                method: .post,
                status: .success,
                contentType: .json,
                origin: .desktopProxy
            )
        )
        XCTAssertNil(store.selectedFlowID)

        store.clearFilters()
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.count, 4)
        XCTAssertEqual(snapshot.selectedSource, .allTraffic)
        XCTAssertEqual(snapshot.displayFilter, .all)
    }

    func testDisplayFilterPersistsAcrossLargeLiveUpdatesAndSelectionChanges() throws {
        var flows: [Flow] = []
        flows.reserveCapacity(2_000)
        for index in 0..<2_000 {
            flows.append(
                try Self.makeFlow(
                    index: index,
                    host: "host-\(index % 25).example.com",
                    statusCode: 200 + (index % 5)
                )
            )
        }

        let filter = TrafficDisplayFilter(
            searchText: "host-7.example.com",
            method: .get,
            status: .success,
            contentType: .binary,
            origin: .desktopProxy
        )
        var store = TrafficConsoleStore()
        store.setDisplayFilter(filter)
        store.apply(flows.map(FlowEvent.finished))

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.displayFilter, filter)
        XCTAssertEqual(snapshot.visibleRows.count, 40)

        let selectedID = try XCTUnwrap(snapshot.visibleRows.first?.id)
        store.selectFlow(selectedID)
        var selectedUpdate = try XCTUnwrap(flows.first { $0.id == selectedID })
        selectedUpdate.markTLSHandshakeCompleted(at: Date(timeIntervalSince1970: 2_100))
        store.apply([.updated(selectedUpdate)])
        XCTAssertEqual(store.selectedFlowID, selectedID)

        selectedUpdate.attachResponse(
            try HTTPResponse(
                statusCode: 404,
                reasonPhrase: "Not Found",
                headers: selectedUpdate.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(selectedUpdate)])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.visibleRows.count, 39)
        XCTAssertEqual(snapshot.displayFilter, filter)
    }

    func testCustomFilterStorePersistsStableUpdatesRenameDeleteAndBounds() throws {
        let suiteName = "ProxyLensIntegrationTests.CustomFilters.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficCustomFilterPresetStore(defaults: defaults)
        let firstFilter = TrafficDisplayFilter(
            searchText: "api",
            method: .post,
            status: .success,
            contentType: .json,
            origin: .desktopProxy,
            annotation: .commented
        )

        let first = try store.save(name: "  API failures  ", filter: firstFilter)
        let second = try store.save(
            name: "Images",
            filter: TrafficDisplayFilter(contentType: .image)
        )
        let updated = try store.save(
            name: "api failures",
            filter: TrafficDisplayFilter(status: .serverError)
        )

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(store.presets.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.presets.first?.name, "api failures")
        XCTAssertEqual(store.presets.first?.filter.status, .serverError)
        XCTAssertEqual(
            UserDefaultsTrafficCustomFilterPresetStore(defaults: defaults).presets,
            store.presets
        )

        let renamed = try store.rename(id: second.id, name: "Media")
        XCTAssertEqual(renamed.id, second.id)
        XCTAssertEqual(store.presets.map(\.name), ["api failures", "Media"])
        XCTAssertThrowsError(try store.rename(id: second.id, name: "API FAILURES")) {
            XCTAssertEqual($0 as? TrafficCustomFilterPresetError, .duplicateName)
        }

        store.remove(id: first.id)
        XCTAssertEqual(store.presets, [renamed])
        store.remove(id: second.id)
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNil(defaults.object(forKey: UserDefaultsTrafficCustomFilterPresetStore.defaultKey))

        for index in 0..<TrafficCustomFilterPreset.maximumPresetCount {
            _ = try store.save(
                name: "Preset \(index)",
                filter: TrafficDisplayFilter(searchText: "host-\(index)")
            )
        }
        XCTAssertThrowsError(
            try store.save(name: "Overflow", filter: .all)
        ) {
            XCTAssertEqual(
                $0 as? TrafficCustomFilterPresetError,
                .tooManyPresets(maximum: TrafficCustomFilterPreset.maximumPresetCount)
            )
        }
    }

    func testCustomFilterStoreRejectsInvalidAndCorruptDocuments() throws {
        struct Document: Encodable {
            let version: Int
            let presets: [TrafficCustomFilterPreset]
        }

        let suiteName = "ProxyLensIntegrationTests.InvalidCustomFilters.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTrafficCustomFilterPresetStore(defaults: defaults)

        XCTAssertThrowsError(try store.save(name: "   ", filter: .all)) {
            XCTAssertEqual($0 as? TrafficCustomFilterPresetError, .emptyName)
        }
        XCTAssertThrowsError(
            try store.save(
                name: String(
                    repeating: "n", count: TrafficCustomFilterPreset.maximumNameLength + 1),
                filter: .all
            )
        ) {
            XCTAssertEqual(
                $0 as? TrafficCustomFilterPresetError,
                .nameTooLong(maximum: TrafficCustomFilterPreset.maximumNameLength)
            )
        }
        XCTAssertThrowsError(
            try store.save(
                name: "Oversized search",
                filter: TrafficDisplayFilter(
                    searchText: String(
                        repeating: "x",
                        count: TrafficCustomFilterPreset.maximumSearchByteCount + 1
                    )
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? TrafficCustomFilterPresetError,
                .searchTooLarge(maximumBytes: TrafficCustomFilterPreset.maximumSearchByteCount)
            )
        }

        defaults.set(
            Data(#"{"version":2,"presets":[]}"#.utf8),
            forKey: UserDefaultsTrafficCustomFilterPresetStore.defaultKey
        )
        XCTAssertTrue(store.presets.isEmpty)
        defaults.set(
            Data("not-json".utf8),
            forKey: UserDefaultsTrafficCustomFilterPresetStore.defaultKey
        )
        XCTAssertTrue(store.presets.isEmpty)

        let duplicate = try TrafficCustomFilterPreset(name: "Duplicate", filter: .all)
        defaults.set(
            try JSONEncoder().encode(Document(version: 1, presets: [duplicate, duplicate])),
            forKey: UserDefaultsTrafficCustomFilterPresetStore.defaultKey
        )
        XCTAssertTrue(store.presets.isEmpty)
    }

    func testViewModelAppliesCompleteCustomFilterAndInvalidatesHiddenSelection() async throws {
        let presetStore = InMemoryTrafficCustomFilterPresetStore()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            customFilterPresetStore: presetStore
        )
        await viewModel.prepare()
        var matching = try Self.makeFlow(
            index: 21,
            host: "api.example.com",
            statusCode: 201,
            method: .post,
            responseContentType: "application/json"
        )
        matching.setAnnotation(
            try FlowAnnotation(comment: "keep", highlight: .blue, isStruckThrough: false)
        )
        let hidden = try Self.makeFlow(
            index: 22,
            host: "cdn.example.com",
            statusCode: 404,
            method: .get,
            responseContentType: "image/png"
        )
        viewModel.receive(.finished(matching))
        viewModel.receive(.finished(hidden))
        viewModel.flushPendingEvents()
        viewModel.setSearchText("api")
        viewModel.setMethodFilter(.post)
        viewModel.setStatusFilter(.success)
        viewModel.setContentTypeFilter(.json)
        viewModel.setOriginFilter(.desktopProxy)
        viewModel.setAnnotationFilter(.blue)
        let saved = try viewModel.saveCustomFilterPreset(named: "API success")
        viewModel.clearDisplayFilters()
        viewModel.selectFlow(hidden.id)

        try viewModel.applyCustomFilterPreset(id: saved.id)

        XCTAssertEqual(viewModel.snapshot.displayFilter, saved.filter)
        XCTAssertEqual(viewModel.snapshot.visibleRows.map(\.id), [matching.id])
        XCTAssertNil(viewModel.snapshot.selectedFlowID)
        XCTAssertEqual(viewModel.customFilterPresets, [saved])
    }

    func testFilterBarExposesAccessibleCustomFilterMenuAndAppliesPreset() async throws {
        let presetStore = InMemoryTrafficCustomFilterPresetStore()
        let preset = try presetStore.save(
            name: "Errors",
            filter: TrafficDisplayFilter(status: .serverError)
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            customFilterPresetStore: presetStore
        )
        await viewModel.prepare()
        let filterBar = TrafficFilterBar(viewModel: viewModel)
        filterBar.render(viewModel.snapshot)
        let popup = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: filterBar,
                matching: { $0.accessibilityIdentifier() == "traffic.filter.custom" }
            )
        )

        XCTAssertEqual(popup.accessibilityLabel(), "Custom traffic filters")
        let presetIndex = try XCTUnwrap(popup.itemTitles.firstIndex(of: "Errors"))
        let presetItem = try XCTUnwrap(popup.item(at: presetIndex))
        let presetAction = try XCTUnwrap(presetItem.action)
        XCTAssertTrue(NSApp.sendAction(presetAction, to: presetItem.target, from: presetItem))
        XCTAssertEqual(viewModel.snapshot.displayFilter, preset.filter)
        filterBar.render(viewModel.snapshot)
        XCTAssertTrue(popup.itemTitles.contains("Rename Errors…"))
        XCTAssertTrue(popup.itemTitles.contains("Delete Errors"))
        XCTAssertTrue(popup.itemTitles.contains("Save Current Filter…"))
    }

    func testGraphQLOperationIsSearchableFilterableAndShownInRows() throws {
        let graphqlBody = Data(
            #"{"query":"mutation SaveProfile { saveProfile { id } }"}"#.utf8
        )
        let graphql = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200,
            requestBody: graphqlBody,
            method: .post,
            responseContentType: "application/json",
            requestContentType: "application/json"
        )
        let ordinaryJSON = try Self.makeFlow(
            index: 2,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data(#"{"status":"ok"}"#.utf8),
            method: .post,
            responseContentType: "application/json",
            requestContentType: "application/json"
        )
        var store = TrafficConsoleStore()
        store.apply([.finished(graphql), .finished(ordinaryJSON)])
        store.setDisplayFilter(TrafficDisplayFilter(contentType: .graphql))

        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [graphql.id])
        XCTAssertEqual(snapshot.visibleRows.first?.graphqlOperation, "SaveProfile")

        store.setDisplayFilter(
            TrafficDisplayFilter(searchText: "mutation saveprofile", contentType: .graphql)
        )
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [graphql.id])
    }

    func testAnnotationSearchFiltersAndStaleCaptureUpdatesPreserveLocalMetadata() throws {
        var annotated = try Self.makeFlow(
            index: 31,
            host: "annotations.example.com",
            statusCode: 200
        )
        let annotation = try FlowAnnotation(
            comment: "Investigate the authentication redirect",
            highlight: .purple,
            isStruckThrough: true
        )
        annotated.setAnnotation(annotation)
        let staleCaptureSnapshot = Flow(
            id: annotated.id,
            sessionID: annotated.sessionID,
            source: annotated.source,
            request: annotated.request,
            connection: annotated.connection,
            startedAt: annotated.createdAt
        )
        var store = TrafficConsoleStore()
        store.apply([.finished(annotated)])

        store.setDisplayFilter(
            TrafficDisplayFilter(
                searchText: "authentication redirect",
                annotation: .commented
            )
        )
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [annotated.id]
        )

        store.setDisplayFilter(TrafficDisplayFilter(annotation: .purple))
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [annotated.id]
        )
        store.apply([.updated(staleCaptureSnapshot)])
        XCTAssertEqual(store.flow(id: annotated.id)?.annotation, annotation)

        store.updateAnnotation(nil, for: annotated.id)
        XCTAssertNil(store.flow(id: annotated.id)?.annotation)
        XCTAssertTrue(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.isEmpty
        )
    }

    func testActiveFilterIncrementallyProjectsLiveInsertionsAndUpdates() throws {
        let matching = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200,
            requestHeaderValue: "needle"
        )
        var promoted = try Self.makeFlow(
            index: 2,
            host: "promoted.example.com",
            statusCode: 404,
            requestHeaderValue: "needle"
        )
        let hidden = try Self.makeFlow(
            index: 3,
            host: "hidden.example.com",
            statusCode: 200,
            requestHeaderValue: "haystack"
        )
        let liveMatching = try Self.makeFlow(
            index: 4,
            host: "live.example.com",
            statusCode: 204,
            requestHeaderValue: "needle"
        )

        var store = TrafficConsoleStore()
        store.setDisplayFilter(
            TrafficDisplayFilter(searchText: "needle", status: .success)
        )
        store.apply([.finished(matching), .finished(promoted), .finished(hidden)])
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [matching.id]
        )

        store.apply([.finished(liveMatching)])
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [matching.id, liveMatching.id]
        )

        promoted.attachResponse(
            try HTTPResponse(
                statusCode: 202,
                reasonPhrase: "Accepted",
                headers: promoted.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(promoted)])
        XCTAssertEqual(
            store.snapshot(capture: .stopped, inspection: .empty).visibleRows.map(\.id),
            [matching.id, promoted.id, liveMatching.id]
        )

        store.selectFlow(promoted.id)
        promoted.attachResponse(
            try HTTPResponse(
                statusCode: 503,
                reasonPhrase: "Unavailable",
                headers: promoted.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(promoted)])
        let snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [matching.id, liveMatching.id])
        XCTAssertNil(snapshot.selectedFlowID)
        XCTAssertEqual(snapshot.allFlowCount, 4)
    }

    func testFlowTableInsertsPromotedFilteredRowWithoutFullReload() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        let first = try Self.makeFlow(
            index: 1,
            host: "first.example.com",
            statusCode: 200,
            requestHeaderValue: "needle"
        )
        var promoted = try Self.makeFlow(
            index: 2,
            host: "promoted.example.com",
            statusCode: 404,
            requestHeaderValue: "needle"
        )
        let last = try Self.makeFlow(
            index: 3,
            host: "last.example.com",
            statusCode: 204,
            requestHeaderValue: "needle"
        )

        var store = TrafficConsoleStore()
        store.setDisplayFilter(
            TrafficDisplayFilter(searchText: "needle", status: .success)
        )
        store.apply([.finished(first), .finished(promoted), .finished(last)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.resetRecordedUpdates()

        promoted.attachResponse(
            try HTTPResponse(
                statusCode: 202,
                reasonPhrase: "Accepted",
                headers: promoted.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(promoted)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))

        XCTAssertEqual(tableView.insertedRowIndexes, [IndexSet(integer: 1)])
        XCTAssertEqual(tableView.fullReloadCount, 0)
        XCTAssertEqual(tableView.numberOfRows, 3)
    }

    func testFlowTableMovesSortedLiveUpdatesWithoutFullReload() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        var first = try Self.makeFlow(
            index: 1,
            host: "first.example.com",
            statusCode: 200,
            requestHeaderValue: "needle"
        )
        let second = try Self.makeFlow(
            index: 2,
            host: "second.example.com",
            statusCode: 300,
            requestHeaderValue: "needle"
        )
        let third = try Self.makeFlow(
            index: 3,
            host: "third.example.com",
            statusCode: 400,
            requestHeaderValue: "needle"
        )

        var store = TrafficConsoleStore()
        store.setDisplayFilter(TrafficDisplayFilter(searchText: "needle"))
        store.setSort(TrafficConsoleSort(key: .status, ascending: true))
        store.apply([.finished(first), .finished(second), .finished(third)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.resetRecordedUpdates()

        first.attachResponse(
            try HTTPResponse(
                statusCode: 500,
                reasonPhrase: "Server Error",
                headers: first.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(first)])
        var snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [second.id, third.id, first.id])
        controller.render(snapshot)
        XCTAssertFalse(tableView.movedRows.isEmpty)
        XCTAssertEqual(tableView.fullReloadCount, 0)

        tableView.resetRecordedUpdates()
        first.attachResponse(
            try HTTPResponse(
                statusCode: 100,
                reasonPhrase: "Continue",
                headers: first.response?.headers ?? HTTPHeaders()
            )
        )
        store.apply([.updated(first)])
        snapshot = store.snapshot(capture: .stopped, inspection: .empty)
        XCTAssertEqual(snapshot.visibleRows.map(\.id), [first.id, second.id, third.id])
        controller.render(snapshot)
        XCTAssertEqual(tableView.movedRows.count, 1)
        XCTAssertEqual(tableView.movedRows.first?.from, 2)
        XCTAssertEqual(tableView.movedRows.first?.to, 0)
        XCTAssertEqual(tableView.fullReloadCount, 0)
        XCTAssertEqual(tableView.numberOfRows, 3)
    }

    func testFlowTableKeepsDataSourceInSyncWhenRemovingMultipleRows() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view

        let kept = try Self.makeFlow(index: 1, host: "keep.example.com", statusCode: 200)
        let droppedA = try Self.makeFlow(index: 2, host: "drop-a.example.com", statusCode: 404)
        let droppedB = try Self.makeFlow(index: 3, host: "drop-b.example.com", statusCode: 500)
        let droppedC = try Self.makeFlow(index: 4, host: "drop-c.example.com", statusCode: 204)

        var store = TrafficConsoleStore()
        store.apply([
            .finished(kept),
            .finished(droppedA),
            .finished(droppedB),
            .finished(droppedC)
        ])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        XCTAssertEqual(tableView.numberOfRows, 4)
        tableView.resetRecordedUpdates()

        store.selectSource(.domain("keep.example.com"))
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))

        XCTAssertEqual(
            tableView.removedRowIndexes,
            [
                IndexSet(integer: 3),
                IndexSet(integer: 2),
                IndexSet(integer: 1)
            ])
        XCTAssertEqual(tableView.dataSourceRowCountsDuringRemovals, [3, 2, 1])
        XCTAssertEqual(tableView.fullReloadCount, 0)
        XCTAssertEqual(tableView.numberOfRows, 1)
    }

    func testFlowTableContextMenuOffersAnnotationsBeforeRequestActions() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view
        let first = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200
        )
        let second = try Self.makeFlow(
            index: 2,
            host: "cdn.example.com",
            statusCode: 201
        )
        let third = try Self.makeFlow(
            index: 3,
            host: "other.example.com",
            statusCode: 202
        )
        var store = TrafficConsoleStore()
        store.apply([.finished(first), .finished(second), .finished(third)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        XCTAssertTrue(tableView.allowsMultipleSelection)
        tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        tableView.clickedRowOverride = 0
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items[0].title, "Add Comment…")
        XCTAssertEqual(menu.items[0].action, NSSelectorFromString("editComment:"))
        XCTAssertEqual(menu.items[1].title, "Highlight")
        XCTAssertEqual(
            menu.items[1].submenu?.items.map(\.title),
            [
                "None", "Red", "Yellow", "Green", "Blue", "Purple", "Gray"
            ])
        XCTAssertEqual(menu.items[2].title, "Strikethrough")
        XCTAssertEqual(menu.items[4].title, "Repeat Request")
        XCTAssertEqual(menu.items[4].action, NSSelectorFromString("repeatRequest:"))
        XCTAssertEqual(menu.items[5].title, "Edit & Repeat…")
        XCTAssertEqual(menu.items[5].action, NSSelectorFromString("editAndRepeat:"))
        XCTAssertEqual(menu.items[6].title, "Compare Selected Flows…")
        XCTAssertEqual(menu.items[6].action, NSSelectorFromString("compareSelectedFlows:"))
        XCTAssertTrue(menu.items[6].isEnabled)
        XCTAssertEqual(menu.items[6].representedObject as? [FlowID], [first.id, second.id])
        XCTAssertEqual(menu.items[8].title, "Generate Request Code…")
        XCTAssertEqual(menu.items[8].action, NSSelectorFromString("generateRequestCode:"))
        XCTAssertEqual(menu.items[9].title, "Copy")
        XCTAssertEqual(
            menu.items[9].submenu?.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "URL", "Request Headers", "Request Body", "Request Cookies",
                "Response Headers", "Response Body", "Response Cookies", "cURL"
            ]
        )
        let copyItems = try XCTUnwrap(menu.items[9].submenu?.items)
        XCTAssertTrue(try XCTUnwrap(copyItems.first { $0.title == "URL" }).isEnabled)
        XCTAssertTrue(
            try XCTUnwrap(copyItems.first { $0.title == "Request Headers" }).isEnabled
        )
        XCTAssertFalse(
            try XCTUnwrap(copyItems.first { $0.title == "Request Body" }).isEnabled
        )
        XCTAssertFalse(
            try XCTUnwrap(copyItems.first { $0.title == "Request Cookies" }).isEnabled
        )
        XCTAssertTrue(
            try XCTUnwrap(copyItems.first { $0.title == "Response Headers" }).isEnabled
        )
        XCTAssertFalse(
            try XCTUnwrap(copyItems.first { $0.title == "Response Body" }).isEnabled
        )
        XCTAssertFalse(
            try XCTUnwrap(copyItems.first { $0.title == "Response Cookies" }).isEnabled
        )
        XCTAssertEqual(menu.items[10].title, "Export 2 Flows as HAR…")
        XCTAssertEqual(menu.items[10].action, NSSelectorFromString("exportHAR:"))
        XCTAssertEqual(menu.items[10].representedObject as? [FlowID], [first.id, second.id])
        XCTAssertEqual(menu.items[11].title, "Export 2 Flows as OpenAPI…")
        XCTAssertEqual(menu.items[11].action, NSSelectorFromString("exportOpenAPI:"))
        XCTAssertEqual(menu.items[11].representedObject as? [FlowID], [first.id, second.id])
        let dnsSpoofItem = try XCTUnwrap(
            menu.items.first { $0.action == NSSelectorFromString("dnsSpoof:") }
        )
        XCTAssertEqual(dnsSpoofItem.title, "DNS Spoof api.example.com…")
        XCTAssertEqual(dnsSpoofItem.representedObject as? String, "api.example.com")

        tableView.clickedRowOverride = 2
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 2))
        XCTAssertEqual(menu.items[6].title, "Compare Selected Flows…")
        XCTAssertFalse(menu.items[6].isEnabled)
        XCTAssertEqual(menu.items[10].title, "Export HAR…")
        XCTAssertEqual(menu.items[10].representedObject as? [FlowID], [third.id])
        XCTAssertEqual(menu.items[11].title, "Export OpenAPI…")
        XCTAssertEqual(menu.items[11].representedObject as? [FlowID], [third.id])
    }

    func testFlowComparisonViewExposesRequestAndResponseDiffs() {
        let comparison = TrafficFlowComparison(
            leftTitle: "GET first.example.com/a",
            rightTitle: "POST second.example.com/b",
            request: TrafficMessageComparison(
                rows: TrafficLineDiff.rows(left: "GET /a", right: "POST /b")
            ),
            response: TrafficMessageComparison(
                rows: TrafficLineDiff.rows(left: "HTTP/1.1 200", right: "HTTP/1.1 404")
            )
        )
        let controller = FlowComparisonViewController(comparison: comparison)

        _ = controller.view

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "flowComparison")
        XCTAssertNotNil(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "flowComparison.message" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "flowComparison.presentation" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "flowComparison.left" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "flowComparison.right" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "flowComparison.unified" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "flowComparison.copy" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "flowComparison.export" }
            )
        )
    }

    func testUnifiedDiffRendersHeadersAndModifiedLines() {
        let comparison = TrafficMessageComparison(
            rows: TrafficLineDiff.rows(
                left: "GET /items\nAccept: application/json\n\nold",
                right: "GET /items\nAccept: application/json\n\nnew"
            )
        )

        let diff = TrafficUnifiedDiff.text(
            leftTitle: "GET first.example.com/items",
            rightTitle: "GET second.example.com/items",
            sectionTitle: "Request",
            comparison: comparison
        )

        XCTAssertTrue(diff.hasPrefix("--- GET first.example.com/items\n"))
        XCTAssertTrue(diff.contains("+++ GET second.example.com/items\n"))
        XCTAssertTrue(diff.contains("@@ -1,4 +1,4 @@ Request\n"))
        XCTAssertTrue(diff.contains("  GET /items\n"))
        XCTAssertTrue(diff.contains("- old\n"))
        XCTAssertTrue(diff.contains("+ new\n"))
    }

    func testRequestCodeViewExposesLanguageSelectionSourceAndCopyAction() {
        let controller = RequestCodeViewController(
            snippets: RequestCodeLanguage.allCases.map {
                RequestCodeSnippet(language: $0, source: "// \($0.displayName)")
            }
        )

        _ = controller.view

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "requestCode")
        XCTAssertNotNil(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestCode.language" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestCode.source" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestCode.copy" }
            )
        )
    }

    func testViewModelBuildsCopyValuesFromAuthoritativeFlowData() async throws {
        let flow = try Self.makeFlow(
            index: 17,
            host: "copy.example.com",
            statusCode: 201,
            requestBody: Data(#"{"name":"ProxyLens"}"#.utf8),
            responseBody: Data("created".utf8),
            requestCookieValues: ["session=abc; theme=dark"],
            responseSetCookieValues: ["token=xyz; Secure; HttpOnly"]
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()

        let url = try await viewModel.copyText(for: flow.id, kind: .url)
        let requestHeaders = try await viewModel.copyText(
            for: flow.id, kind: .requestHeaders)
        let requestBody = try await viewModel.copyText(for: flow.id, kind: .requestBody)
        let requestCookies = try await viewModel.copyText(
            for: flow.id, kind: .requestCookies)
        let responseHeaders = try await viewModel.copyText(
            for: flow.id, kind: .responseHeaders)
        let responseBody = try await viewModel.copyText(for: flow.id, kind: .responseBody)
        let responseCookies = try await viewModel.copyText(
            for: flow.id, kind: .responseCookies)

        XCTAssertEqual(url, "https://copy.example.com/v1/items/17?source=test")
        XCTAssertTrue(requestHeaders.contains("POST /v1/items/17?source=test HTTP/1.1"))
        XCTAssertEqual(requestBody, #"{"name":"ProxyLens"}"#)
        XCTAssertEqual(requestCookies, "session=abc\ntheme=dark")
        XCTAssertTrue(responseHeaders.hasPrefix("HTTP/1.1 201 Result"))
        XCTAssertEqual(responseBody, "created")
        XCTAssertEqual(responseCookies, "token=xyz\n  Secure\n  HttpOnly")
    }

    func testFlowTableContextMenuOffersGraphQLOperationBreakpoint() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view
        let flow = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data(
                #"{"query":"mutation SaveProfile { saveProfile { id } }"}"#.utf8
            ),
            method: .post,
            requestContentType: "application/json"
        )
        var store = TrafficConsoleStore()
        store.apply([.finished(flow)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.clickedRowOverride = 0
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let item = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("breakpointGraphQLOperation:")
            }
        )
        XCTAssertEqual(item.title, "Breakpoint GraphQL mutation SaveProfile")
        XCTAssertEqual(
            item.representedObject as? GraphQLOperationMetadata,
            GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )

        let blockItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("blockGraphQLOperation:")
            }
        )
        XCTAssertEqual(blockItem.title, "Block GraphQL mutation SaveProfile")
        XCTAssertEqual(
            blockItem.representedObject as? GraphQLOperationMetadata,
            GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )

        let mapLocalItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("mapLocalGraphQLOperation:")
            }
        )
        XCTAssertEqual(mapLocalItem.title, "Map Local GraphQL mutation SaveProfile…")
        XCTAssertEqual(
            mapLocalItem.representedObject as? GraphQLOperationMetadata,
            GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )

        let mapRemoteItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("mapRemoteGraphQLOperation:")
            }
        )
        XCTAssertEqual(mapRemoteItem.title, "Map Remote GraphQL mutation SaveProfile…")
        XCTAssertEqual(
            mapRemoteItem.representedObject as? GraphQLOperationMetadata,
            GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )

        let genericReplaceBodyItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("replaceBody:")
            }
        )
        XCTAssertEqual(
            genericReplaceBodyItem.title,
            "Replace Request Body api.example.com/v1/items/1…"
        )

        let genericReplaceResponseBodyItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("replaceResponseBody:")
            }
        )
        XCTAssertEqual(
            genericReplaceResponseBodyItem.title,
            "Replace Response Body api.example.com/v1/items/1…"
        )

        let redirectItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("redirect:")
            }
        )
        XCTAssertEqual(redirectItem.title, "Redirect api.example.com/v1/items/1…")

        let networkConditionsItem = try XCTUnwrap(
            menu.items.first { $0.title == "Network Conditions" }
        )
        XCTAssertEqual(
            networkConditionsItem.submenu?.items.map(\.title),
            [
                "No Throttling", "", "Lost Connection", "Very Bad Network", "200 ms Latency",
                "500 ms Latency", "1 s Latency", "2 s Latency", "", "Slow 3G", "Fast 3G",
                "Wi-Fi", "", "Custom…"
            ]
        )

        let replaceBodyItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("replaceBodyGraphQLOperation:")
            }
        )
        XCTAssertEqual(replaceBodyItem.title, "Replace Request Body GraphQL mutation SaveProfile…")
        XCTAssertEqual(
            replaceBodyItem.representedObject as? GraphQLOperationMetadata,
            GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )

        let replaceResponseBodyItem = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("replaceResponseBodyGraphQLOperation:")
            }
        )
        XCTAssertEqual(
            replaceResponseBodyItem.title,
            "Replace Response Body GraphQL mutation SaveProfile…"
        )
        XCTAssertEqual(
            replaceResponseBodyItem.representedObject as? GraphQLOperationMetadata,
            GraphQLOperationMetadata(kind: .mutation, name: "SaveProfile")
        )
    }

    func testFlowTableContextMenuOffersWebSocketResponseBreakpoint() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view
        var flow = try Self.makeFlow(
            index: 1,
            host: "socket.example.com",
            statusCode: 101
        )
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "socket.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        var store = TrafficConsoleStore()
        store.apply([.finished(flow)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.clickedRowOverride = 0
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let item = try XCTUnwrap(
            menu.items.first {
                $0.action == NSSelectorFromString("breakpointWebSocketResponse:")
            }
        )
        XCTAssertEqual(
            item.title,
            "Breakpoint WebSocket responses socket.example.com/v1/items/1"
        )
    }

    func testWebSocketBreakpointPresentsAnEditableHighlightedPayloadAndPreservesDraft()
        throws
    {
        let controller = WebSocketFramesViewController()
        _ = controller.view
        let breakpoint = TrafficWebSocketBreakpointInspection(
            sequenceNumber: 7,
            opcode: .text,
            payload: #"{"event":"ready","ok":true}"#,
            syntax: .json,
            canEditPayload: true,
            statusMessage: "Paused response breakpoint."
        )

        controller.render(nil, breakpoint: breakpoint, resetBreakpoint: true)

        let payloadEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.payload"
                }
            )
        )
        let connectionStatus = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.connectionStatus"
                }
            )
        )
        XCTAssertTrue(payloadEditor.isEditable)
        XCTAssertEqual(payloadEditor.string, breakpoint.payload)
        XCTAssertEqual(
            payloadEditor.accessibilityLabel(),
            "Editable paused WebSocket response payload"
        )
        XCTAssertEqual(connectionStatus.stringValue, "Paused")
        let keyRange = try XCTUnwrap(payloadEditor.string.range(of: #""event""#))
        XCTAssertEqual(
            payloadEditor.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(keyRange, in: payloadEditor.string).location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.key
        )

        payloadEditor.string = #"{"event":"edited"}"#
        controller.render(nil, breakpoint: breakpoint)
        XCTAssertEqual(controller.pendingBreakpointPayloadText(), #"{"event":"edited"}"#)
    }

    func testWebSocketBreakpointKeepsUnsafePayloadsReadOnly() throws {
        let controller = WebSocketFramesViewController()
        _ = controller.view
        controller.render(
            nil,
            breakpoint: TrafficWebSocketBreakpointInspection(
                sequenceNumber: 8,
                opcode: .binary,
                payload: "00000000  00 FF 01",
                syntax: .binary,
                canEditPayload: false,
                statusMessage: "Paused response breakpoint. Binary frames are read-only."
            ),
            resetBreakpoint: true
        )

        let payloadEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.payload"
                }
            )
        )
        XCTAssertFalse(payloadEditor.isEditable)
        XCTAssertNil(controller.pendingBreakpointPayloadText())
        XCTAssertEqual(
            payloadEditor.accessibilityLabel(),
            "Read-only paused WebSocket response payload"
        )
    }

    func testWebSocketBreakpointViewModelLoadsAndContinuesEditedJSONPayload() async throws {
        let coordinator = BreakpointCoordinator()
        let request = HTTPRequest(
            method: .get,
            url: try XCTUnwrap(URL(string: "wss://socket.example.com/events"))
        )
        let response = try HTTPResponse(statusCode: 101, reasonPhrase: "Switching Protocols")
        var flow = Flow(
            sessionID: SessionID(),
            request: request,
            connection: ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "socket.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .connectingUpstream)
        try flow.transition(to: .receivingResponse)
        flow.attachResponse(response)
        try flow.transition(to: .paused(.webSocketResponse))
        let hit = BreakpointHit(
            flowID: flow.id,
            phase: .webSocketResponse,
            request: request,
            response: response,
            webSocketFrame: WebSocketBreakpointFrame(
                sequenceNumber: 3,
                opcode: .text,
                isFinal: true,
                payload: Data(#"{"event":"original"}"#.utf8),
                originalPayloadByteCount: 20,
                maximumEditablePayloadBytes: 1_024 * 1_024
            )
        )
        let pausedDecision = Task { await coordinator.pause(hit) }
        defer { Task { await coordinator.abort(flowID: flow.id) } }
        try await waitUntilAsync { await coordinator.hit(for: flow.id) != nil }

        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            breakpointCoordinator: coordinator
        )
        await viewModel.prepare()
        viewModel.receive(.updated(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            viewModel.snapshot.inspection.breakpoint?.webSocketFrame?.payload
                == #"{"event":"original"}"#
        }
        let presentation = try XCTUnwrap(
            viewModel.snapshot.inspection.breakpoint?.webSocketFrame
        )
        XCTAssertEqual(presentation.syntax, .json)
        XCTAssertTrue(presentation.canEditPayload)

        try await viewModel.continueBreakpoint(
            headersText: "",
            bodyText: nil,
            webSocketPayloadText: #"{"event":"edited"}"#
        )
        let decision = await pausedDecision.value
        guard case .continue(let decidedHit) = decision else {
            return XCTFail("Expected the edited WebSocket frame to continue")
        }
        XCTAssertEqual(
            decidedHit.webSocketFrame?.payload,
            Data(#"{"event":"edited"}"#.utf8)
        )
    }

    func testFlowTableContextMenuOffersReusableAndRemovableNetworkProfiles() throws {
        let tableView = RecordingTableView()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )
        let profileStore = InMemoryTrafficNetworkConditionProfileStore()
        _ = try profileStore.save(
            name: "Office VPN",
            profile: ThrottleProfile(latency: 0.35, downloadBytesPerSecond: 256_000)
        )
        let controller = FlowTableViewController(
            viewModel: viewModel,
            tableView: tableView,
            networkConditionProfileStore: profileStore
        )
        _ = controller.view
        let flow = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200
        )
        var store = TrafficConsoleStore()
        store.apply([.finished(flow)])
        controller.render(store.snapshot(capture: .stopped, inspection: .empty))
        tableView.clickedRowOverride = 0
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let conditions = try XCTUnwrap(
            menu.items.first { $0.title == "Network Conditions" }?.submenu
        )
        let saved = try XCTUnwrap(
            conditions.items.first { $0.title == "Saved Profiles" }?.submenu
        )
        XCTAssertEqual(saved.items.map(\.title), ["Office VPN"])
        XCTAssertEqual(
            saved.items.first?.action,
            NSSelectorFromString("applyNetworkCondition:")
        )
        let removal = try XCTUnwrap(
            conditions.items.first { $0.title == "Remove Saved Profile" }?.submenu
        )
        XCTAssertEqual(removal.items.map(\.title), ["Office VPN"])
        XCTAssertEqual(
            removal.items.first?.action,
            NSSelectorFromString("removeNetworkConditionProfile:")
        )
    }

    func testFlowTablePublishesNativeMultiSelectionAndPrimaryInspection() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()
        let first = try Self.makeFlow(index: 7, host: "first.example.com", statusCode: 200)
        let second = try Self.makeFlow(index: 8, host: "second.example.com", statusCode: 201)
        viewModel.receive(.finished(first))
        viewModel.receive(.finished(second))
        viewModel.flushPendingEvents()

        let tableView = RecordingTableView()
        let controller = FlowTableViewController(viewModel: viewModel, tableView: tableView)
        _ = controller.view
        controller.render(viewModel.snapshot)

        tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

        try await waitUntil {
            viewModel.snapshot.selectedFlowIDs == [first.id, second.id]
                && viewModel.snapshot.inspection.flowID == viewModel.snapshot.selectedFlowID
        }
        XCTAssertTrue(
            viewModel.snapshot.selectedFlowID.map { [first.id, second.id].contains($0) } ?? false
        )
    }

    func testRequestEditorExposesAccessiblePlainTextFieldsAndOnlyReturnsChangedBody() throws {
        let controller = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText: "GET / HTTP/1.1\nHost: api.example.com",
                bodyText: "before",
                canEditBody: true,
                bodyMessage: nil
            )
        )
        _ = controller.view

        XCTAssertEqual(controller.headersText, "GET / HTTP/1.1\nHost: api.example.com")
        XCTAssertEqual(controller.bodyText, "before")
        XCTAssertNil(controller.changedBodyText)
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.headers" }
            )
        )
        XCTAssertNotNil(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.body" }
            )
        )

        controller.bodyText = "after"

        XCTAssertEqual(controller.changedBodyText, "after")

        let binaryController = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText: "POST / HTTP/1.1\nHost: api.example.com",
                bodyText: "",
                canEditBody: false,
                bodyMessage: "Binary request bodies are preserved but cannot be edited"
            )
        )
        _ = binaryController.view
        let binaryBodyEditor = Self.descendant(
            of: NSTextView.self,
            in: binaryController.view,
            matching: { $0.accessibilityIdentifier() == "requestEditor.body" }
        )
        XCTAssertFalse(try XCTUnwrap(binaryBodyEditor).isEditable)
        binaryController.bodyText = "replacement"
        XCTAssertNil(binaryController.changedBodyText)
    }

    func testRequestEditorPrettyPrintsAndHighlightsJSONWithoutTreatingFormattingAsAnEdit()
        async throws
    {
        let controller = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText:
                    "POST /events HTTP/1.1\nHost: api.example.com\nContent-Type: application/json",
                bodyText: #"{"name":"ProxyLens","enabled":true}"#,
                canEditBody: true,
                bodyMessage: nil
            )
        )

        _ = controller.view

        let expected = """
            {
              "enabled" : true,
              "name" : "ProxyLens"
            }
            """
        XCTAssertEqual(controller.bodyText, expected)
        XCTAssertNil(controller.changedBodyText)

        let headersEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.headers" }
            )
        )
        let bodyEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.body" }
            )
        )

        XCTAssertEqual(
            headersEditor.textStorage?.attribute(
                .foregroundColor,
                at: (headersEditor.string as NSString).range(of: "Content-Type").location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.key
        )
        XCTAssertEqual(
            bodyEditor.textStorage?.attribute(
                .foregroundColor,
                at: (bodyEditor.string as NSString).range(of: #""name""#).location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.key
        )

        bodyEditor.string = #"{"count":42}"#
        controller.textDidChange(
            Notification(name: NSText.didChangeNotification, object: bodyEditor)
        )
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(
            bodyEditor.textStorage?.attribute(
                .foregroundColor,
                at: (bodyEditor.string as NSString).range(of: "42").location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.number
        )
        XCTAssertEqual(controller.changedBodyText, #"{"count":42}"#)
    }

    func testRequestEditorImportsCURLIntoTheComposeFields() throws {
        let controller = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText: "GET https://example.com/ HTTP/1.1",
                bodyText: "",
                canEditBody: true,
                bodyMessage: nil
            ),
            allowsCURLImport: true
        )
        _ = controller.view

        XCTAssertNotNil(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.importCURL" }
            )
        )

        try controller.importCURLCommand(
            #"curl 'https://api.example.com/events' -H 'Content-Type: application/json' --data-raw '{"name":"ProxyLens","enabled":true}'"#
        )

        XCTAssertTrue(controller.headersText.hasPrefix("POST https://api.example.com/events"))
        XCTAssertTrue(controller.headersText.contains("Content-Type: application/json"))
        XCTAssertEqual(
            controller.bodyText,
            """
            {
              "enabled" : true,
              "name" : "ProxyLens"
            }
            """
        )
    }

    func testRequestEditorExposesComposerHistoryAndPresetControls() throws {
        let store = InMemoryTrafficRequestComposerStore(
            history: [
                TrafficRequestComposerEntry(
                    kind: .history,
                    name: "Recent request",
                    headersText: "GET https://example.com/ HTTP/1.1",
                    bodyText: ""
                )
            ],
            presets: [
                TrafficRequestComposerEntry(
                    kind: .preset,
                    name: "Demo API",
                    headersText: "POST https://example.com/events HTTP/1.1",
                    bodyText: "{}"
                )
            ]
        )
        let controller = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText: "GET https://example.com/ HTTP/1.1",
                bodyText: "",
                canEditBody: true,
                bodyMessage: nil
            ),
            allowsCURLImport: true,
            composerStore: store
        )
        _ = controller.view

        let historyPopup = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.history" }
            )
        )
        let presetsPopup = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.presets" }
            )
        )
        XCTAssertTrue(historyPopup.itemTitles.contains("Recent request"))
        XCTAssertTrue(presetsPopup.itemTitles.contains("Demo API"))
        historyPopup.menu?.performActionForItem(at: 1)
        XCTAssertTrue(controller.headersText.hasPrefix("GET https://example.com/"))
        presetsPopup.menu?.performActionForItem(at: 1)
        XCTAssertTrue(controller.headersText.hasPrefix("POST https://example.com/events"))
        XCTAssertEqual(controller.bodyText.filter { !$0.isWhitespace }, "{}")
        XCTAssertNotNil(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "requestEditor.savePreset" }
            )
        )
    }

    func testViewModelBatchesLargeFlowListsAndLoadsAuthoritativeBodies() async throws {
        let captureController = RecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        var flows: [Flow] = []
        flows.reserveCapacity(2_000)
        for index in 0..<2_000 {
            let flow = try Self.makeFlow(
                index: index,
                host: "host-\(index % 25).example.com",
                statusCode: 200 + (index % 5)
            )
            flows.append(flow)
            viewModel.receive(.finished(flow))
        }
        viewModel.flushPendingEvents()

        XCTAssertEqual(viewModel.snapshot.allFlowCount, 2_000)
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, 2_000)
        XCTAssertEqual(viewModel.snapshot.domains.count, 25)

        let selected = try Self.makeFlow(
            index: 2_001,
            host: "inspect.example.com",
            statusCode: 201,
            requestBody: Data("request body".utf8),
            responseBody: Data([0, 1, 255])
        )
        viewModel.receive(.finished(selected))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(selected.id)

        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.body else {
                return false
            }
            return true
        }

        guard
            case .content(let requestMetadata, let requestValue) =
                viewModel.snapshot.inspection.request?.body
        else {
            return XCTFail("Expected loaded request body")
        }
        XCTAssertTrue(requestMetadata.contains("12 B"))
        XCTAssertEqual(requestValue, "request body")

        guard
            case .content(let responseMetadata, let responseValue) =
                viewModel.snapshot.inspection.response?.body
        else {
            return XCTFail("Expected loaded response body")
        }
        XCTAssertTrue(responseMetadata.contains("3 B"))
        XCTAssertTrue(responseValue.contains("00000000"))
        XCTAssertTrue(responseValue.contains("00 01 ff"))
    }

    func testViewModelHydratesPersistedWorkspaceAndClearsItOffline() async throws {
        let first = try Self.makeFlow(
            index: 1,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("request body".utf8),
            responseBody: Data("response body".utf8)
        )
        let second = try Self.makeFlow(
            index: 2,
            host: "cdn.example.com",
            statusCode: 404
        )
        let sessionService = RecordingSessionService(flows: [first, second])
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            exportService: ExportService(bodyStore: InlineBodyStore()),
            sessionService: sessionService
        )

        await viewModel.prepare()

        XCTAssertEqual(viewModel.snapshot.allFlowCount, 2)
        XCTAssertEqual(viewModel.snapshot.visibleRows.map(\.id), [first.id, second.id])
        XCTAssertEqual(viewModel.snapshot.capture, .stopped)

        viewModel.selectFlow(first.id)
        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.body else {
                return false
            }
            return true
        }
        guard
            case .content(_, let requestValue) = viewModel.snapshot.inspection.request?.body
        else {
            return XCTFail("Expected loaded request body")
        }
        XCTAssertEqual(requestValue, "request body")

        let command = try await viewModel.curlCommand(for: first.id)
        XCTAssertTrue(command.contains("curl 'https://api.example.com/v1/items/1?source=test'"))
        XCTAssertTrue(command.contains("--data-binary 'request body'"))

        let snippets = try await viewModel.requestCodeSnippets(for: first.id)
        XCTAssertEqual(snippets.map(\.language), RequestCodeLanguage.allCases)
        XCTAssertTrue(
            snippets.first { $0.language == .javascriptFetch }?.source.contains(
                "await fetch(\"https://api.example.com/v1/items/1?source=test\""
            ) == true
        )

        try await viewModel.clearSession()
        let didClear = await sessionService.cleared()
        XCTAssertTrue(didClear)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
        XCTAssertTrue(viewModel.snapshot.visibleRows.isEmpty)
        XCTAssertNil(viewModel.snapshot.selectedFlowID)
        XCTAssertEqual(viewModel.snapshot.inspection, .empty)
    }

    func testViewModelImportsHARAndSelectsTheNewSavedSession() async throws {
        var session = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try session.rename(to: "Imported checkout")
        session.registerFlow()
        session.stop(at: Date(timeIntervalSince1970: 1_001))
        let flow = try Self.makeFlow(
            index: 14,
            host: "imported.example.com",
            statusCode: 201,
            sessionID: session.id
        )
        let harImporter = RecordingHARImporter(
            result: HARImportResult(session: session, flows: [flow])
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            harImporter: harImporter
        )
        await viewModel.prepare()

        let importedSessionID = try await viewModel.importHAR(
            from: URL(fileURLWithPath: "/tmp/imported.har")
        )

        XCTAssertEqual(importedSessionID, session.id)
        XCTAssertEqual(viewModel.snapshot.sessions.map(\.id), [session.id])
        XCTAssertEqual(viewModel.snapshot.selectedSource, .session(session.id))
        XCTAssertEqual(viewModel.snapshot.visibleRows.map(\.id), [flow.id])
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, flow.id)
        let importedURLs = await harImporter.importedURLs()
        XCTAssertEqual(importedURLs, [URL(fileURLWithPath: "/tmp/imported.har")])
    }

    func testViewModelImportsAndExportsPortableSessions() async throws {
        var session = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        try session.rename(to: "Portable checkout")
        session.registerFlow()
        session.stop(at: Date(timeIntervalSince1970: 2_001))
        let flow = try Self.makeFlow(
            index: 15,
            host: "portable.example.com",
            statusCode: 202,
            sessionID: session.id
        )
        let transfer = RecordingPortableSessionTransfer(
            result: PortableSessionImportResult(session: session, flows: [flow])
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            portableSessionTransfer: transfer
        )
        await viewModel.prepare()
        let importURL = URL(fileURLWithPath: "/tmp/imported.proxylens", isDirectory: true)

        let importedSessionID = try await viewModel.importPortableSession(from: importURL)

        XCTAssertEqual(importedSessionID, session.id)
        XCTAssertEqual(viewModel.snapshot.sessions.map(\.id), [session.id])
        XCTAssertEqual(viewModel.snapshot.selectedSource, .session(session.id))
        XCTAssertEqual(viewModel.snapshot.visibleRows.map(\.id), [flow.id])
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, flow.id)
        let exportURL = URL(fileURLWithPath: "/tmp/exported.proxylens", isDirectory: true)
        try await viewModel.writePortableSession(sessionID: session.id, to: exportURL)
        let calls = await transfer.calls()
        XCTAssertEqual(calls.importedURLs, [importURL])
        XCTAssertEqual(calls.exports.map(\.sessionID), [session.id])
        XCTAssertEqual(calls.exports.map(\.fileURL), [exportURL])
    }

    func testViewModelExportsEveryFlowInSessionRegardlessOfVisibleFilters() async throws {
        var selectedSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try selectedSession.rename(to: "Checkout")
        selectedSession.stop(at: Date(timeIntervalSince1970: 1_100))
        var otherSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        otherSession.stop(at: Date(timeIntervalSince1970: 2_100))
        let first = try Self.makeFlow(
            index: 21,
            host: "first.example.com",
            statusCode: 200,
            requestBody: Data(#"{"step":1}"#.utf8),
            requestContentType: "application/json",
            sessionID: selectedSession.id
        )
        let second = try Self.makeFlow(
            index: 22,
            host: "second.example.com",
            statusCode: 201,
            sessionID: selectedSession.id
        )
        let unrelated = try Self.makeFlow(
            index: 23,
            host: "other.example.com",
            statusCode: 204,
            sessionID: otherSession.id
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            exportService: ExportService(bodyStore: InlineBodyStore()),
            sessionService: RecordingSessionService(
                flows: [first, second, unrelated],
                sessions: [selectedSession, otherSession]
            )
        )
        await viewModel.prepare()
        viewModel.setSearchText("no visible flow matches")
        XCTAssertTrue(viewModel.snapshot.visibleRows.isEmpty)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "proxylens-session-export-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("Checkout.har")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try await viewModel.writeHAR(sessionID: selectedSession.id, to: fileURL)

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        let log = try XCTUnwrap(document["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(
            entries.compactMap { ($0["request"] as? [String: Any])?["url"] as? String },
            [
                "https://first.example.com/v1/items/21?source=test",
                "https://second.example.com/v1/items/22?source=test"
            ]
        )
    }

    func testViewModelExportsSelectedFlowsInRequestedVisibleOrder() async throws {
        let first = try Self.makeFlow(
            index: 31,
            host: "first.example.com",
            statusCode: 200,
            requestBody: Data(#"{"selected":1}"#.utf8),
            requestContentType: "application/json"
        )
        let second = try Self.makeFlow(
            index: 32,
            host: "second.example.com",
            statusCode: 201
        )
        let unselected = try Self.makeFlow(
            index: 33,
            host: "unselected.example.com",
            statusCode: 202
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            exportService: ExportService(bodyStore: InlineBodyStore())
        )
        await viewModel.prepare()
        for flow in [first, second, unselected] {
            viewModel.receive(.finished(flow))
        }
        viewModel.flushPendingEvents()
        viewModel.selectFlows([second.id, first.id], primary: second.id)

        XCTAssertEqual(viewModel.snapshot.selectedFlowIDs, [first.id, second.id])
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, second.id)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "proxylens-selected-export-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("Selected.har")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try await viewModel.writeHAR(flowIDs: viewModel.snapshot.selectedFlowIDs, to: fileURL)

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        let log = try XCTUnwrap(document["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(
            entries.compactMap { ($0["request"] as? [String: Any])?["url"] as? String },
            [
                "https://first.example.com/v1/items/31?source=test",
                "https://second.example.com/v1/items/32?source=test"
            ]
        )
    }

    func testViewModelBuildsComparisonForExactlyTwoFlows() async throws {
        let first = try Self.makeFlow(
            index: 41,
            host: "first.example.com",
            statusCode: 200,
            requestBody: Data("{\n  \"value\": 1\n}".utf8),
            responseBody: Data("first response".utf8),
            responseContentType: "text/plain",
            requestContentType: "application/json"
        )
        let second = try Self.makeFlow(
            index: 42,
            host: "second.example.com",
            statusCode: 201,
            requestBody: Data("{\n  \"value\": 2\n}".utf8),
            responseBody: Data("second response".utf8),
            responseContentType: "text/plain",
            requestContentType: "application/json"
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()
        viewModel.receive(.finished(first))
        viewModel.receive(.finished(second))
        viewModel.flushPendingEvents()

        let comparison = try await viewModel.comparison(
            flowIDs: [second.id, first.id]
        )

        XCTAssertTrue(comparison.leftTitle.contains("second.example.com"))
        XCTAssertTrue(comparison.rightTitle.contains("first.example.com"))
        XCTAssertTrue(
            comparison.request.rows.contains {
                $0.leftText?.contains("\"value\": 2") == true
                    && $0.rightText?.contains("\"value\": 1") == true
                    && $0.kind == .modified
            }
        )
        XCTAssertTrue(
            comparison.response.rows.contains {
                $0.leftText == "second response"
                    && $0.rightText == "first response"
                    && $0.kind == .modified
            }
        )

        do {
            _ = try await viewModel.comparison(flowIDs: [first.id])
            XCTFail("Expected comparing fewer than two flows to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exactly two"))
        }
    }

    func testViewModelHydratesRenamesAndDeletesSavedSessions() async throws {
        var session = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        session.stop(at: Date(timeIntervalSince1970: 1_100))
        let flow = try Self.makeFlow(
            index: 12,
            host: "session.example.com",
            statusCode: 200,
            sessionID: session.id
        )
        let sessionService = RecordingSessionService(
            flows: [flow],
            sessions: [session]
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            sessionService: sessionService
        )

        await viewModel.prepare()

        XCTAssertEqual(viewModel.snapshot.sessions.map(\.id), [session.id])
        try await viewModel.renameSession(session.id, to: "Payments investigation")
        XCTAssertEqual(viewModel.snapshot.sessions.first?.name, "Payments investigation")

        viewModel.selectSource(.session(session.id))
        viewModel.selectFlow(flow.id)
        try await viewModel.deleteSession(session.id)

        XCTAssertTrue(viewModel.snapshot.sessions.isEmpty)
        XCTAssertEqual(viewModel.snapshot.selectedSource, .allTraffic)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
        XCTAssertEqual(viewModel.snapshot.inspection, .empty)
        let removedSessionIDs = await sessionService.removedSessionIDs()
        XCTAssertEqual(removedSessionIDs, [session.id])
    }

    func testViewModelPersistsAnnotationsAndRefreshesSelectedInspector() async throws {
        let flow = try Self.makeFlow(
            index: 8,
            host: "annotations.example.com",
            statusCode: 200
        )
        let sessionService = RecordingSessionService(flows: [flow])
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            sessionService: sessionService
        )
        await viewModel.prepare()
        viewModel.selectFlow(flow.id)
        let annotation = try FlowAnnotation(
            comment: "Useful response",
            highlight: .green,
            isStruckThrough: false
        )

        try await viewModel.updateAnnotation(annotation, for: flow.id)

        XCTAssertEqual(viewModel.snapshot.visibleRows.first?.annotation, annotation)
        XCTAssertEqual(viewModel.snapshot.inspection.annotation, annotation)
        var annotationFilter = TrafficDisplayFilter(annotation: .green)
        viewModel.setAnnotationFilter(annotationFilter.annotation)
        XCTAssertEqual(viewModel.snapshot.visibleRows.map(\.id), [flow.id])

        annotationFilter.annotation = .red
        viewModel.setAnnotationFilter(annotationFilter.annotation)
        XCTAssertTrue(viewModel.snapshot.visibleRows.isEmpty)
        XCTAssertNil(viewModel.snapshot.selectedFlowID)
        XCTAssertEqual(viewModel.snapshot.inspection, .empty)
    }

    func testViewModelStopsCaptureAndDropsPendingEventsWhenClearingTheSession() async throws {
        let persisted = try Self.makeFlow(index: 1, host: "api.example.com", statusCode: 200)
        let pending = try Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 404)
        let sessionService = RecordingSessionService(flows: [persisted])
        let captureController = RecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            sessionService: sessionService
        )

        await viewModel.prepare()
        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }
        viewModel.receive(.finished(pending))
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 1)

        try await viewModel.clearSession()

        XCTAssertEqual(viewModel.snapshot.capture, .stopped)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
        XCTAssertTrue(viewModel.snapshot.visibleRows.isEmpty)
        let didClear = await sessionService.cleared()
        XCTAssertTrue(didClear)
        let calls = await captureController.calls()
        XCTAssertEqual(calls, ["recover", "start", "stop"])

        viewModel.flushPendingEvents()
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
    }

    func testViewModelSurfacesWorkspaceHydrationFailures() async throws {
        let sessionService = RecordingSessionService(
            loadError: ProxyLensError.unsupportedOperation("The capture database could not be read")
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            sessionService: sessionService
        )

        await viewModel.prepare()

        XCTAssertEqual(viewModel.snapshot.capture, .stopped)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 0)
        XCTAssertEqual(
            viewModel.snapshot.workspaceWarning,
            "Could not restore the previous session: Unsupported operation: The capture database could not be read"
        )
    }

    func testViewModelPublishesCertificateTrustAndRefreshesAfterInstall() async throws {
        let trust = RecordingCertificateTrust(state: .untrusted)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            certificateTrust: trust
        )

        await viewModel.prepare()
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)

        try await viewModel.installCertificateTrust()
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .trusted)
        let calls = await trust.calls()
        XCTAssertEqual(calls, ["state", "install", "state"])
    }

    func testViewModelSwallowsCertificateTrustCancellationAndSurfacesFailures() async throws {
        let trust = RecordingCertificateTrust(state: .untrusted)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            certificateTrust: trust
        )

        await viewModel.prepare()
        await trust.failNextInstall(CertificateTrustError.userCancelled)
        try await viewModel.installCertificateTrust()
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)

        await trust.failNextInstall(
            ProxyLensError.unsupportedOperation("The trust settings could not be updated")
        )
        do {
            try await viewModel.installCertificateTrust()
            XCTFail("Expected a trust failure to be surfaced")
        } catch let error as ProxyLensError {
            XCTAssertEqual(
                error,
                .unsupportedOperation("The trust settings could not be updated")
            )
        }
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-trust-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try await viewModel.exportRootCertificate(to: exportURL)
        XCTAssertEqual(viewModel.snapshot.certificateTrust, .untrusted)
        let exported = await trust.exportedURLs()
        XCTAssertEqual(exported, [exportURL])
    }

    func testCaptureControlPresentsRecoveryStartAndStopTransitions() async throws {
        let captureController = RecordingCaptureController()
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )

        await viewModel.prepare()
        XCTAssertEqual(viewModel.snapshot.capture, .stopped)

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }
        guard case .running(let context, _) = viewModel.snapshot.capture else {
            return XCTFail("Expected capture to be running")
        }
        XCTAssertEqual(context.endpoint, NetworkEndpoint(host: "127.0.0.1", port: 59_090))

        viewModel.toggleCapture()
        try await waitUntil {
            viewModel.snapshot.capture == .stopped
        }
        let calls = await captureController.calls()
        XCTAssertEqual(calls, ["recover", "start", "stop"])
    }

    func testCaptureControlRefreshesSavedSessionsAfterStartAndStop() async throws {
        let sessionService = RecordingSessionService()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            sessionService: sessionService
        )

        await viewModel.prepare()
        let initialLoadCount = await sessionService.loadSessionsCallCount()
        XCTAssertEqual(initialLoadCount, 1)

        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }
        let loadCountAfterStart = await sessionService.loadSessionsCallCount()
        XCTAssertEqual(loadCountAfterStart, 2)

        viewModel.toggleCapture()
        try await waitUntil {
            viewModel.snapshot.capture == .stopped
        }
        let loadCountAfterStop = await sessionService.loadSessionsCallCount()
        XCTAssertEqual(loadCountAfterStop, 3)
    }

    func testCaptureControlKeepsStopAvailableAfterProxyRestoreFailure() async throws {
        let restoreError = CaptureCoordinatorError.stopFailed(
            stage: .systemProxyRestoration,
            message: "Previous proxy settings are temporarily unavailable"
        )
        let captureController = RecordingCaptureController(stopError: restoreError)
        let viewModel = TrafficConsoleViewModel(
            captureController: captureController,
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration
        )

        await viewModel.prepare()
        viewModel.toggleCapture()
        try await waitUntil {
            if case .running = viewModel.snapshot.capture {
                return true
            }
            return false
        }

        viewModel.toggleCapture()
        try await waitUntil {
            guard case .running(_, let warning) = viewModel.snapshot.capture else {
                return false
            }
            return warning?.contains("systemProxyRestoration") == true
        }

        viewModel.toggleCapture()
        try await waitUntil {
            viewModel.snapshot.capture == .stopped
        }
        let calls = await captureController.calls()
        XCTAssertEqual(calls, ["recover", "start", "stop", "stop"])
    }

    func testViewModelObservesPublishedFlowEvents() async throws {
        let eventBus = FlowEventBus()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: eventBus,
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .milliseconds(1)
        )
        await viewModel.prepare()
        try await waitUntilAsync {
            await eventBus.subscriptionCount() == 1
        }

        let flow = try Self.makeFlow(index: 5, host: "stream.example.com", statusCode: 202)
        await eventBus.publish(.finished(flow))

        try await waitUntil {
            viewModel.snapshot.visibleRows.map(\.id) == [flow.id]
        }
    }

    func testViewModelComposesARequestIntoTheCurrentWorkspace() async throws {
        let sessionID = SessionID()
        let replayed = try Self.makeFlow(
            index: 40,
            host: "api.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let sessionService = RecordingSessionService(composeSessionID: sessionID)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer,
            sessionService: sessionService
        )
        await viewModel.prepare()

        let replayedID = try await viewModel.composeRequest(
            headersText: """
                POST https://api.example.com/v1/events HTTP/1.1
                Content-Type: application/json
                """,
            bodyText: #"{"name":"ProxyLens"}"#
        )

        XCTAssertEqual(replayedID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, replayed.id)
        let received = await replayer.receivedRequests()
        let request = try XCTUnwrap(received.first?.request)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/events")
        XCTAssertEqual(request.body?.inlineData, Data(#"{"name":"ProxyLens"}"#.utf8))
        XCTAssertEqual(
            request.headers.firstValue(for: "Content-Length"),
            "20"
        )
        XCTAssertEqual(received.first?.sessionID, sessionID)
        let composeSessionRequestCount = await sessionService.composeSessionRequestCount()
        XCTAssertEqual(composeSessionRequestCount, 1)

        do {
            try await viewModel.composeRequest(
                headersText: "GET /relative HTTP/1.1\nHost: api.example.com",
                bodyText: nil
            )
            XCTFail("Expected a relative composed target to be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid HTTP message: A composed request must use an absolute HTTP or HTTPS URL"
            )
        }
        let requestsAfterInvalidInput = await replayer.receivedRequests()
        let sessionsAfterInvalidInput = await sessionService.composeSessionRequestCount()
        XCTAssertEqual(requestsAfterInvalidInput.count, 1)
        XCTAssertEqual(sessionsAfterInvalidInput, 1)
    }

    func testViewModelRepeatsAFlowAndSelectsTheVisibleReplayResult() async throws {
        let original = try Self.makeFlow(
            index: 41,
            host: "api.example.com",
            statusCode: 200
        )
        let replayed = try Self.makeFlow(
            index: 42,
            host: "api.example.com",
            statusCode: 202,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()
        viewModel.setOriginFilter(.desktopProxy)

        let replayedID = try await viewModel.repeatRequest(flowID: original.id)

        XCTAssertEqual(replayedID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.allFlowCount, 2)
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.displayFilter, .all)
        XCTAssertEqual(viewModel.snapshot.selectedSource, .allTraffic)
        XCTAssertEqual(viewModel.snapshot.inspection.flowID, replayed.id)
        let received = await replayer.receivedRequests()
        XCTAssertEqual(received.map(\.request), [original.request])
        XCTAssertEqual(received.map(\.sessionID), [original.sessionID])
    }

    func testViewModelBuildsARequestDraftAndRepeatsTheEditedRequest() async throws {
        let original = try Self.makeFlow(
            index: 43,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("before".utf8),
            method: .post
        )
        let replayed = try Self.makeFlow(
            index: 44,
            host: "staging.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)
        let replayedID = try await viewModel.editAndRepeat(
            flowID: original.id,
            headersText: """
                PUT /v2/users/42 HTTP/1.1
                Host: staging.example.com
                Content-Type: text/plain
                X-Debug: enabled
                """,
            bodyText: "after"
        )

        XCTAssertEqual(draft.headersText, HTTPMessageText.requestHeaders(original.request))
        XCTAssertEqual(draft.bodyText, "before")
        XCTAssertTrue(draft.canEditBody)
        XCTAssertNil(draft.bodyMessage)
        XCTAssertEqual(replayedID, replayed.id)
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, replayed.id)
        let received = await replayer.receivedRequests()
        let editedRequest = try XCTUnwrap(received.first?.request)
        XCTAssertEqual(editedRequest.method, .put)
        XCTAssertEqual(editedRequest.url.absoluteString, "https://staging.example.com/v2/users/42")
        XCTAssertEqual(editedRequest.headers.firstValue(for: "X-Debug"), "enabled")
        XCTAssertEqual(editedRequest.body?.inlineData, Data("after".utf8))
        XCTAssertEqual(received.first?.sessionID, original.sessionID)
    }

    func testViewModelEditsAndReencodesAGzipJSONRequestBody() async throws {
        let compressedBody = try XCTUnwrap(
            Data(base64Encoded: "H4sIAAAAAAAC/6tWKkvMKU1VslJKSk3LL0pVqgUAy2iO6hIAAAA=")
        )
        let original = try Self.makeFlow(
            index: 47,
            host: "api.example.com",
            statusCode: 200,
            requestBody: compressedBody,
            method: .post,
            requestContentType: "application/json",
            requestContentEncoding: "gzip"
        )
        let replayed = try Self.makeFlow(
            index: 48,
            host: "api.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)
        let replayedID = try await viewModel.editAndRepeat(
            flowID: original.id,
            headersText: draft.headersText,
            bodyText: #"{"value":"after"}"#
        )

        XCTAssertTrue(draft.canEditBody)
        XCTAssertEqual(draft.bodyText, #"{"value":"before"}"#)
        XCTAssertNil(draft.bodyMessage)
        XCTAssertEqual(replayedID, replayed.id)
        let received = await replayer.receivedRequests()
        let editedRequest = try XCTUnwrap(received.first?.request)
        let editedBody = try XCTUnwrap(editedRequest.body?.inlineData)
        XCTAssertEqual(editedRequest.headers.firstValue(for: "Content-Encoding"), "gzip")
        XCTAssertEqual(
            editedRequest.headers.firstValue(for: "Content-Length"),
            "\(editedBody.count)"
        )
        guard
            case .prettyPrinted(let editedJSON) = JSONBodyView.render(
                data: editedBody,
                contentType: editedRequest.headers.firstValue(for: "Content-Type"),
                contentEncoding: editedRequest.headers.firstValue(for: "Content-Encoding")
            )
        else {
            return XCTFail("Expected the edited body to remain valid gzip JSON")
        }
        XCTAssertTrue(editedJSON.contains(#""value" : "after""#))
    }

    func testViewModelDoesNotLoadAnOversizedBodyIntoTheRequestEditor() async throws {
        let original = try Self.makeFlow(
            index: 45,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("ninebytes".utf8)
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            maximumEditableRequestBodyBytes: 8
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)

        XCTAssertEqual(draft.bodyText, "")
        XCTAssertFalse(draft.canEditBody)
        XCTAssertEqual(draft.bodyMessage, "Body editing is limited to 8 bytes")
    }

    func testViewModelRejectsAnEditedBodyThatExceedsTheEditorLimit() async throws {
        let original = try Self.makeFlow(
            index: 49,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data("before".utf8)
        )
        let replayed = try Self.makeFlow(
            index: 50,
            host: "api.example.com",
            statusCode: 201,
            source: .replay
        )
        let replayer = RecordingRequestReplayer(result: replayed)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            maximumEditableRequestBodyBytes: 8,
            requestReplayer: replayer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        do {
            try await viewModel.editAndRepeat(
                flowID: original.id,
                headersText: HTTPMessageText.requestHeaders(original.request),
                bodyText: "ninebytes"
            )
            XCTFail("Expected the oversized edit to be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported operation: Body editing is limited to 8 bytes"
            )
        }
        let received = await replayer.receivedRequests()
        XCTAssertTrue(received.isEmpty)
    }

    func testViewModelPreservesABinaryBodyOutsideTheTextRequestEditor() async throws {
        let original = try Self.makeFlow(
            index: 46,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data([0x00, 0xFF, 0x01])
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()

        let draft = try await viewModel.requestEditDraft(flowID: original.id)

        XCTAssertEqual(draft.bodyText, "")
        XCTAssertFalse(draft.canEditBody)
        XCTAssertEqual(
            draft.bodyMessage,
            "Binary request bodies are preserved but cannot be edited"
        )
    }

    func testTrafficConsoleHidesWindowTitleAndInspectorWithoutSelection() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 12,
            host: "api.example.com",
            statusCode: 200
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        XCTAssertNil(viewModel.snapshot.selectedFlowID)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ProxyLens"
        window.contentViewController = controller
        window.setContentSize(frame.size)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        let detailSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.split.detail" }
            )
        )
        let flowPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.flows" }
            )
        )
        let inspectorPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.inspector" }
            )
        )
        XCTAssertEqual(flowPane.frame.height, detailSplit.bounds.height, accuracy: 1)
        XCTAssertTrue(inspectorPane.visibleRect.isEmpty)

        let titlebarRoot = try XCTUnwrap(window.contentView?.superview)
        let title = Self.descendant(
            of: NSTextField.self,
            in: titlebarRoot,
            matching: { $0.accessibilityIdentifier() == "window.title.centered" }
        )
        XCTAssertNil(title)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertNil(window.toolbar)

        let composeButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "request.compose" }
            )
        )
        XCTAssertEqual(composeButton.title, "Compose Request…")
        XCTAssertEqual(composeButton.action, NSSelectorFromString("composeRequest:"))
        XCTAssertEqual(composeButton.keyEquivalent, "n")
        XCTAssertEqual(composeButton.keyEquivalentModifierMask, [.command])

        let rulesButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "rules.manage" }
            )
        )
        XCTAssertEqual(rulesButton.accessibilityLabel(), "Manage Rules")
        XCTAssertEqual(rulesButton.action, NSSelectorFromString("showRules"))

        let importHARButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "session.import" }
            )
        )
        XCTAssertEqual(importHARButton.title, "Import…")
        XCTAssertEqual(importHARButton.accessibilityLabel(), "Import ProxyLens session or HAR file")
        XCTAssertEqual(importHARButton.action, NSSelectorFromString("importSession:"))
        XCTAssertEqual(importHARButton.keyEquivalent, "o")
        XCTAssertEqual(importHARButton.keyEquivalentModifierMask, [.command])

        viewModel.selectFlow(flow.id)
        try await waitUntil {
            viewModel.snapshot.selectedFlowID == flow.id
                && !inspectorPane.visibleRect.isEmpty
                && inspectorPane.frame.height >= 240
        }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            flowPane.frame.height / detailSplit.bounds.height,
            0.36,
            accuracy: 0.05
        )

        let requestedInspectorHeight: CGFloat = 280
        detailSplit.setPosition(
            detailSplit.bounds.height
                - detailSplit.dividerThickness
                - requestedInspectorHeight,
            ofDividerAt: 0
        )
        controller.view.layoutSubtreeIfNeeded()
        let rememberedInspectorHeight = inspectorPane.frame.height
        XCTAssertEqual(rememberedInspectorHeight, requestedInspectorHeight, accuracy: 1)

        viewModel.selectFlow(nil)
        try await waitUntil {
            viewModel.snapshot.selectedFlowID == nil
                && inspectorPane.visibleRect.isEmpty
                && abs(flowPane.frame.height - detailSplit.bounds.height) <= 1
        }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(flowPane.frame.height, detailSplit.bounds.height, accuracy: 1)
        XCTAssertTrue(inspectorPane.visibleRect.isEmpty)

        viewModel.selectFlow(flow.id)
        try await waitUntil {
            viewModel.snapshot.selectedFlowID == flow.id
                && !inspectorPane.visibleRect.isEmpty
        }
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(inspectorPane.frame.height, rememberedInspectorHeight, accuracy: 1)
    }

    func testTrafficConsoleTogglesSourceListAndRendersPinnedDomains() async throws {
        let pinnedDomainsStore = InMemoryTrafficPinnedDomainsStore(
            domains: ["offline.example.com"]
        )
        let sourceListVisibilityStore = InMemoryTrafficSourceListVisibilityStore()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            pinnedDomainsStore: pinnedDomainsStore
        )
        await viewModel.prepare()
        let flow = try Self.makeFlow(
            index: 13,
            host: "api.example.com",
            statusCode: 200
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(
            viewModel: viewModel,
            sourceListVisibilityStore: sourceListVisibilityStore
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(frame.size)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()

        let sourcePane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.sources" }
            )
        )
        let sourceOutline = try XCTUnwrap(
            Self.descendant(
                of: NSOutlineView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.sources" }
            )
        )
        let sourceToggle = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "sourceList.toggle" }
            )
        )
        let sourceLabels = (0..<sourceOutline.numberOfRows).compactMap { row in
            sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .accessibilityLabel()
        }
        XCTAssertTrue(sourceLabels.contains("Pinned, 1 domain"))
        XCTAssertTrue(sourceLabels.contains("api.example.com, 1 flow"))
        XCTAssertTrue(sourceLabels.contains("offline.example.com, 0 flows"))
        let apiRow = try XCTUnwrap(
            (0..<sourceOutline.numberOfRows).first { row in
                sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                    .accessibilityLabel() == "api.example.com, 1 flow"
            }
        )
        sourceOutline.selectRowIndexes(IndexSet(integer: apiRow), byExtendingSelection: false)
        let sourceMenu = try XCTUnwrap(sourceOutline.menu)
        let menuDelegate = try XCTUnwrap(sourceMenu.delegate as? SourceListViewController)
        menuDelegate.menuNeedsUpdate(sourceMenu)
        let pinItem = try XCTUnwrap(sourceMenu.items.first)
        XCTAssertEqual(pinItem.title, "Pin Domain")
        XCTAssertEqual(pinItem.representedObject as? String, "api.example.com")
        let pinAction = try XCTUnwrap(pinItem.action)
        XCTAssertTrue(NSApp.sendAction(pinAction, to: pinItem.target, from: pinItem))
        XCTAssertEqual(
            viewModel.snapshot.pinnedDomains.map(\.host),
            [
                "api.example.com", "offline.example.com"
            ])
        XCTAssertEqual(
            pinnedDomainsStore.domains,
            ["api.example.com", "offline.example.com"]
        )
        let updatedSourceLabels = (0..<sourceOutline.numberOfRows).compactMap { row in
            sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .accessibilityLabel()
        }
        XCTAssertTrue(updatedSourceLabels.contains("Pinned, 2 domains"))
        XCTAssertFalse(sourcePane.visibleRect.isEmpty)
        XCTAssertEqual(sourceToggle.accessibilityLabel(), "Hide Source List")

        sourceToggle.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(sourcePane.visibleRect.isEmpty)
        XCTAssertFalse(sourceListVisibilityStore.isVisible)
        XCTAssertEqual(sourceToggle.accessibilityLabel(), "Show Source List")

        sourceToggle.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(sourcePane.visibleRect.isEmpty)
        XCTAssertTrue(sourceListVisibilityStore.isVisible)
        XCTAssertEqual(sourceToggle.accessibilityLabel(), "Hide Source List")
    }

    func testTrafficConsoleRendersSavedSessionsWithStateAndProtectedActions() async throws {
        var stoppedSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try stoppedSession.rename(to: "Payments investigation")
        stoppedSession.stop(at: Date(timeIntervalSince1970: 1_100))
        var recordingSession = Session(
            id: SessionID(),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        try recordingSession.rename(to: "Live capture")
        let stoppedFlow = try Self.makeFlow(
            index: 17,
            host: "payments.example.com",
            statusCode: 200,
            sessionID: stoppedSession.id
        )
        let recordingFlow = try Self.makeFlow(
            index: 18,
            host: "live.example.com",
            statusCode: 202,
            sessionID: recordingSession.id
        )
        let sessionService = RecordingSessionService(
            flows: [stoppedFlow, recordingFlow],
            sessions: [stoppedSession, recordingSession]
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            sessionService: sessionService
        )
        await viewModel.prepare()

        let controller = SourceListViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sourceOutline = try XCTUnwrap(
            Self.descendant(
                of: NSOutlineView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.sources" }
            )
        )
        let sourceLabels = (0..<sourceOutline.numberOfRows).compactMap { row in
            sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .accessibilityLabel()
        }
        XCTAssertTrue(sourceLabels.contains("Sessions, 2 sessions"))
        XCTAssertTrue(
            sourceLabels.contains("Live capture, Recording, 1 flow")
        )
        XCTAssertTrue(
            sourceLabels.contains("Payments investigation, Stopped, 1 flow")
        )

        let stoppedRow = try XCTUnwrap(
            (0..<sourceOutline.numberOfRows).first { row in
                sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                    .accessibilityLabel()
                    == "Payments investigation, Stopped, 1 flow"
            }
        )
        sourceOutline.selectRowIndexes(IndexSet(integer: stoppedRow), byExtendingSelection: false)
        XCTAssertEqual(viewModel.snapshot.selectedSource, .session(stoppedSession.id))
        XCTAssertEqual(viewModel.snapshot.visibleRows.map(\.id), [stoppedFlow.id])
        let sourceMenu = try XCTUnwrap(sourceOutline.menu)
        controller.menuNeedsUpdate(sourceMenu)
        XCTAssertEqual(
            sourceMenu.items.map(\.title),
            [
                "Export ProxyLens Session…", "Export Session as HAR…", "",
                "Rename Session…", "Delete Session…"
            ]
        )
        XCTAssertEqual(
            sourceMenu.items.first?.action,
            NSSelectorFromString("exportPortableSession:")
        )
        XCTAssertEqual(sourceMenu.items[1].action, NSSelectorFromString("exportSessionHAR:"))
        XCTAssertTrue(sourceMenu.items[0].isEnabled)
        XCTAssertTrue(sourceMenu.items[1].isEnabled)
        XCTAssertTrue(sourceMenu.items[3].isEnabled)
        XCTAssertTrue(sourceMenu.items[4].isEnabled)

        let recordingRow = try XCTUnwrap(
            (0..<sourceOutline.numberOfRows).first { row in
                sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                    .accessibilityLabel()
                    == "Live capture, Recording, 1 flow"
            }
        )
        sourceOutline.selectRowIndexes(
            IndexSet(integer: recordingRow),
            byExtendingSelection: false
        )
        controller.menuNeedsUpdate(sourceMenu)
        XCTAssertTrue(sourceMenu.items[0].isEnabled)
        XCTAssertTrue(sourceMenu.items[1].isEnabled)
        XCTAssertFalse(sourceMenu.items[3].isEnabled)
        XCTAssertFalse(sourceMenu.items[4].isEnabled)
    }

    func testTrafficConsoleRendersSplitMessageInspector() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let safariSource = FlowSource(
            kind: .desktopProxy,
            label: "Safari",
            application: FlowApplication(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundlePath: "/System/Applications/Safari.app",
                processIdentifier: 501
            )
        )
        let flows = try [
            Self.makeFlow(
                index: 1,
                host: "api.example.com",
                statusCode: 201,
                source: safariSource
            ),
            Self.makeFlow(index: 2, host: "cdn.example.com", statusCode: 304),
            Self.makeFlow(
                index: 3,
                host: "api.example.com",
                statusCode: 404,
                requestBody: Data("{\"query\":\"proxylens\"}".utf8),
                responseBody: Data("{\"error\":\"not found\"}".utf8),
                requestCookieValues: ["session=abc123; theme=dark; token=a=b"],
                responseSetCookieValues: [
                    "session=updated; Path=/; HttpOnly; Secure",
                    "theme=light; Max-Age=3600; SameSite=Lax"
                ]
            ),
            Self.makeFlow(index: 4, host: "auth.example.net", statusCode: 500)
        ]
        for flow in flows {
            viewModel.receive(.finished(flow))
        }
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flows[2].id)
        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.body else {
                return false
            }
            return true
        }
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, flows.count)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(frame.size)
        controller.view.frame = NSRect(origin: .zero, size: frame.size)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()

        let sourceOutline = try XCTUnwrap(
            Self.descendant(
                of: NSOutlineView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.sources" }
            )
        )
        let flowTable = try XCTUnwrap(
            Self.descendant(
                of: NSTableView.self,
                in: controller.view,
                matching: { !($0 is NSOutlineView) }
            )
        )
        XCTAssertEqual(
            flowTable.tableColumns.map(\.title),
            ["Method", "Host", "Path", "Query", "Status", "Time", "Duration", "Size"]
        )
        let requestInspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request.content" }
            )
        )
        let responseInspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.response.content" }
            )
        )
        let searchField = try XCTUnwrap(
            Self.descendant(
                of: NSSearchField.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.search" }
            )
        )
        let clearButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.filter.clear" }
            )
        )
        let rootSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.split.root" }
            )
        )
        let detailSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.split.detail" }
            )
        )
        XCTAssertTrue(rootSplit.isVertical)
        XCTAssertFalse(detailSplit.isVertical)
        let sourcePane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.sources" }
            )
        )
        let flowPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.flows" }
            )
        )
        let inspectorPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.inspector" }
            )
        )

        let sourcePaneFrame = sourcePane.convert(sourcePane.bounds, to: controller.view)
        let workspaceFrame = detailSplit.convert(detailSplit.bounds, to: controller.view)
        XCTAssertGreaterThanOrEqual(sourcePaneFrame.width, 250)
        XCTAssertGreaterThanOrEqual(sourcePaneFrame.minY, workspaceFrame.minY)
        XCTAssertLessThanOrEqual(sourcePaneFrame.maxY, workspaceFrame.maxY)
        XCTAssertGreaterThan(sourcePaneFrame.height, workspaceFrame.height * 0.9)

        let flowPaneFrame = flowPane.convert(flowPane.bounds, to: controller.view)
        let inspectorPaneFrame = inspectorPane.convert(inspectorPane.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(sourcePaneFrame.maxX, flowPaneFrame.minX)
        XCTAssertEqual(flowPaneFrame.minX, inspectorPaneFrame.minX, accuracy: 1)
        XCTAssertEqual(flowPaneFrame.width, inspectorPaneFrame.width, accuracy: 1)
        XCTAssertGreaterThan(flowPaneFrame.minY, inspectorPaneFrame.minY)
        XCTAssertLessThanOrEqual(inspectorPaneFrame.maxY, flowPaneFrame.minY)
        XCTAssertEqual(
            flowPaneFrame.height / workspaceFrame.height,
            0.36,
            accuracy: 0.05
        )

        let messageSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.split.messages"
                }
            )
        )
        let requestPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request" }
            )
        )
        let responsePane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.response" }
            )
        )
        XCTAssertTrue(messageSplit.isVertical)
        let requestPaneFrame = requestPane.convert(requestPane.bounds, to: inspectorPane)
        let responsePaneFrame = responsePane.convert(responsePane.bounds, to: inspectorPane)
        XCTAssertLessThanOrEqual(requestPaneFrame.maxX, responsePaneFrame.minX)
        XCTAssertEqual(requestPaneFrame.minY, responsePaneFrame.minY, accuracy: 1)
        XCTAssertEqual(requestPaneFrame.height, responsePaneFrame.height, accuracy: 1)
        XCTAssertEqual(
            requestPaneFrame.width,
            responsePaneFrame.width,
            accuracy: 2,
            "request=\(requestPaneFrame) response=\(responsePaneFrame) split=\(messageSplit.bounds) inspector=\(inspectorPane.bounds)"
        )

        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        let requestSectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let responseSectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.section"
                }
            )
        )
        let requestCompactSectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section.compact"
                }
            )
        )
        let responseCompactSectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.section.compact"
                }
            )
        )
        let summaryMethod = Self.descendant(
            of: NSTextField.self,
            in: controller.view,
            matching: { $0.accessibilityIdentifier() == "inspector.summary.method" }
        )
        let summaryStatus = Self.descendant(
            of: NSTextField.self,
            in: controller.view,
            matching: { $0.accessibilityIdentifier() == "inspector.summary.status" }
        )
        let summaryURL = Self.descendant(
            of: NSTextField.self,
            in: controller.view,
            matching: { $0.accessibilityIdentifier() == "inspector.summary.url" }
        )
        XCTAssertLessThan(modeSelector.frame.width, inspectorPaneFrame.width / 2)
        XCTAssertTrue(requestSectionSelector.isHidden)
        XCTAssertFalse(requestCompactSectionSelector.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(requestCompactSectionSelector.selectedItem?.title, "Headers")
        XCTAssertTrue(responseSectionSelector.isHidden)
        XCTAssertFalse(responseCompactSectionSelector.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(responseCompactSectionSelector.selectedItem?.title, "Headers")
        XCTAssertEqual(
            (0..<requestSectionSelector.segmentCount).map {
                requestSectionSelector.label(forSegment: $0)
            },
            [
                "Headers", "Query", "Cookies", "Body", "Preview", "JSON", "JSONPath",
                "Tree", "XML", "Form", "GraphQL", "Protobuf", "Hex", "Raw"
            ]
        )
        XCTAssertEqual(
            (0..<responseSectionSelector.segmentCount).map {
                responseSectionSelector.label(forSegment: $0)
            },
            [
                "Headers", "Cookies", "Body", "Preview", "JSON", "JSONPath", "Tree", "XML",
                "Form", "Protobuf", "Hex", "Raw"
            ]
        )
        XCTAssertEqual(summaryMethod?.stringValue, "POST")
        XCTAssertEqual(summaryStatus?.stringValue, "404 Result")
        XCTAssertEqual(
            summaryURL?.stringValue,
            "https://api.example.com/v1/items/3?source=test"
        )
        for identifier in [
            "traffic.filter.method",
            "traffic.filter.status",
            "traffic.filter.contentType",
            "traffic.filter.source",
            "traffic.filter.annotation"
        ] {
            XCTAssertNotNil(
                Self.descendant(
                    of: NSPopUpButton.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == identifier }
                )
            )
        }
        for identifier in [
            "inspector.annotation.comment",
            "inspector.annotation.highlight",
            "inspector.annotation.strikethrough",
            "inspector.annotation.save"
        ] {
            XCTAssertNotNil(
                Self.descendant(
                    of: NSControl.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == identifier }
                )
            )
        }
        XCTAssertEqual(sourceOutline.numberOfRows, 8)
        let sourceLabels = (0..<sourceOutline.numberOfRows).compactMap { row in
            sourceOutline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .accessibilityLabel()
        }
        XCTAssertEqual(
            sourceLabels,
            [
                "All Traffic, 4 flows",
                "Apps, 2 applications",
                "Safari, 1 flow",
                "Unknown App, 3 flows",
                "Domains, 3 domains",
                "api.example.com, 2 flows",
                "auth.example.net, 1 flow",
                "cdn.example.com, 1 flow"
            ]
        )
        XCTAssertEqual(flowTable.numberOfRows, flows.count)
        XCTAssertTrue(requestInspector.string.contains("POST /v1/items/3?source=test HTTP/1.1"))
        XCTAssertTrue(responseInspector.string.contains("HTTP/1.1 404 Result"))

        requestSectionSelector.selectedSegment = 1
        XCTAssertTrue(
            requestSectionSelector.sendAction(
                requestSectionSelector.action,
                to: requestSectionSelector.target
            )
        )
        XCTAssertEqual(requestInspector.string, "source=test")

        requestSectionSelector.selectedSegment = 2
        XCTAssertTrue(
            requestSectionSelector.sendAction(
                requestSectionSelector.action,
                to: requestSectionSelector.target
            )
        )
        XCTAssertEqual(
            requestInspector.string,
            "session=abc123\ntheme=dark\ntoken=a=b"
        )

        responseSectionSelector.selectedSegment = 1
        XCTAssertTrue(
            responseSectionSelector.sendAction(
                responseSectionSelector.action,
                to: responseSectionSelector.target
            )
        )
        XCTAssertEqual(
            responseInspector.string,
            "session=updated\n  Path=/\n  HttpOnly\n  Secure\n\n"
                + "theme=light\n  Max-Age=3600\n  SameSite=Lax"
        )

        if let rawIndex = (0..<requestSectionSelector.segmentCount).first(where: {
            requestSectionSelector.label(forSegment: $0) == "Raw"
        }) {
            requestSectionSelector.selectedSegment = rawIndex
            XCTAssertTrue(
                requestSectionSelector.sendAction(
                    requestSectionSelector.action,
                    to: requestSectionSelector.target
                )
            )
            XCTAssertTrue(
                requestInspector.string.contains("POST /v1/items/3?source=test HTTP/1.1")
            )
            XCTAssertTrue(requestInspector.string.contains(#"{"query":"proxylens"}"#))
        } else {
            XCTFail("Request inspector is missing its Raw tab")
        }

        if let rawIndex = (0..<responseSectionSelector.segmentCount).first(where: {
            responseSectionSelector.label(forSegment: $0) == "Raw"
        }) {
            responseSectionSelector.selectedSegment = rawIndex
            XCTAssertTrue(
                responseSectionSelector.sendAction(
                    responseSectionSelector.action,
                    to: responseSectionSelector.target
                )
            )
            XCTAssertTrue(responseInspector.string.contains("HTTP/1.1 404 Result"))
            XCTAssertTrue(responseInspector.string.contains(#"{"error":"not found"}"#))
        } else {
            XCTFail("Response inspector is missing its Raw tab")
        }

        searchField.stringValue = "api.example.com"
        XCTAssertTrue(searchField.sendAction(searchField.action, to: searchField.target))
        XCTAssertEqual(viewModel.snapshot.visibleRows.count, 2)
        XCTAssertEqual(flowTable.numberOfRows, 2)

        clearButton.performClick(nil)
        XCTAssertEqual(viewModel.snapshot.displayFilter, .all)
        XCTAssertEqual(flowTable.numberOfRows, flows.count)

        let representation = try XCTUnwrap(
            controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)
        )
        controller.view.cacheDisplay(in: controller.view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "ProxyLens stacked traffic workspace"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.orderOut(nil)
        window.contentViewController = nil
    }

    func testInspectorLongURLDoesNotExpandPastWindowBounds() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        var flow = try Self.makeFlow(index: 9, host: "api.example.com", statusCode: 200)
        let query = String(repeating: "parameter=0123456789&", count: 100)
        flow.replaceRequest(
            HTTPRequest(
                method: flow.request.method,
                url: try XCTUnwrap(URL(string: "https://api.example.com/search?\(query)")),
                headers: flow.request.headers
            )
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(frame.size)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.view.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(window.contentView?.frame.width ?? 0, frame.width, accuracy: 1)

        for identifierPrefix in [
            "inspector.request.section",
            "inspector.response.section"
        ] {
            let sectionSelector = try XCTUnwrap(
                Self.descendant(
                    of: NSSegmentedControl.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == identifierPrefix }
                )
            )
            let sectionPopup = try XCTUnwrap(
                Self.descendant(
                    of: NSPopUpButton.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == "\(identifierPrefix).compact" }
                )
            )
            let visibleSelector: NSView =
                sectionSelector.isHiddenOrHasHiddenAncestor ? sectionPopup : sectionSelector
            XCTAssertFalse(visibleSelector.isHiddenOrHasHiddenAncestor)
            let selectorFrame = visibleSelector.convert(
                visibleSelector.bounds,
                to: controller.view
            )
            XCTAssertGreaterThanOrEqual(selectorFrame.minX, controller.view.bounds.minX)
            XCTAssertLessThanOrEqual(selectorFrame.maxX, controller.view.bounds.maxX)
        }

        let representation = try XCTUnwrap(
            controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)
        )
        controller.view.cacheDisplay(in: controller.view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "ProxyLens long URL inspector"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInspectorShowsAppliedRuleTraces() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        var flow = try Self.makeFlow(index: 7, host: "ads.example.com", statusCode: 403)
        flow.appendRuleTrace(
            RuleTrace(
                ruleID: RuleID(),
                phase: .requestHeaders,
                outcome: .applied,
                ruleName: "Block ads.example.com",
                logs: ["script selected campaign 42"]
            )
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        XCTAssertTrue(viewModel.snapshot.inspection.rules.contains("Block ads.example.com"))
        XCTAssertTrue(viewModel.snapshot.inspection.rules.contains("applied"))
        XCTAssertTrue(viewModel.snapshot.inspection.rules.contains("script selected campaign 42"))

        var filter = TrafficDisplayFilter()
        filter.searchText = "Block ads.example.com"
        XCTAssertTrue(filter.matches(flow))
        filter.searchText = "campaign 42"
        XCTAssertTrue(filter.matches(flow))

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        modeSelector.selectedSegment = 1
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.rules.content"
                }
            )
        )
        XCTAssertTrue(inspector.string.contains("Block ads.example.com"))
        XCTAssertTrue(inspector.string.contains("requestHeaders"))
        XCTAssertTrue(inspector.string.contains("script selected campaign 42"))
    }

    func testTimingInspectionBuildsAClampedWaterfallFromCapturedMilestones() throws {
        var flow = try Self.makeFlow(index: 8, host: "timing.example.com", statusCode: 200)
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .https,
                upstreamHost: "timing.example.com",
                upstreamPort: 443,
                tlsIntercepted: true,
                upstreamHTTPVersion: .http2,
                isUpstreamConnectionReused: true
            )
        )
        let startedAt = flow.timing.startedAt
        flow.markRequestHeadersReceived(at: startedAt.addingTimeInterval(0.010))
        flow.markRequestBodyCompleted(at: startedAt.addingTimeInterval(0.030))
        flow.markUpstreamConnected(at: startedAt.addingTimeInterval(0.050))
        flow.markTLSHandshakeCompleted(at: startedAt.addingTimeInterval(0.080))
        flow.markResponseHeadersReceived(at: startedAt.addingTimeInterval(0.200))
        flow.markResponseBodyCompleted(at: startedAt.addingTimeInterval(0.240))
        flow.markCompleted(at: startedAt.addingTimeInterval(0.250))

        let timing = TrafficTimingInspection(flow: flow)

        XCTAssertEqual(timing.elapsedDuration, 0.250, accuracy: 0.000_1)
        XCTAssertEqual(timing.totalDuration, 0.250, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(timing.timeToFirstByte), 0.200, accuracy: 0.000_1)
        XCTAssertTrue(timing.isComplete)
        XCTAssertEqual(timing.clientProtocol, "HTTP/1.1")
        XCTAssertEqual(timing.upstreamProtocol, "HTTP/2")
        XCTAssertEqual(timing.connectionReuse, "Reused Connection")
        XCTAssertEqual(
            timing.phases.map(\.kind),
            [
                .requestHeaders, .requestBody, .connection, .tls, .waiting, .responseBody,
                .finalization
            ]
        )
        XCTAssertEqual(timing.phases[1].startOffset, 0.010, accuracy: 0.000_1)
        XCTAssertEqual(timing.phases[1].duration, 0.020, accuracy: 0.000_1)
        XCTAssertEqual(timing.phases[4].startOffset, 0.080, accuracy: 0.000_1)
        XCTAssertEqual(timing.phases[4].duration, 0.120, accuracy: 0.000_1)
    }

    func testTimingInspectionKeepsIncompleteFlowsTruthful() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var headers = HTTPHeaders()
        try headers.append(name: "Host", value: "pending.example.com")
        var flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(
                method: .post,
                url: try XCTUnwrap(URL(string: "https://pending.example.com/upload")),
                headers: headers
            ),
            startedAt: startedAt
        )
        flow.markRequestHeadersReceived(at: startedAt.addingTimeInterval(0.010))
        flow.markRequestBodyCompleted(at: startedAt.addingTimeInterval(0.020))

        let timing = TrafficTimingInspection(flow: flow)

        XCTAssertFalse(timing.isComplete)
        XCTAssertNil(timing.timeToFirstByte)
        XCTAssertEqual(timing.totalDuration, 0.020, accuracy: 0.000_1)
        XCTAssertEqual(timing.phases.map(\.kind), [.requestHeaders, .requestBody])
    }

    func testInspectorMessagePanesGiveTheirContentTheFullPaneHeight() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        // The Tree section only renders rows for a JSON body. Without one JSONTreeView shows its
        // message label and hides the scroll view, which would make the height guard below measure
        // an outline view that is not on screen.
        let treeBody = Data(
            #"{"id":12,"items":[{"sku":"a","qty":1},{"sku":"b","qty":2}],"meta":{"page":1}}"#.utf8
        )
        let flow = try Self.makeFlow(
            index: 12,
            host: "panes.example.com",
            statusCode: 200,
            requestBody: treeBody,
            requestContentType: "application/json"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(frame.size)
        controller.view.frame = NSRect(origin: .zero, size: frame.size)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()

        for prefix in ["inspector.request", "inspector.response"] {
            let paneView = try XCTUnwrap(
                Self.descendant(
                    of: NSView.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == prefix }
                )
            )
            let textView = try XCTUnwrap(
                Self.descendant(
                    of: NSTextView.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == "\(prefix).content" }
                )
            )
            let scrollView = try XCTUnwrap(textView.enclosingScrollView)
            // The chrome above the content is one row of controls, so the scrollable content must
            // keep nearly the whole pane. Regression guard: an unconstrained chrome stack used to
            // inflate to ~287pt of a 349pt pane and leave the headers squeezed into a 46pt strip.
            XCTAssertGreaterThan(
                scrollView.frame.height,
                paneView.frame.height - 80,
                "\(prefix) content is squeezed: pane=\(paneView.frame.height)"
                    + " content=\(scrollView.frame.height)"
            )
            // The pane container is not flipped, so the content region starts at y == 0.
            XCTAssertEqual(
                scrollView.frame.minY,
                0,
                accuracy: 1,
                "\(prefix) content should reach the bottom of the pane"
            )
        }

        // The same region is shared with the Tree view, which must fill it too once selected.
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request.section" }
            )
        )
        let treeSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Tree"
            }
        )
        sectionSelector.selectedSegment = treeSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        window.contentView?.layoutSubtreeIfNeeded()

        let requestPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request" }
            )
        )
        let treeView = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request.tree" }
            )
        )
        try await waitUntil { !treeView.isHiddenOrHasHiddenAncestor }
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(treeView.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(
            treeView.frame.height,
            requestPane.frame.height - 80,
            "tree view is squeezed: pane=\(requestPane.frame.height)"
                + " tree=\(treeView.frame.height)"
        )
    }

    func testInspectorGivesVerticalSlackToMessagePanes() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(index: 11, host: "layout.example.com", statusCode: 200)
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        let frame = NSRect(x: 0, y: 0, width: 1_200, height: 720)
        let controller = TrafficConsoleViewController(viewModel: viewModel)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(frame.size)
        controller.view.frame = NSRect(origin: .zero, size: frame.size)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()

        let inspectorPane = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "traffic.pane.inspector" }
            )
        )
        let annotationBar = try XCTUnwrap(
            Self.descendant(of: FlowAnnotationBar.self, in: controller.view)
        )
        let messagesSplit = try XCTUnwrap(
            Self.descendant(
                of: NSSplitView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.split.messages" }
            )
        )

        XCTAssertFalse(annotationBar.isHiddenOrHasHiddenAncestor)
        XCTAssertLessThanOrEqual(
            annotationBar.frame.height,
            annotationBar.fittingSize.height + 1
        )
        XCTAssertGreaterThan(messagesSplit.frame.height, inspectorPane.frame.height * 0.7)
    }

    func testInspectorShowsTimingWaterfallForTheSelectedFlow() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        var flow = try Self.makeFlow(index: 9, host: "timing.example.com", statusCode: 200)
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .https,
                upstreamHost: "timing.example.com",
                upstreamPort: 443,
                tlsIntercepted: true,
                upstreamHTTPVersion: .http2,
                isUpstreamConnectionReused: true
            )
        )
        let startedAt = flow.timing.startedAt
        flow.markRequestHeadersReceived(at: startedAt.addingTimeInterval(0.010))
        flow.markRequestBodyCompleted(at: startedAt.addingTimeInterval(0.030))
        flow.markUpstreamConnected(at: startedAt.addingTimeInterval(0.050))
        flow.markTLSHandshakeCompleted(at: startedAt.addingTimeInterval(0.080))
        flow.markResponseHeadersReceived(at: startedAt.addingTimeInterval(0.200))
        flow.markResponseBodyCompleted(at: startedAt.addingTimeInterval(0.240))
        flow.markCompleted(at: startedAt.addingTimeInterval(0.250))
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        XCTAssertEqual(
            (0..<modeSelector.segmentCount).map { modeSelector.label(forSegment: $0) },
            ["Content", "Rules", "Timing", "Frames", "Events"]
        )
        modeSelector.selectedSegment = 2
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)

        let timingView = try XCTUnwrap(
            Self.descendant(
                of: NSView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.timing" }
            )
        )
        let totalField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: timingView,
                matching: { $0.accessibilityIdentifier() == "inspector.timing.total" }
            )
        )
        let waitingField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: timingView,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.timing.waiting.duration"
                }
            )
        )
        let clientProtocolField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: timingView,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.timing.clientProtocol"
                }
            )
        )
        let upstreamProtocolField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: timingView,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.timing.upstreamProtocol"
                }
            )
        )
        let connectionReuseField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: timingView,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.timing.connectionReuse"
                }
            )
        )
        XCTAssertFalse(timingView.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(totalField.stringValue, "250 ms")
        XCTAssertEqual(waitingField.stringValue, "120 ms")
        XCTAssertEqual(clientProtocolField.stringValue, "HTTP/1.1")
        XCTAssertEqual(upstreamProtocolField.stringValue, "HTTP/2")
        XCTAssertEqual(connectionReuseField.stringValue, "Reused Connection")
    }

    func testInspectorShowsDerivedJSONWithoutReplacingRawBody() async throws {
        let compact = #"{"z":1,"a":2}"#
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 3,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data(compact.utf8),
            responseBody: Data(compact.utf8),
            responseContentType: "application/json"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard case .content(_, let json) = viewModel.snapshot.inspection.response?.json,
                case .content(_, let body) = viewModel.snapshot.inspection.response?.body
            else {
                return false
            }
            return json.contains(#""a""#) && body.contains(compact)
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.section"
                }
            )
        )
        XCTAssertEqual(
            (0..<sectionSelector.segmentCount).map {
                sectionSelector.label(forSegment: $0) ?? ""
            },
            [
                "Headers", "Cookies", "Body", "Preview", "JSON", "JSONPath", "Tree", "XML",
                "Form", "Protobuf", "Hex", "Raw"
            ]
        )

        let bodySegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Body"
            }
        )
        let jsonSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "JSON"
            }
        )
        let treeSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Tree"
            }
        )
        let jsonPathSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "JSONPath"
            }
        )

        sectionSelector.selectedSegment = bodySegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.content"
                }
            )
        )
        XCTAssertTrue(inspector.string.contains(compact))

        sectionSelector.selectedSegment = jsonSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        XCTAssertTrue(inspector.string.contains(#""a""#))
        XCTAssertTrue(inspector.string.contains(#""z""#))
        XCTAssertTrue(inspector.string.contains("\n"))
        XCTAssertFalse(inspector.string.contains(compact))
        let keyRange = try XCTUnwrap(inspector.string.range(of: #""a""#))
        let keyColor =
            inspector.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(keyRange, in: inspector.string).location,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertEqual(keyColor, InspectorSyntaxPalette.key)

        sectionSelector.selectedSegment = jsonPathSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        let jsonPathQuery = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.jsonpath.query"
                }
            )
        )
        let jsonPathRun = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.jsonpath.run"
                }
            )
        )
        let jsonPathResult = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.jsonpath.result"
                }
            )
        )
        jsonPathQuery.stringValue = "$.z"
        jsonPathRun.sendAction(jsonPathRun.action, to: jsonPathRun.target)
        XCTAssertTrue(jsonPathResult.string.contains("$.z"))
        XCTAssertTrue(jsonPathResult.string.contains("1"))

        let jsonQueryMode = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.jsonquery.mode"
                }
            )
        )
        XCTAssertEqual(jsonQueryMode.itemTitles, ["JSONPath", "jq"])
        jsonQueryMode.selectItem(withTitle: "jq")
        jsonQueryMode.sendAction(jsonQueryMode.action, to: jsonQueryMode.target)
        jsonPathQuery.stringValue = ".z"
        jsonPathRun.sendAction(jsonPathRun.action, to: jsonPathRun.target)
        XCTAssertEqual(jsonPathResult.string, "1")
        let numberColor =
            jsonPathResult.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertEqual(numberColor, InspectorSyntaxPalette.number)

        sectionSelector.selectedSegment = treeSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        let tree = try XCTUnwrap(
            Self.descendant(
                of: NSOutlineView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.response.tree"
                }
            )
        )
        XCTAssertFalse(tree.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(inspector.enclosingScrollView?.isHidden ?? false)
        XCTAssertGreaterThanOrEqual(tree.numberOfRows, 3)

        sectionSelector.selectedSegment = bodySegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        XCTAssertTrue(inspector.string.contains(compact))
        XCTAssertFalse(inspector.enclosingScrollView?.isHiddenOrHasHiddenAncestor ?? true)
        XCTAssertTrue(tree.isHiddenOrHasHiddenAncestor)
    }

    func testInspectorShowsDerivedXMLAndFormViewsWithoutReplacingRawBodies() async throws {
        let compactXML = #"<root><item id="1">Ada</item></root>"#
        let compactForm = "name=ProxyLens+App&tag=one&tag=two"
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 5,
            host: "api.example.com",
            statusCode: 200,
            requestBody: Data(compactXML.utf8),
            responseBody: Data(compactForm.utf8),
            responseContentType: "application/x-www-form-urlencoded",
            requestContentType: "application/xml"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard case .content(_, let xml) = viewModel.snapshot.inspection.request?.xml,
                case .content(_, let form) = viewModel.snapshot.inspection.response?.form,
                case .content(_, let requestBody) = viewModel.snapshot.inspection.request?.body,
                case .content(_, let responseBody) = viewModel.snapshot.inspection.response?.body
            else {
                return false
            }
            return xml.contains("<item id=\"1\">")
                && form.contains("name=ProxyLens App")
                && requestBody.contains(compactXML)
                && responseBody.contains(compactForm)
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)

        for (prefix, section, token, expectedColor) in [
            ("request", "XML", "root", InspectorSyntaxPalette.key),
            ("response", "Form", "ProxyLens App", InspectorSyntaxPalette.string)
        ] {
            let sectionSelector = try XCTUnwrap(
                Self.descendant(
                    of: NSSegmentedControl.self,
                    in: controller.view,
                    matching: {
                        $0.accessibilityIdentifier() == "inspector.\(prefix).section"
                    }
                )
            )
            let segment = try XCTUnwrap(
                (0..<sectionSelector.segmentCount).first {
                    sectionSelector.label(forSegment: $0) == section
                }
            )
            sectionSelector.selectedSegment = segment
            sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

            let inspector = try XCTUnwrap(
                Self.descendant(
                    of: NSTextView.self,
                    in: controller.view,
                    matching: {
                        $0.accessibilityIdentifier() == "inspector.\(prefix).content"
                    }
                )
            )
            XCTAssertFalse(inspector.isEditable)
            let tokenRange = try XCTUnwrap(inspector.string.range(of: token))
            let tokenColor =
                inspector.textStorage?.attribute(
                    .foregroundColor,
                    at: NSRange(tokenRange, in: inspector.string).location,
                    effectiveRange: nil
                ) as? NSColor
            XCTAssertEqual(tokenColor, expectedColor)

            if section == "XML" {
                XCTAssertTrue(inspector.string.contains("\n"))
            } else {
                XCTAssertTrue(inspector.string.contains("tag=one\ntag=two"))
            }
        }
    }

    func testServerSentEventInspectorLoadsEventsSearchesAndHighlightsSelectedJSONData()
        async throws
    {
        let flow = try Self.makeFlow(
            index: 8,
            host: "events.example.com",
            statusCode: 200,
            responseContentType: "text/event-stream; charset=utf-8"
        )
        let first = CapturedServerSentEvent(
            flowID: flow.id,
            sequenceNumber: 1,
            eventType: "order.updated",
            eventID: "evt-41",
            retryMilliseconds: 1_500,
            data: BodyReference(
                inline: Data(#"{"orderID":41,"state":"ready"}"#.utf8),
                metadata: BodyMetadata(contentType: "application/json")
            ),
            receivedAt: Date(timeIntervalSince1970: 8.1)
        )
        let second = CapturedServerSentEvent(
            flowID: flow.id,
            sequenceNumber: 2,
            eventType: "heartbeat",
            data: BodyReference(
                inline: Data("alive".utf8),
                metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
            ),
            receivedAt: Date(timeIntervalSince1970: 8.2)
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            serverSentEventLoader: StaticServerSentEventLoader(events: [first, second])
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard let eventStream = viewModel.snapshot.inspection.serverSentEvents,
                eventStream.events.count == 2,
                eventStream.selectedEventID == first.id,
                case .content(_, let payload) = eventStream.payload
            else {
                return false
            }
            return payload.contains(#""orderID" : 41"#)
        }

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        XCTAssertEqual(modeSelector.segmentCount, 5)
        XCTAssertTrue(modeSelector.isEnabled(forSegment: 4))
        modeSelector.selectedSegment = 4
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)

        let eventTable = try XCTUnwrap(
            Self.descendant(
                of: NSTableView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.sse.events" }
            )
        )
        XCTAssertFalse(eventTable.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(eventTable.numberOfRows, 2)
        XCTAssertEqual(eventTable.selectedRow, 0)

        let payloadView = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.sse.payload" }
            )
        )
        XCTAssertTrue(payloadView.string.contains(#""state" : "ready""#))
        let keyRange = try XCTUnwrap(payloadView.string.range(of: #""orderID""#))
        let keyColor =
            payloadView.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(keyRange, in: payloadView.string).location,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertEqual(keyColor, InspectorSyntaxPalette.key)

        let searchField = try XCTUnwrap(
            Self.descendant(
                of: NSSearchField.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.sse.search" }
            )
        )
        searchField.stringValue = "heartbeat"
        searchField.sendAction(searchField.action, to: searchField.target)
        try await waitUntil {
            viewModel.snapshot.inspection.serverSentEvents?.events.map(\.id) == [second.id]
        }
    }

    func testServerSentEventInspectorBuildsAndShowsAccumulatedOpenAIText() async throws {
        let flow = try Self.makeFlow(
            index: 9,
            host: "api.openai.com",
            statusCode: 200,
            responseContentType: "text/event-stream"
        )
        let events = [
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: 1,
                data: BodyReference(
                    inline: Data(
                        #"{"choices":[{"delta":{"content":"Hello "}}]}"#.utf8
                    )
                )
            ),
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: 2,
                eventType: "response.output_text.delta",
                data: BodyReference(
                    inline: Data(
                        #"{"type":"response.output_text.delta","delta":"world"}"#.utf8
                    )
                )
            ),
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: 3,
                data: BodyReference(inline: Data("[DONE]".utf8))
            )
        ]
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            serverSentEventLoader: StaticServerSentEventLoader(events: events)
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard
                case .content(let metadata, let text) =
                    viewModel.snapshot.inspection.serverSentEvents?.accumulated
            else {
                return false
            }
            return text == "Hello world"
                && metadata.contains("2 text deltas")
                && metadata.contains("1 terminal marker")
        }

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        modeSelector.selectedSegment = 4
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)

        let presentationSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.sse.presentation"
                }
            )
        )
        XCTAssertEqual(
            (0..<presentationSelector.segmentCount).map {
                presentationSelector.label(forSegment: $0)
            },
            ["Event Data", "Accumulated"]
        )
        presentationSelector.selectedSegment = 1
        presentationSelector.sendAction(
            presentationSelector.action,
            to: presentationSelector.target
        )

        let payloadView = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.sse.payload" }
            )
        )
        XCTAssertEqual(payloadView.string, "Hello world")
        XCTAssertEqual(payloadView.accessibilityLabel(), "Accumulated streaming response text")
        XCTAssertTrue(payloadView.usesFindBar)

        let copyButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.sse.copy-accumulated"
                }
            )
        )
        XCTAssertTrue(copyButton.isEnabled)
    }

    func testServerSentEventAccumulationReportsBoundedVisibleHistoryAndSafetyLimits()
        async throws
    {
        let flow = try Self.makeFlow(
            index: 10,
            host: "api.openai.com",
            statusCode: 200,
            responseContentType: "text/event-stream"
        )
        let visibleDelta = Data(
            #"{"choices":[{"delta":{"content":"A"}}]}"#.utf8
        )
        let oversizedDelta = Data(
            #"{"choices":[{"delta":{"content":"This delta exceeds the remaining input budget"}}]}"#
                .utf8
        )
        let events = [
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: 1,
                data: BodyReference(inline: Data("omitted event".utf8))
            ),
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: 2,
                data: BodyReference(inline: visibleDelta)
            ),
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: 3,
                data: BodyReference(inline: oversizedDelta)
            ),
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: 4,
                data: BodyReference(inline: oversizedDelta)
            )
        ]
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            serverSentEventLoader: StaticServerSentEventLoader(events: events),
            maximumVisibleServerSentEvents: 3,
            maximumServerSentEventAccumulationBytes: Int64(visibleDelta.count),
            maximumServerSentEventAccumulationBytesPerEvent: 1_024,
            maximumServerSentEventAccumulatedOutputBytes: 1_024
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard
                case .content(let metadata, let text) =
                    viewModel.snapshot.inspection.serverSentEvents?.accumulated
            else {
                return false
            }
            return text == "A"
                && metadata.contains("1 text delta")
                && metadata.contains("2 events skipped by safety limits")
                && metadata.contains("Derived from the latest 3 events; 1 earlier omitted")
                && metadata.contains("Preview truncated")
        }
    }

    func testWebSocketInspectorLoadsFrameMetadataAndSelectedJSONPayload() async throws {
        var flow = try Self.makeFlow(
            index: 9,
            host: "socket.example.com",
            statusCode: 101
        )
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "socket.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        let requestPayload = Data(#"{"action":"subscribe","channel":"orders"}"#.utf8)
        let responsePayload = Data(#"{"event":"ready","ok":true}"#.utf8)
        let requestFrame = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 1,
            direction: .clientToServer,
            opcode: .text,
            isFinal: true,
            wasMasked: true,
            payload: BodyReference(
                inline: requestPayload,
                metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
            ),
            receivedAt: Date(timeIntervalSince1970: 9.1)
        )
        let responseFrame = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 2,
            direction: .serverToClient,
            opcode: .text,
            isFinal: true,
            payload: BodyReference(
                inline: responsePayload,
                metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
            ),
            receivedAt: Date(timeIntervalSince1970: 9.2)
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(
                frames: [requestFrame, responseFrame]
            )
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                webSocket.frames.count == 2,
                webSocket.selectedFrameID == requestFrame.id,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return payload.contains(#""action" : "subscribe""#)
        }

        let webSocket = try XCTUnwrap(viewModel.snapshot.inspection.webSocket)
        XCTAssertEqual(webSocket.frames.map(\.direction), [.clientToServer, .serverToClient])
        XCTAssertEqual(webSocket.frames.map(\.opcodeLabel), ["Text", "Text"])
        XCTAssertEqual(webSocket.payloadSyntax, .json)
        XCTAssertEqual(webSocket.omittedFrameCount, 0)

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        XCTAssertTrue(modeSelector.isEnabled(forSegment: 3))
        modeSelector.selectedSegment = 3
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)

        let frameTable = try XCTUnwrap(
            Self.descendant(
                of: NSTableView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.frames"
                }
            )
        )
        XCTAssertFalse(frameTable.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(frameTable.numberOfRows, 2)
        XCTAssertEqual(frameTable.selectedRow, 0)

        let payloadView = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.payload"
                }
            )
        )
        XCTAssertTrue(payloadView.string.contains(#""channel" : "orders""#))
        let keyRange = try XCTUnwrap(payloadView.string.range(of: #""action""#))
        let keyColor =
            payloadView.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(keyRange, in: payloadView.string).location,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertEqual(keyColor, InspectorSyntaxPalette.key)

        let directionFilter = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.direction"
                }
            )
        )
        XCTAssertEqual(directionFilter.segmentCount, 3)
        XCTAssertEqual(
            (0..<directionFilter.segmentCount).compactMap {
                directionFilter.label(forSegment: $0)
            },
            ["All", "Sent", "Received"]
        )

        let searchField = try XCTUnwrap(
            Self.descendant(
                of: NSSearchField.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.search"
                }
            )
        )
        XCTAssertEqual(searchField.placeholderString, "Search frame payloads")

        directionFilter.selectedSegment = 1
        directionFilter.sendAction(directionFilter.action, to: directionFilter.target)
        XCTAssertEqual(
            viewModel.snapshot.inspection.webSocket?.frames.map(\.id),
            [requestFrame.id]
        )
        searchField.stringValue = "orders"
        searchField.sendAction(searchField.action, to: searchField.target)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket else {
                return false
            }
            return !webSocket.isSearching
                && webSocket.frames.map(\.id) == [requestFrame.id]
        }

        let exportButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.export"
                }
            )
        )
        XCTAssertTrue(exportButton.isEnabled)
    }

    func testServerSentEventInspectorStreamsEventsAndBoundsVisibleHistory() async throws {
        let flow = try Self.makeFlow(
            index: 9,
            host: "live-events.example.com",
            statusCode: 200,
            responseContentType: "text/event-stream"
        )
        let eventBus = ServerSentEventEventBus()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            serverSentEventLoader: StaticServerSentEventLoader(events: []),
            serverSentEventEventSource: eventBus,
            maximumVisibleServerSentEvents: 2
        )
        await viewModel.prepare()
        try await waitUntilAsync {
            await eventBus.subscriptionCount() == 1
        }
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        let events = (1...3).map { sequenceNumber in
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: Int64(sequenceNumber),
                eventType: "message.\(sequenceNumber)",
                data: BodyReference(
                    inline: Data(#"{"sequence":\#(sequenceNumber)}"#.utf8),
                    metadata: BodyMetadata(contentType: "application/json")
                ),
                receivedAt: Date(timeIntervalSince1970: TimeInterval(sequenceNumber))
            )
        }
        for event in events {
            await eventBus.publish(event)
        }

        try await waitUntil {
            guard let eventStream = viewModel.snapshot.inspection.serverSentEvents,
                case .content(_, let payload) = eventStream.payload
            else {
                return false
            }
            return eventStream.events.map(\.sequenceNumber) == [2, 3]
                && eventStream.omittedEventCount == 1
                && eventStream.selectedEventID == events[1].id
                && payload.contains(#""sequence" : 2"#)
        }

        XCTAssertEqual(
            viewModel.snapshot.inspection.serverSentEvents?.statusMessage,
            "Showing the latest 2 events; 1 earlier event is hidden."
        )
    }

    func testWebSocketInspectorStreamsFramesAndBoundsVisibleHistory() async throws {
        var flow = try Self.makeFlow(
            index: 10,
            host: "stream.example.com",
            statusCode: 101
        )
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .webSocket,
                upstreamHost: "stream.example.com",
                upstreamPort: 80
            )
        )
        let frameEvents = WebSocketFrameEventBus()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(frames: []),
            webSocketFrameEventSource: frameEvents,
            maximumVisibleWebSocketFrames: 2
        )
        await viewModel.prepare()
        try await waitUntilAsync {
            await frameEvents.subscriptionCount() == 1
        }
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        let frames = (1...3).map { sequenceNumber in
            CapturedWebSocketFrame(
                flowID: flow.id,
                sequenceNumber: Int64(sequenceNumber),
                direction: sequenceNumber.isMultiple(of: 2)
                    ? .serverToClient
                    : .clientToServer,
                opcode: .text,
                isFinal: true,
                payload: BodyReference(
                    inline: Data(#"{"sequence":\#(sequenceNumber)}"#.utf8),
                    metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
                ),
                receivedAt: Date(timeIntervalSince1970: TimeInterval(sequenceNumber))
            )
        }
        for frame in frames {
            await frameEvents.publish(frame)
        }

        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket else {
                return false
            }
            guard case .content = webSocket.payload else {
                return false
            }
            return webSocket.frames.map(\.sequenceNumber) == [2, 3]
                && webSocket.omittedFrameCount == 1
                && webSocket.selectedFrameID == frames[1].id
        }

        let webSocket = try XCTUnwrap(viewModel.snapshot.inspection.webSocket)
        XCTAssertEqual(
            webSocket.statusMessage,
            "Showing the latest 2 frames; 1 earlier frame is hidden."
        )
        guard case .content(_, let payload) = webSocket.payload else {
            return XCTFail("Expected the newly selected frame payload")
        }
        XCTAssertTrue(payload.contains(#""sequence" : 2"#))
    }

    func testWebSocketInspectorComposesMessagesOnlyWhileTheSelectedConnectionIsOpen()
        async throws
    {
        let request = HTTPRequest(
            method: .get,
            url: try XCTUnwrap(URL(string: "ws://live.example.com/socket"))
        )
        var flow = Flow(
            sessionID: SessionID(),
            source: .desktopProxy,
            request: request,
            connection: ConnectionInfo(
                protocolKind: .webSocket,
                upstreamHost: "live.example.com",
                upstreamPort: 80
            )
        )
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .connectingUpstream)
        try flow.transition(to: .receivingResponse)
        flow.attachResponse(
            try HTTPResponse(statusCode: 101, reasonPhrase: "Switching Protocols")
        )
        let composer = RecordingTrafficWebSocketComposer(openFlowIDs: [flow.id])
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(frames: []),
            webSocketComposer: composer
        )
        await viewModel.prepare()
        viewModel.receive(.updated(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            viewModel.snapshot.inspection.webSocket?.canCompose == true
        }

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        modeSelector.selectedSegment = 3
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)
        let composeButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.compose"
                }
            )
        )
        XCTAssertTrue(composeButton.isEnabled)

        try await viewModel.sendWebSocketMessage(
            direction: .serverToClient,
            payloadEncoding: .base64,
            payload: "AQID"
        )

        let requests = await composer.requests()
        XCTAssertEqual(
            requests,
            [
                WebSocketComposeRequest(
                    flowID: flow.id,
                    direction: .serverToClient,
                    payloadEncoding: .base64,
                    payload: "AQID"
                )
            ]
        )
    }

    func testClosedWebSocketReconnectsWithAReconstructedMessageAndSelectsTheNewFlow()
        async throws
    {
        var original = try Self.makeFlow(
            index: 114,
            host: "socket.example.com",
            statusCode: 101
        )
        original.replaceConnection(
            ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "socket.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        var requestHeaders = original.request.headers
        try requestHeaders.append(name: "Authorization", value: "Bearer local-test")
        original.replaceRequest(original.request.replacingHeaders(requestHeaders))

        let start = CapturedWebSocketFrame(
            flowID: original.id,
            sequenceNumber: 1,
            direction: .serverToClient,
            opcode: .text,
            isFinal: false,
            payload: BodyReference(inline: Data("{\"event\":\"".utf8))
        )
        let end = CapturedWebSocketFrame(
            flowID: original.id,
            sequenceNumber: 2,
            direction: .serverToClient,
            opcode: .continuation,
            isFinal: true,
            payload: BodyReference(inline: Data("ready\"}".utf8))
        )

        let replayRequest = HTTPRequest(
            method: .get,
            url: try XCTUnwrap(URL(string: "wss://socket.example.com/events"))
        )
        var replay = Flow(
            sessionID: original.sessionID,
            source: .replay,
            request: replayRequest,
            connection: ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "socket.example.com",
                upstreamPort: 443
            )
        )
        try replay.transition(to: .receivingRequest)
        try replay.transition(to: .connectingUpstream)
        try replay.transition(to: .receivingResponse)
        replay.attachResponse(
            try HTTPResponse(statusCode: 101, reasonPhrase: "Switching Protocols")
        )

        let composer = RecordingTrafficWebSocketComposer(
            openFlowIDs: [replay.id],
            reconnectResult: replay
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(frames: [start, end]),
            webSocketComposer: composer
        )
        await viewModel.prepare()
        viewModel.receive(.finished(original))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(original.id)

        try await waitUntil {
            viewModel.snapshot.inspection.webSocket?.frames.count == 2
                && viewModel.snapshot.inspection.webSocket?.canReconnect == true
        }

        let inspectorController = InspectorViewController(viewModel: viewModel)
        _ = inspectorController.view
        inspectorController.render(viewModel.snapshot)
        let modeSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: inspectorController.view,
                matching: { $0.accessibilityIdentifier() == "inspector.mode" }
            )
        )
        modeSelector.selectedSegment = 3
        modeSelector.sendAction(modeSelector.action, to: modeSelector.target)
        let reconnectButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: inspectorController.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.compose"
                }
            )
        )
        XCTAssertTrue(reconnectButton.isEnabled)
        XCTAssertEqual(reconnectButton.title, "Reconnect…")
        XCTAssertEqual(reconnectButton.accessibilityLabel(), "Reconnect WebSocket")

        viewModel.selectWebSocketFrame(end.id)
        let draft = try await viewModel.webSocketReconnectDraft()
        XCTAssertEqual(draft.urlText, "wss://socket.example.com/v1/items/114?source=test")
        XCTAssertTrue(draft.headersText.contains("Authorization: Bearer local-test"))
        XCTAssertEqual(draft.payloadEncoding, .text)
        XCTAssertEqual(draft.payload, #"{"event":"ready"}"#)
        XCTAssertTrue(draft.payloadStatusMessage?.contains("complete text") == true)

        let reconnectController = WebSocketReconnectViewController(
            draft: draft,
            connectHandler: { _, _, _, _, _ in }
        )
        _ = reconnectController.view
        let urlField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: reconnectController.view,
                matching: { $0.accessibilityIdentifier() == "webSocketReconnect.url" }
            )
        )
        let headersEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: reconnectController.view,
                matching: { $0.accessibilityIdentifier() == "webSocketReconnect.headers" }
            )
        )
        let payloadEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: reconnectController.view,
                matching: { $0.accessibilityIdentifier() == "webSocketReconnect.payload" }
            )
        )
        let formatJSONButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: reconnectController.view,
                matching: {
                    $0.accessibilityIdentifier() == "webSocketReconnect.formatJSON"
                }
            )
        )
        XCTAssertEqual(urlField.stringValue, draft.urlText)
        XCTAssertEqual(headersEditor.string, draft.headersText)
        XCTAssertEqual(payloadEditor.string, draft.payload)
        XCTAssertNotNil(
            headersEditor.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            )
        )
        XCTAssertNotNil(
            payloadEditor.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            )
        )
        formatJSONButton.performClick(nil)
        XCTAssertTrue(payloadEditor.string.contains("\n"))

        let replayedID = try await viewModel.reconnectWebSocket(
            urlText: "wss://socket.example.com/events",
            headersText: "Authorization: Bearer replacement\nSec-WebSocket-Protocol: chat",
            payloadEncoding: draft.payloadEncoding,
            payload: draft.payload,
            replayPayload: true
        )
        XCTAssertEqual(replayedID, replay.id)
        XCTAssertEqual(viewModel.snapshot.selectedFlowID, replay.id)

        let reconnectRequests = await composer.reconnectRequests()
        XCTAssertEqual(reconnectRequests.count, 1)
        XCTAssertEqual(reconnectRequests[0].1, original.sessionID)
        XCTAssertEqual(reconnectRequests[0].0.url.absoluteString, replayRequest.url.absoluteString)
        XCTAssertEqual(
            reconnectRequests[0].0.headers.firstValue(for: "Authorization"),
            "Bearer replacement"
        )
        XCTAssertEqual(
            reconnectRequests[0].0.replayPayload,
            WebSocketReplayPayload(encoding: .text, payload: draft.payload)
        )

        try await waitUntil {
            viewModel.snapshot.inspection.webSocket?.canCompose == true
                && viewModel.snapshot.inspection.webSocket?.canDisconnect == true
        }
        try await viewModel.disconnectSelectedWebSocket()
        let disconnectedFlowIDs = await composer.disconnectFlowIDs()
        XCTAssertEqual(disconnectedFlowIDs, [replay.id])
    }

    func testWebSocketComposerFormatsJSONAndExplainsBinaryPayloads() throws {
        let controller = WebSocketComposerViewController(
            flowTitle: "GET wss://socket.example.com/events"
        ) { _, _, _ in }
        _ = controller.view

        let directionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "webSocketComposer.direction"
                }
            )
        )
        XCTAssertEqual(
            (0..<directionSelector.segmentCount).compactMap {
                directionSelector.label(forSegment: $0)
            },
            ["To Server", "To Client"]
        )

        let payloadView = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "webSocketComposer.payload"
                }
            )
        )
        payloadView.string = #"{"event":"ping","sequence":1}"#
        let formatButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "webSocketComposer.formatJSON"
                }
            )
        )
        formatButton.sendAction(formatButton.action, to: formatButton.target)
        XCTAssertTrue(payloadView.string.contains("\n"))
        let keyRange = try XCTUnwrap(payloadView.string.range(of: #""event""#))
        XCTAssertEqual(
            payloadView.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(keyRange, in: payloadView.string).location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.key
        )

        let encodingSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "webSocketComposer.encoding"
                }
            )
        )
        encodingSelector.selectedSegment = 1
        encodingSelector.sendAction(encodingSelector.action, to: encodingSelector.target)
        XCTAssertFalse(formatButton.isEnabled)
        let payloadHelp = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "webSocketComposer.payloadHelp"
                }
            )
        )
        XCTAssertTrue(payloadHelp.stringValue.contains("Base64"))
        XCTAssertTrue(payloadHelp.stringValue.contains("1 MB"))
    }

    func testWebSocketInspectorFiltersSentAndReceivedFramesWithoutLosingPayloadSelection()
        async throws
    {
        var flow = try Self.makeFlow(index: 11, host: "filters.example.com", statusCode: 101)
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .webSocket,
                upstreamHost: "filters.example.com",
                upstreamPort: 80
            )
        )
        let sent = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 1,
            direction: .clientToServer,
            opcode: .text,
            isFinal: true,
            payload: BodyReference(inline: Data(#"{"kind":"sent"}"#.utf8))
        )
        let received = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 2,
            direction: .serverToClient,
            opcode: .text,
            isFinal: true,
            payload: BodyReference(inline: Data(#"{"kind":"received"}"#.utf8))
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(frames: [sent, received])
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil { viewModel.snapshot.inspection.webSocket?.frames.count == 2 }

        viewModel.setWebSocketDirectionFilter(.sent)
        var webSocket = try XCTUnwrap(viewModel.snapshot.inspection.webSocket)
        XCTAssertEqual(webSocket.frames.map(\.id), [sent.id])
        XCTAssertEqual(webSocket.selectedFrameID, sent.id)
        XCTAssertEqual(webSocket.directionFilter, .sent)

        viewModel.setWebSocketDirectionFilter(.received)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                webSocket.frames.map(\.id) == [received.id],
                webSocket.selectedFrameID == received.id,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return payload.contains(#""received""#)
        }
    }

    func testWebSocketInspectorExplicitlyDecodesEligibleBinaryFramesAsProtobuf()
        async throws
    {
        var flow = try Self.makeFlow(
            index: 111,
            host: "protobuf.socket.example.com",
            statusCode: 101
        )
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "protobuf.socket.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        let sent = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 1,
            direction: .clientToServer,
            opcode: .binary,
            isFinal: true,
            payload: BodyReference(inline: Data([0x08, 0x96, 0x01]))
        )
        let received = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 2,
            direction: .serverToClient,
            opcode: .binary,
            isFinal: true,
            payload: BodyReference(inline: Data([0x08, 0x07]))
        )
        let fragmented = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 3,
            direction: .clientToServer,
            opcode: .binary,
            isFinal: false,
            payload: BodyReference(inline: Data([0x08, 0x01]))
        )
        let extensionEncoded = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 4,
            direction: .serverToClient,
            opcode: .binary,
            isFinal: true,
            reservedBits: .rsv1,
            payload: BodyReference(inline: Data([0x08, 0x02]))
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(
                frames: [sent, received, fragmented, extensionEncoded]
            )
        )
        await viewModel.prepare()
        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "example.desc"
        )
        try await viewModel.selectProtobufMessageType("example.User", direction: .request)
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket else {
                return false
            }
            return webSocket.frames.count == 4
                && webSocket.selectedFrameID == sent.id
                && webSocket.payloadMode == .automatic
                && webSocket.canDecodePayloadAsProtobuf
        }

        viewModel.setWebSocketPayloadMode(.protobuf)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .protobuf
                && webSocket.payloadSyntax == .protobuf
                && payload.contains("1  id")
                && payload.contains("int32")
                && payload.contains("150")
        }

        try await viewModel.selectProtobufMessageType(nil, direction: .request)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.selectedFrameID == sent.id
                && webSocket.payloadMode == .protobuf
                && payload.contains("1  varint   150")
        }
        try await viewModel.selectProtobufMessageType("example.User", direction: .request)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.selectedFrameID == sent.id
                && webSocket.payloadMode == .protobuf
                && payload.contains("1  id")
        }

        viewModel.selectWebSocketFrame(received.id)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .protobuf
                && payload.contains("1  varint   7")
                && !payload.contains("1  id")
        }

        viewModel.setWebSocketPayloadMode(.hex)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .hex && payload.contains("08 07")
        }

        viewModel.setWebSocketPayloadMode(.protobuf)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .protobuf
                && webSocket.payloadSyntax == .protobuf
                && payload.contains("1  varint   7")
        }
        viewModel.selectWebSocketFrame(fragmented.id)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket else {
                return false
            }
            return webSocket.selectedFrameID == fragmented.id
                && webSocket.payloadMode == .automatic
                && !webSocket.canDecodePayloadAsProtobuf
        }

        viewModel.selectWebSocketFrame(extensionEncoded.id)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket else {
                return false
            }
            return webSocket.selectedFrameID == extensionEncoded.id
                && !webSocket.canDecodePayloadAsProtobuf
        }

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)
        let representationSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier()
                        == "inspector.websocket.payload.representation"
                }
            )
        )
        XCTAssertEqual(
            (0..<representationSelector.segmentCount).compactMap {
                representationSelector.label(forSegment: $0)
            },
            ["Auto", "Protobuf", "Hex"]
        )
        XCTAssertFalse(representationSelector.isEnabled(forSegment: 1))
        XCTAssertEqual(representationSelector.accessibilityLabel(), "Payload representation")
        XCTAssertEqual(
            representationSelector.accessibilityHelp(),
            "Auto and Protobuf inspect the complete reconstructed message. Hex shows the exact bytes of the selected frame."
        )

        viewModel.selectWebSocketFrame(sent.id)
        try await waitUntil {
            viewModel.snapshot.inspection.webSocket?.selectedFrameID == sent.id
        }
        controller.render(viewModel.snapshot)
        XCTAssertTrue(representationSelector.isEnabled(forSegment: 1))
        representationSelector.selectedSegment = 1
        representationSelector.sendAction(
            representationSelector.action,
            to: representationSelector.target
        )
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .protobuf
                && webSocket.payloadSyntax == .protobuf
                && payload.contains("1  id")
        }
        controller.render(viewModel.snapshot)
        let payloadTextView = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.websocket.payload"
                }
            )
        )
        let payloadText = payloadTextView.string
        let fieldRange = try XCTUnwrap(payloadText.range(of: "1"))
        XCTAssertEqual(
            payloadTextView.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(fieldRange, in: payloadText).location,
                effectiveRange: nil
            ) as? NSColor,
            InspectorSyntaxPalette.key
        )

        representationSelector.selectedSegment = 2
        representationSelector.sendAction(
            representationSelector.action,
            to: representationSelector.target
        )
        try await waitUntil {
            viewModel.snapshot.inspection.webSocket?.payloadMode == .hex
        }
    }

    func testWebSocketInspectorReconstructsFragmentedAndCompressedMessages() async throws {
        var flow = try Self.makeFlow(
            index: 112,
            host: "compressed.socket.example.com",
            statusCode: 101
        )
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "compressed.socket.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        var responseHeaders = try XCTUnwrap(flow.response).headers
        try responseHeaders.append(
            name: "Sec-WebSocket-Extensions",
            value: "permessage-deflate; client_no_context_takeover"
        )
        flow.replaceResponse(try XCTUnwrap(flow.response).replacingHeaders(responseHeaders))

        let compressedStart = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 1,
            direction: .clientToServer,
            opcode: .text,
            isFinal: false,
            reservedBits: .rsv1,
            payload: BodyReference(inline: Data([0xF2, 0x48, 0xCD]))
        )
        let ping = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 2,
            direction: .clientToServer,
            opcode: .ping,
            isFinal: true,
            payload: BodyReference(inline: Data("?".utf8))
        )
        let compressedEnd = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 3,
            direction: .clientToServer,
            opcode: .continuation,
            isFinal: true,
            payload: BodyReference(inline: Data([0xC9, 0xC9, 0x07, 0x00]))
        )
        let protobufStart = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 4,
            direction: .serverToClient,
            opcode: .binary,
            isFinal: false,
            payload: BodyReference(inline: Data([0x08]))
        )
        let protobufEnd = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 5,
            direction: .serverToClient,
            opcode: .continuation,
            isFinal: true,
            payload: BodyReference(inline: Data([0x2A]))
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(
                frames: [
                    compressedStart,
                    ping,
                    compressedEnd,
                    protobufStart,
                    protobufEnd
                ]
            )
        )
        await viewModel.prepare()
        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "example.desc"
        )
        try await viewModel.selectProtobufMessageType("example.User", direction: .response)
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                webSocket.selectedFrameID == compressedStart.id,
                case .content(let metadata, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .automatic
                && webSocket.payloadSyntax == .plainText
                && payload == "Hello"
                && metadata.contains("2 frames")
                && metadata.contains("permessage-deflate")
        }

        viewModel.selectWebSocketFrame(compressedEnd.id)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(_, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .automatic && payload == "Hello"
        }

        viewModel.setWebSocketPayloadMode(.hex)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(let metadata, let payload) = webSocket.payload
            else {
                return false
            }
            return payload.contains("c9 c9 07 00")
                && !payload.contains("Hello")
                && !metadata.contains("2 frames")
        }

        viewModel.selectWebSocketFrame(protobufEnd.id)
        try await waitUntil {
            viewModel.snapshot.inspection.webSocket?.canDecodePayloadAsProtobuf == true
        }
        viewModel.setWebSocketPayloadMode(.protobuf)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(let metadata, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadSyntax == .protobuf
                && metadata.contains("2 frames")
                && payload.contains("1  id")
                && payload.contains("42")
        }
    }

    func testWebSocketInspectorFallsBackToSelectedFrameHexWhenReconstructionExceedsLimit()
        async throws
    {
        var flow = try Self.makeFlow(
            index: 113,
            host: "bounded.socket.example.com",
            statusCode: 101
        )
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "bounded.socket.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        let start = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 1,
            direction: .serverToClient,
            opcode: .binary,
            isFinal: false,
            payload: BodyReference(inline: Data([0x08]))
        )
        let end = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 2,
            direction: .serverToClient,
            opcode: .continuation,
            isFinal: true,
            payload: BodyReference(inline: Data([0x2A]))
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(frames: [start, end]),
            maximumWebSocketReconstructionBytes: 1
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                webSocket.selectedFrameID == start.id,
                case .none(let message) = webSocket.payload
            else {
                return false
            }
            return message.localizedCaseInsensitiveContains("input limit")
        }

        viewModel.setWebSocketPayloadMode(.hex)
        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket,
                case .content(let metadata, let payload) = webSocket.payload
            else {
                return false
            }
            return webSocket.payloadMode == .hex
                && metadata.contains("1 B")
                && payload.contains("08")
        }
    }

    func testWebSocketInspectorSearchesPayloadsWithinExplicitByteLimits() async throws {
        var flow = try Self.makeFlow(index: 12, host: "search.example.com", statusCode: 101)
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .secureWebSocket,
                upstreamHost: "search.example.com",
                upstreamPort: 443,
                tlsIntercepted: true
            )
        )
        let matchingPayload = Data(#"{"event":"order.ready"}"#.utf8)
        let matching = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 1,
            direction: .serverToClient,
            opcode: .text,
            isFinal: true,
            payload: BodyReference(inline: matchingPayload)
        )
        let oversizedBodyID = BodyID()
        let oversizedReference = try BodyReference(
            externalID: oversizedBodyID,
            byteCount: 512,
            metadata: BodyMetadata(contentType: "text/plain")
        )
        let oversized = CapturedWebSocketFrame(
            flowID: flow.id,
            sequenceNumber: 2,
            direction: .clientToServer,
            opcode: .text,
            isFinal: true,
            payload: oversizedReference
        )
        let bodyReader = TrackingTrafficBodyReader(
            externalPayloads: [oversizedBodyID: Data("order.ready".utf8)]
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: bodyReader,
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(frames: [matching, oversized]),
            maximumWebSocketSearchBytes: 64,
            maximumWebSocketSearchBytesPerFrame: 32
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil { viewModel.snapshot.inspection.webSocket?.frames.count == 2 }

        viewModel.setWebSocketSearchText("ORDER.READY")

        try await waitUntil {
            guard let webSocket = viewModel.snapshot.inspection.webSocket else {
                return false
            }
            return !webSocket.isSearching
                && webSocket.frames.map(\.id) == [matching.id]
                && webSocket.statusMessage
                    == "1 of 2 captured frames match. 1 large payload skipped."
        }
        let readIDs = await bodyReader.readIDs()
        XCTAssertFalse(readIDs.contains(oversizedBodyID))
    }

    func testWebSocketExportLoadsTheCompleteFlowHistoryBeyondTheInspectorLimit() async throws {
        var flow = try Self.makeFlow(index: 13, host: "export.example.com", statusCode: 101)
        flow.replaceConnection(
            ConnectionInfo(
                protocolKind: .webSocket,
                upstreamHost: "export.example.com",
                upstreamPort: 80
            )
        )
        let frames = (1...2).map { sequenceNumber in
            CapturedWebSocketFrame(
                flowID: flow.id,
                sequenceNumber: Int64(sequenceNumber),
                direction: .clientToServer,
                opcode: .text,
                isFinal: true,
                payload: BodyReference(
                    inline: Data(#"{"sequence":\#(sequenceNumber)}"#.utf8)
                )
            )
        }
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            webSocketFrameLoader: StaticWebSocketFrameLoader(frames: frames),
            maximumVisibleWebSocketFrames: 1,
            exportService: ExportService(bodyStore: InlineBodyStore())
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "proxylens-complete-websocket-export-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        try await viewModel.writeWebSocketFrames(flowID: flow.id, to: destination)

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: destination))
                as? [String: Any]
        )
        let exportedFrames = try XCTUnwrap(document["frames"] as? [[String: Any]])
        XCTAssertEqual(exportedFrames.count, 2)
    }

    func testServerSentEventExportLoadsCompleteFlowHistoryBeyondInspectorLimit() async throws {
        let flow = try Self.makeFlow(
            index: 14,
            host: "events-export.example.com",
            statusCode: 200,
            responseContentType: "text/event-stream"
        )
        let events = (1...2).map { sequenceNumber in
            CapturedServerSentEvent(
                flowID: flow.id,
                sequenceNumber: Int64(sequenceNumber),
                data: BodyReference(
                    inline: Data("event \(sequenceNumber)".utf8),
                    metadata: BodyMetadata(contentType: "text/plain; charset=utf-8")
                )
            )
        }
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            serverSentEventLoader: StaticServerSentEventLoader(events: events),
            maximumVisibleServerSentEvents: 1,
            exportService: ExportService(bodyStore: InlineBodyStore())
        )
        await viewModel.prepare()
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "proxylens-complete-sse-export-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: destination) }

        try await viewModel.writeServerSentEvents(flowID: flow.id, to: destination)

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: destination))
                as? [String: Any]
        )
        let exportedEvents = try XCTUnwrap(document["events"] as? [[String: Any]])
        XCTAssertEqual(exportedEvents.count, 2)
    }

    func testInspectorShowsMultipartFieldsInTheExistingFormView() async throws {
        let boundary = "ProxyLensBoundary"
        let multipartText = [
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"title\"\r\n\r\n",
            "ProxyLens\r\n",
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"attachment\"; ",
            "filename=\"trace.txt\"\r\n",
            "Content-Type: text/plain\r\n\r\n",
            "captured bytes\r\n",
            "--\(boundary)--\r\n"
        ].joined()
        let multipart = Data(multipartText.utf8)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 7,
            host: "upload.example.com",
            statusCode: 201,
            requestBody: multipart,
            requestContentType: "multipart/form-data; boundary=\(boundary)"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard case .content(_, let form) = viewModel.snapshot.inspection.request?.form,
                case .content(_, let body) = viewModel.snapshot.inspection.request?.body
            else {
                return false
            }
            return form.contains("title=ProxyLens")
                && form.contains("attachment=[File \"trace.txt\", text/plain, 14 B]")
                && body.contains("--\(boundary)")
                && body.contains("captured bytes")
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let formSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Form"
            }
        )
        sectionSelector.selectedSegment = formSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.content"
                }
            )
        )
        XCTAssertFalse(inspector.isEditable)
        XCTAssertTrue(inspector.string.contains("title=ProxyLens"))
        XCTAssertTrue(inspector.string.contains("attachment=[File"))
        XCTAssertFalse(inspector.string.contains("captured bytes"))
    }

    func testInspectorShowsFormattedGraphQLWithoutReplacingRawJSON() async throws {
        let compact =
            #"{"operationName":"GetUser","query":"query GetUser($id: ID!) { user(id: $id) { id name } }","variables":{"id":"42"}}"#
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 8,
            host: "graphql.example.com",
            statusCode: 200,
            requestBody: Data(compact.utf8),
            requestContentType: "application/json"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard
                case .content(_, let graphql) =
                    viewModel.snapshot.inspection.request?.graphql,
                case .content(_, let body) = viewModel.snapshot.inspection.request?.body
            else {
                return false
            }
            return graphql.contains("Operation: GetUser")
                && graphql.contains("    id\n    name")
                && body.contains(compact)
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let graphqlSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "GraphQL"
            }
        )
        sectionSelector.selectedSegment = graphqlSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.content"
                }
            )
        )
        XCTAssertFalse(inspector.isEditable)
        XCTAssertTrue(inspector.string.contains("Operation: GetUser"))
        XCTAssertTrue(inspector.string.contains("Variables:\n"))
        XCTAssertFalse(inspector.string.contains(compact))
        let keywordRange = try XCTUnwrap(inspector.string.range(of: "query GetUser"))
        let keywordColor =
            inspector.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(keywordRange, in: inspector.string).location,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertEqual(keywordColor, InspectorSyntaxPalette.literal)
    }

    func testInspectorShowsBoundedHexWithoutReplacingEditableBody() async throws {
        let body = Data([0x20, 0x41, 0x7E, 0x7F])
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 9,
            host: "binary.example.com",
            statusCode: 200,
            requestBody: body,
            requestContentType: "application/octet-stream"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.body else {
                return false
            }
            return true
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let hexSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Hex"
            }
        )
        sectionSelector.selectedSegment = hexSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.content"
                }
            )
        )
        XCTAssertFalse(inspector.isEditable)
        XCTAssertTrue(inspector.string.contains("00000000  20 41 7e 7f"))
        XCTAssertTrue(inspector.string.contains("| A~.            |"))
    }

    func testInspectorShowsSchemaLessProtobufWithoutReplacingCapturedBytes() async throws {
        let payload = Data([
            0x08, 0x96, 0x01,
            0x12, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
            0x1A, 0x02, 0x08, 0x07
        ])
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 10,
            host: "protobuf.example.com",
            statusCode: 200,
            requestBody: payload,
            requestContentType: "application/x-protobuf; messageType=Example"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard
                case .content(_, let protobuf) =
                    viewModel.snapshot.inspection.request?.protobuf,
                case .content(_, let body) = viewModel.snapshot.inspection.request?.body
            else {
                return false
            }
            return protobuf.contains("1  varint   150")
                && protobuf.contains("2  string   \"hello\"")
                && protobuf.contains("3  message  2 B")
                && body.contains("00000000  08 96 01")
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let protobufSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Protobuf"
            }
        )
        sectionSelector.selectedSegment = protobufSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.content"
                }
            )
        )
        XCTAssertFalse(inspector.isEditable)
        XCTAssertTrue(inspector.string.contains("1  varint   150"))
        XCTAssertTrue(inspector.string.contains("  1  varint   7"))
        XCTAssertFalse(inspector.string.contains("00000000  08 96 01"))
        let typeRange = try XCTUnwrap(inspector.string.range(of: "varint"))
        let typeColor =
            inspector.textStorage?.attribute(
                .foregroundColor,
                at: NSRange(typeRange, in: inspector.string).location,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertEqual(typeColor, InspectorSyntaxPalette.literal)
    }

    func testInspectorUsesGRPCEncodingHeaderForCompressedProtobufFrames() async throws {
        let message = Data([0x08, 0x2A])
        let compressed = try HTTPContentCoding.encode(message, contentEncoding: "gzip")
        var body = Data([0x01])
        let length = UInt32(compressed.count).bigEndian
        withUnsafeBytes(of: length) { body.append(contentsOf: $0) }
        body.append(compressed)

        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 11,
            host: "grpc.example.com",
            statusCode: 200,
            requestBody: body,
            requestContentType: "application/grpc+proto",
            requestGRPCEncoding: "gzip"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard
                case .content(_, let protobuf) =
                    viewModel.snapshot.inspection.request?.protobuf
            else {
                return false
            }
            return protobuf.contains("Message 1 · 2 B · gzip")
                && protobuf.contains("1  varint   42")
        }
    }

    func testInspectorPresentsDelimitedAndTextGRPCWebBodiesInProtobufTabs() async throws {
        let firstMessage = Data([0x08, 0x01])
        let secondMessage = Data([0x08, 0x02])
        var delimitedRequest = Data([UInt8(firstMessage.count)])
        delimitedRequest.append(firstMessage)
        delimitedRequest.append(UInt8(secondMessage.count))
        delimitedRequest.append(secondMessage)

        var grpcWebResponse = Data([0x00, 0x00, 0x00, 0x00, UInt8(firstMessage.count)])
        grpcWebResponse.append(firstMessage)
        let trailers = Data("grpc-status: 0\r\ngrpc-message: OK".utf8)
        grpcWebResponse.append(0x80)
        let trailerLength = UInt32(trailers.count).bigEndian
        withUnsafeBytes(of: trailerLength) { grpcWebResponse.append(contentsOf: $0) }
        grpcWebResponse.append(trailers)
        let textGRPCWebResponse = Data(grpcWebResponse.base64EncodedString().utf8)

        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 13,
            host: "grpc-web.example.com",
            statusCode: 200,
            requestBody: delimitedRequest,
            responseBody: textGRPCWebResponse,
            responseContentType: "application/grpc-web-text+proto",
            requestContentType: "application/x-protobuf; delimited=true"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard
                case .content(_, let requestProtobuf) =
                    viewModel.snapshot.inspection.request?.protobuf,
                case .content(_, let responseProtobuf) =
                    viewModel.snapshot.inspection.response?.protobuf
            else {
                return false
            }
            return requestProtobuf.contains("Message 2 · 2 B · delimited")
                && requestProtobuf.contains("1  varint   2")
                && responseProtobuf.contains("Message 1 · 2 B · uncompressed")
                && responseProtobuf.contains("Trailers · 32 B")
                && responseProtobuf.contains("grpc-status: 0")
        }

        XCTAssertEqual(flow.request.body?.inlineData, delimitedRequest)
        XCTAssertEqual(flow.response?.body?.inlineData, textGRPCWebResponse)
    }

    func testInspectorImportsPersistsAndAppliesAProtobufDescriptorSet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptorStore = FileTrafficProtobufDescriptorStore(directoryURL: directory)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: descriptorStore
        )
        await viewModel.prepare()

        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "example.desc"
        )
        try await viewModel.selectProtobufMessageType("example.User", direction: .request)

        let flow = try Self.makeFlow(
            index: 12,
            host: "protobuf.example.com",
            statusCode: 200,
            requestBody: Data([0x08, 0x96, 0x01]),
            requestContentType: "application/protobuf"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard
                let request = viewModel.snapshot.inspection.request,
                case .content(_, let protobuf) = request.protobuf
            else {
                return false
            }
            return request.protobufSchema.descriptorName == "example.desc"
                && request.protobufSchema.selectedMessageType == "example.User"
                && protobuf.contains("1  id")
                && protobuf.contains("int32")
                && protobuf.contains("150")
        }

        let restored = try await FileTrafficProtobufDescriptorStore(
            directoryURL: directory
        ).load()
        XCTAssertEqual(restored?.sourceName, "example.desc")
        XCTAssertEqual(restored?.requestMessageType, "example.User")
        XCTAssertEqual(restored?.data, Self.singleMessageDescriptorSet)

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let protobufSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Protobuf"
            }
        )
        sectionSelector.selectedSegment = protobufSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

        let importButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.protobuf.import"
                }
            )
        )
        let messageTypePopup = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.protobuf.messageType"
                }
            )
        )
        XCTAssertFalse(importButton.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(messageTypePopup.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(messageTypePopup.itemTitles, ["Schema-less", "example.User"])
        XCTAssertEqual(messageTypePopup.titleOfSelectedItem, "example.User")
    }

    func testFailedProtobufDescriptorImportPreservesLastValidSchema() async throws {
        let store = InMemoryTrafficProtobufDescriptorStore()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: store
        )
        await viewModel.prepare()
        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "valid.desc"
        )

        do {
            try await viewModel.importProtobufDescriptorSet(
                data: Data([0x0A, 0x7F]),
                sourceName: "broken.desc"
            )
            XCTFail("Expected the malformed descriptor import to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("extends past"))
        }

        let stored = try await store.load()
        XCTAssertEqual(stored?.sourceName, "valid.desc")
        XCTAssertEqual(stored?.data, Self.singleMessageDescriptorSet)
    }

    func testProtobufDescriptorFileImportRejectsOversizedInputBeforeParsing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptorURL = directory.appendingPathComponent("oversized.desc")
        try Data(
            repeating: 0,
            count: ProtobufDescriptorSetParser.maximumByteCount + 1
        ).write(to: descriptorURL)
        let store = InMemoryTrafficProtobufDescriptorStore()
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: store
        )
        await viewModel.prepare()
        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "valid.desc"
        )

        do {
            try await viewModel.importProtobufDescriptorSet(from: descriptorURL)
            XCTFail("Expected the oversized descriptor import to fail")
        } catch {
            XCTAssertEqual(
                error as? ProtobufDescriptorSetError,
                .exceedsByteLimit(maximum: ProtobufDescriptorSetParser.maximumByteCount)
            )
        }

        let stored = try await store.load()
        XCTAssertEqual(stored?.sourceName, "valid.desc")
        XCTAssertEqual(stored?.data, Self.singleMessageDescriptorSet)
    }
    func testProtobufDescriptorAndSelectionsHydrateFromAPrePopulatedStore() async throws {
        let store = InMemoryTrafficProtobufDescriptorStore(
            stored: TrafficStoredProtobufDescriptor(
                data: Self.singleMessageDescriptorSet,
                sourceName: "restored.desc",
                requestMessageType: "example.User",
                responseMessageType: "example.Missing"
            )
        )
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: store
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 141,
            host: "restored.protobuf.example.com",
            statusCode: 200,
            requestBody: Data([0x08, 0x96, 0x01]),
            responseBody: Data([0x08, 0x07]),
            responseContentType: "application/protobuf",
            requestContentType: "application/protobuf"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard
                let request = viewModel.snapshot.inspection.request,
                let response = viewModel.snapshot.inspection.response,
                case .content(_, let requestProtobuf) = request.protobuf,
                case .content(_, let responseProtobuf) = response.protobuf
            else {
                return false
            }
            return request.protobufSchema.descriptorName == "restored.desc"
                && request.protobufSchema.selectedMessageType == "example.User"
                && requestProtobuf.contains("1  id")
                && requestProtobuf.contains("150")
                && response.protobufSchema.selectedMessageType == nil
                && responseProtobuf.contains("1  varint   7")
        }

        let request = try XCTUnwrap(viewModel.snapshot.inspection.request)
        let response = try XCTUnwrap(viewModel.snapshot.inspection.response)
        XCTAssertEqual(request.protobufSchema.messageTypeNames, ["example.User"])
        XCTAssertEqual(response.protobufSchema.descriptorName, "restored.desc")
        XCTAssertEqual(response.protobufSchema.messageTypeNames, ["example.User"])
        XCTAssertNil(viewModel.snapshot.workspaceWarning)
    }

    func testNonProtobufInspectorSectionsHideTheDescriptorControls() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: InMemoryTrafficProtobufDescriptorStore()
        )
        await viewModel.prepare()
        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "example.desc"
        )
        try await viewModel.selectProtobufMessageType("example.User", direction: .request)

        let flow = try Self.makeFlow(
            index: 142,
            host: "sections.protobuf.example.com",
            statusCode: 200,
            requestBody: Data([0x08, 0x96, 0x01]),
            requestContentType: "application/protobuf"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            viewModel.snapshot.inspection.request?.protobufSchema.selectedMessageType
                == "example.User"
        }

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)

        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request.section" }
            )
        )
        let importButton = try XCTUnwrap(
            Self.descendant(
                of: NSButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.protobuf.import"
                }
            )
        )
        let descriptorField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.protobuf.descriptor"
                }
            )
        )
        let messageTypePopup = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.protobuf.messageType"
                }
            )
        )

        func selectSection(_ label: String) throws {
            let index = try XCTUnwrap(
                (0..<sectionSelector.segmentCount).first {
                    sectionSelector.label(forSegment: $0) == label
                },
                "Missing \(label) segment"
            )
            sectionSelector.selectedSegment = index
            sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        }

        for section in ["Headers", "Body", "JSON", "Hex", "Raw"] {
            try selectSection(section)
            XCTAssertTrue(
                importButton.isHiddenOrHasHiddenAncestor,
                "Import button visible in \(section)"
            )
            XCTAssertTrue(
                descriptorField.isHiddenOrHasHiddenAncestor,
                "Descriptor field visible in \(section)"
            )
            XCTAssertTrue(
                messageTypePopup.isHiddenOrHasHiddenAncestor,
                "Message type popup visible in \(section)"
            )
        }

        try selectSection("Protobuf")
        XCTAssertFalse(importButton.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(descriptorField.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(messageTypePopup.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(descriptorField.stringValue, "example.desc")
    }

    func testProtobufDescriptorFieldReportsImportStatus() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: InMemoryTrafficProtobufDescriptorStore()
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 143,
            host: "status.protobuf.example.com",
            statusCode: 200,
            requestBody: Data([0x08, 0x96, 0x01]),
            requestContentType: "application/protobuf"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.request?.protobuf else {
                return false
            }
            return true
        }

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)

        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: { $0.accessibilityIdentifier() == "inspector.request.section" }
            )
        )
        let protobufSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Protobuf"
            }
        )
        sectionSelector.selectedSegment = protobufSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

        let descriptorField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.protobuf.descriptor"
                }
            )
        )
        let messageTypePopup = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.protobuf.messageType"
                }
            )
        )
        XCTAssertEqual(descriptorField.stringValue, "No descriptor")
        XCTAssertNil(descriptorField.toolTip)
        XCTAssertEqual(messageTypePopup.itemTitles, ["Schema-less"])

        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "example.desc"
        )
        try await viewModel.selectProtobufMessageType("example.User", direction: .request)
        controller.render(viewModel.snapshot)
        XCTAssertEqual(descriptorField.stringValue, "example.desc")
        XCTAssertEqual(descriptorField.toolTip, "example.desc")
        XCTAssertEqual(messageTypePopup.itemTitles, ["Schema-less", "example.User"])

        do {
            try await viewModel.importProtobufDescriptorSet(
                data: Data([0x0A, 0x7F]),
                sourceName: "broken.desc"
            )
            XCTFail("Expected the malformed descriptor import to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("extends past"))
        }

        controller.render(viewModel.snapshot)
        XCTAssertEqual(descriptorField.stringValue, "example.desc")
        XCTAssertEqual(messageTypePopup.itemTitles, ["Schema-less", "example.User"])
        XCTAssertEqual(messageTypePopup.titleOfSelectedItem, "example.User")
    }

    func testFailedProtobufImportKeepsThePreviousSchemaActiveInTheSnapshot() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: InMemoryTrafficProtobufDescriptorStore()
        )
        await viewModel.prepare()
        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "valid.desc"
        )
        try await viewModel.selectProtobufMessageType("example.User", direction: .request)

        let flow = try Self.makeFlow(
            index: 144,
            host: "failed-import.protobuf.example.com",
            statusCode: 200,
            requestBody: Data([0x08, 0x96, 0x01]),
            requestContentType: "application/protobuf"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard
                let request = viewModel.snapshot.inspection.request,
                case .content(_, let protobuf) = request.protobuf
            else {
                return false
            }
            return request.protobufSchema.selectedMessageType == "example.User"
                && protobuf.contains("1  id")
        }

        do {
            try await viewModel.importProtobufDescriptorSet(
                data: Data([0x0A, 0x7F]),
                sourceName: "broken.desc"
            )
            XCTFail("Expected the malformed descriptor import to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("extends past"))
        }

        let request = try XCTUnwrap(viewModel.snapshot.inspection.request)
        XCTAssertEqual(request.protobufSchema.descriptorName, "valid.desc")
        XCTAssertEqual(request.protobufSchema.messageTypeNames, ["example.User"])
        XCTAssertEqual(request.protobufSchema.selectedMessageType, "example.User")
        guard case .content(_, let protobuf) = request.protobuf else {
            return XCTFail("Expected decoded Protobuf content, got \(request.protobuf)")
        }
        XCTAssertTrue(protobuf.contains("1  id"))
        XCTAssertTrue(protobuf.contains("int32"))
        XCTAssertTrue(protobuf.contains("150"))
    }

    func testInspectorMessageTypePopupReturnsHTTPProtobufOutputToSchemaLess() async throws {
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60),
            protobufDescriptorStore: InMemoryTrafficProtobufDescriptorStore()
        )
        await viewModel.prepare()
        try await viewModel.importProtobufDescriptorSet(
            data: Self.singleMessageDescriptorSet,
            sourceName: "example.desc"
        )

        let flow = try Self.makeFlow(
            index: 145,
            host: "schemaless.protobuf.example.com",
            statusCode: 200,
            requestBody: Data([0x08, 0x96, 0x01]),
            responseBody: Data([0x08, 0x07]),
            responseContentType: "application/protobuf",
            requestContentType: "application/protobuf"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)

        try await waitUntil {
            guard case .content = viewModel.snapshot.inspection.response?.protobuf else {
                return false
            }
            return true
        }

        let controller = InspectorViewController(viewModel: viewModel)
        _ = controller.view
        controller.render(viewModel.snapshot)

        for prefix in ["inspector.request", "inspector.response"] {
            let sectionSelector = try XCTUnwrap(
                Self.descendant(
                    of: NSSegmentedControl.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == "\(prefix).section" }
                )
            )
            let protobufSegment = try XCTUnwrap(
                (0..<sectionSelector.segmentCount).first {
                    sectionSelector.label(forSegment: $0) == "Protobuf"
                }
            )
            sectionSelector.selectedSegment = protobufSegment
            sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

            let messageTypePopup = try XCTUnwrap(
                Self.descendant(
                    of: NSPopUpButton.self,
                    in: controller.view,
                    matching: {
                        $0.accessibilityIdentifier() == "\(prefix).protobuf.messageType"
                    }
                )
            )
            let textView = try XCTUnwrap(
                Self.descendant(
                    of: NSTextView.self,
                    in: controller.view,
                    matching: { $0.accessibilityIdentifier() == "\(prefix).content" }
                )
            )
            let isRequest = prefix == "inspector.request"

            messageTypePopup.selectItem(withTitle: "example.User")
            messageTypePopup.sendAction(messageTypePopup.action, to: messageTypePopup.target)
            try await waitUntil {
                let message =
                    isRequest
                    ? viewModel.snapshot.inspection.request
                    : viewModel.snapshot.inspection.response
                guard case .content(_, let protobuf) = message?.protobuf else {
                    return false
                }
                return message?.protobufSchema.selectedMessageType == "example.User"
                    && protobuf.contains("1  id")
            }
            controller.render(viewModel.snapshot)
            XCTAssertEqual(messageTypePopup.titleOfSelectedItem, "example.User")
            XCTAssertTrue(textView.string.contains("1  id"))
            XCTAssertTrue(textView.string.contains("int32"))

            messageTypePopup.selectItem(at: 0)
            messageTypePopup.sendAction(messageTypePopup.action, to: messageTypePopup.target)
            try await waitUntil {
                let message =
                    isRequest
                    ? viewModel.snapshot.inspection.request
                    : viewModel.snapshot.inspection.response
                guard case .content(_, let protobuf) = message?.protobuf else {
                    return false
                }
                return message?.protobufSchema.selectedMessageType == nil
                    && protobuf.contains("1  varint")
            }
            controller.render(viewModel.snapshot)
            XCTAssertEqual(messageTypePopup.titleOfSelectedItem, "Schema-less")
            XCTAssertTrue(
                textView.string.contains(isRequest ? "1  varint   150" : "1  varint   7")
            )
            XCTAssertFalse(textView.string.contains("int32"))
        }
    }

    func testRuleEditorScriptTemplatesDocumentWebSocketHandshakeSupport() throws {
        let editor = TrafficRuleEditorViewController()
        editor.loadView()

        let action = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.action" }
            )
        )
        action.selectItem(withTitle: "Script")
        action.sendAction(action.action, to: action.target)

        let sourceEditor = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.scriptSource" }
            )
        )
        let phase = try XCTUnwrap(
            Self.descendant(
                of: NSPopUpButton.self,
                in: editor.view,
                matching: { $0.accessibilityIdentifier() == "ruleEditor.phase" }
            )
        )

        phase.selectItem(withTitle: "Request Headers")
        phase.sendAction(phase.action, to: phase.target)
        let requestTemplate = sourceEditor.string
        XCTAssertTrue(requestTemplate.contains("function onRequest(context)"))
        XCTAssertTrue(
            requestTemplate.contains(
                "WebSocket handshakes support ws/wss URL and ordinary header edits."
            ),
            "Request header template must advertise WebSocket handshake support"
        )
        XCTAssertTrue(
            requestTemplate.contains(
                "The method and upgrade-critical headers are protected."
            ),
            "Request header template must name the protected fields"
        )

        phase.selectItem(withTitle: "Response Headers")
        phase.sendAction(phase.action, to: phase.target)
        let responseTemplate = sourceEditor.string
        XCTAssertTrue(responseTemplate.contains("function onResponse(context)"))
        XCTAssertTrue(
            responseTemplate.contains(
                "WebSocket handshakes support ordinary response header edits."
            ),
            "Response header template must advertise WebSocket handshake support"
        )
        XCTAssertTrue(
            responseTemplate.contains(
                "The 101 status and upgrade-critical headers are protected."
            ),
            "Response header template must name the protected fields"
        )
    }

    func testImageBodyPreviewBuilderCreatesABoundedNativeThumbnail() throws {
        let imageData = try Self.makePNG(width: 3, height: 2)
        let reference = BodyReference(
            inline: imageData,
            metadata: BodyMetadata(contentType: "image/png")
        )

        let presentation = ImageBodyPreviewBuilder.render(
            imageData,
            reference: reference,
            metadata: "\(imageData.count) B • image/png"
        )

        guard case .content(let preview) = presentation else {
            return XCTFail("Expected a decoded image preview, got \(presentation)")
        }
        XCTAssertEqual(preview.pixelWidth, 3)
        XCTAssertEqual(preview.pixelHeight, 2)
        XCTAssertEqual(preview.format, "PNG")
        XCTAssertEqual(preview.frameCount, 1)
        XCTAssertLessThanOrEqual(
            max(preview.thumbnailPixelWidth, preview.thumbnailPixelHeight),
            ImageBodyPreviewBuilder.maximumThumbnailPixelDimension
        )
        XCTAssertNotNil(NSImage(data: preview.thumbnailPNGData))
        XCTAssertTrue(preview.metadata.contains("3 × 2 px"))
    }

    func testImageBodyPreviewBuilderFailsClosedForUnsafeOrInvalidImages() throws {
        let oversized = Data(
            repeating: 0,
            count: ImageBodyPreviewBuilder.maximumDecodedByteCount + 1
        )
        let oversizedReference = BodyReference(
            inline: oversized,
            metadata: BodyMetadata(contentType: "image/png")
        )
        XCTAssertEqual(
            ImageBodyPreviewBuilder.render(
                oversized,
                reference: oversizedReference,
                metadata: "Oversized"
            ),
            .none(ImageBodyPreviewBuilder.exceedsPreviewLimitReason)
        )

        let invalid = Data("not an image".utf8)
        let invalidReference = BodyReference(
            inline: invalid,
            metadata: BodyMetadata(contentType: "image/png")
        )
        XCTAssertEqual(
            ImageBodyPreviewBuilder.render(
                invalid,
                reference: invalidReference,
                metadata: "Invalid"
            ),
            .none(ImageBodyPreviewBuilder.invalidImageReason)
        )

        let imageData = try Self.makePNG(width: 1, height: 1)
        let truncatedReference = BodyReference(
            inline: imageData,
            metadata: BodyMetadata(contentType: "image/png", isTruncated: true)
        )
        XCTAssertEqual(
            ImageBodyPreviewBuilder.render(
                imageData,
                reference: truncatedReference,
                metadata: "Truncated"
            ),
            .none(ImageBodyPreviewBuilder.truncatedImageReason)
        )
    }

    func testInspectorShowsNativeImagePreviewWithoutReplacingCapturedBody() async throws {
        let imageData = try Self.makePNG(width: 3, height: 2)
        let viewModel = TrafficConsoleViewModel(
            captureController: RecordingCaptureController(),
            eventSource: FinishedEventSource(),
            bodyReader: InlineBodyReader(),
            captureConfiguration: Self.captureConfiguration,
            eventBatchDelay: .seconds(60)
        )
        await viewModel.prepare()

        let flow = try Self.makeFlow(
            index: 10,
            host: "images.example.com",
            statusCode: 200,
            requestBody: imageData,
            requestContentType: "image/png"
        )
        viewModel.receive(.finished(flow))
        viewModel.flushPendingEvents()
        viewModel.selectFlow(flow.id)
        try await waitUntil {
            guard case .content(let preview) = viewModel.snapshot.inspection.request?.image else {
                return false
            }
            return preview.pixelWidth == 3 && preview.pixelHeight == 2
        }

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(viewModel.snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let previewSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Preview"
            }
        )
        sectionSelector.selectedSegment = previewSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

        let imageView = try XCTUnwrap(
            Self.descendant(
                of: NSImageView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.preview.image"
                }
            )
        )
        let metadataField = try XCTUnwrap(
            Self.descendant(
                of: NSTextField.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.preview.metadata"
                }
            )
        )
        XCTAssertFalse(imageView.isHiddenOrHasHiddenAncestor)
        XCTAssertNotNil(imageView.image)
        XCTAssertEqual(imageView.accessibilityLabel(), "PNG image, 3 by 2 pixels")
        XCTAssertTrue(metadataField.stringValue.contains("PNG • 3 × 2 px"))

        let bodySegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Body"
            }
        )
        sectionSelector.selectedSegment = bodySegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        let bodyTextView = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.content"
                }
            )
        )
        XCTAssertTrue(bodyTextView.string.contains("00000000"))
    }

    func testJSONTreeBuilderClassifiesValuesAndBoundsTheTree() throws {
        let presentation = TrafficJSONTreeBuilder.build(
            #"{"enabled":true,"items":[1,null,"two"]}"#
        )
        guard case .content(let root) = presentation else {
            return XCTFail("Expected a JSON tree")
        }
        XCTAssertEqual(root.key, "JSON")
        XCTAssertEqual(root.value, "{2 keys}")
        XCTAssertEqual(root.children.map(\.key), ["enabled", "items"])
        XCTAssertEqual(root.children[0].kind, .literal)
        XCTAssertEqual(root.children[0].value, "true")
        XCTAssertEqual(root.children[1].children.map(\.value), ["1", "null", #""two""#])

        let bounded = TrafficJSONTreeBuilder.build(
            #"{"a":1,"b":2,"c":3}"#,
            maximumNodeCount: 3
        )
        guard case .content(let boundedRoot) = bounded else {
            return XCTFail("Expected a bounded JSON tree")
        }
        XCTAssertEqual(boundedRoot.children.count, 2)
        XCTAssertEqual(boundedRoot.children.last?.kind, .notice)
        XCTAssertEqual(boundedRoot.children.last?.value, "More values omitted")
    }

    func testInspectorHighlightsBodyFromDeclaredContentTypeWithoutColoringMetadata() throws {
        let requestXML = #"<root id="42"/>"#
        let responseForm = "name=ProxyLens&enabled=true"
        let flowID = FlowID()
        let snapshot = TrafficConsoleSnapshot(
            capture: .stopped,
            workspaceWarning: nil,
            certificateTrust: nil,
            allFlowCount: 1,
            applications: [],
            pinnedDomains: [],
            domains: [],
            selectedSource: .allTraffic,
            displayFilter: .all,
            visibleRows: [],
            selectedFlowID: flowID,
            inspection: TrafficFlowInspection(
                flowID: flowID,
                title: "POST https://api.example.com/v1",
                request: TrafficMessageInspection(
                    title: "Request",
                    headers: "POST /v1 HTTP/1.1\nHost: api.example.com",
                    body: .content(metadata: "15 B • application/xml", value: requestXML),
                    json: .none("This body is not JSON."),
                    bodyContentType: "application/xml"
                ),
                response: TrafficMessageInspection(
                    title: "Response",
                    headers: "HTTP/1.1 200 OK",
                    body: .content(
                        metadata: "27 B • application/x-www-form-urlencoded",
                        value: responseForm
                    ),
                    json: .none("This body is not JSON."),
                    bodyContentType: "application/x-www-form-urlencoded"
                ),
                rules: "No rules applied to this flow.",
                breakpoint: nil
            )
        )

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(snapshot)

        for (prefix, token, expectedColor) in [
            ("request", "root", InspectorSyntaxPalette.key),
            ("response", "name", InspectorSyntaxPalette.key),
            ("response", "ProxyLens", InspectorSyntaxPalette.string)
        ] {
            let sectionSelector = try XCTUnwrap(
                Self.descendant(
                    of: NSSegmentedControl.self,
                    in: controller.view,
                    matching: {
                        $0.accessibilityIdentifier() == "inspector.\(prefix).section"
                    }
                )
            )
            let bodySegment = try XCTUnwrap(
                (0..<sectionSelector.segmentCount).first {
                    sectionSelector.label(forSegment: $0) == "Body"
                }
            )
            sectionSelector.selectedSegment = bodySegment
            sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)

            let inspector = try XCTUnwrap(
                Self.descendant(
                    of: NSTextView.self,
                    in: controller.view,
                    matching: {
                        $0.accessibilityIdentifier() == "inspector.\(prefix).content"
                    }
                )
            )
            let tokenRange = try XCTUnwrap(inspector.string.range(of: token))
            let tokenColor =
                inspector.textStorage?.attribute(
                    .foregroundColor,
                    at: NSRange(tokenRange, in: inspector.string).location,
                    effectiveRange: nil
                ) as? NSColor
            XCTAssertEqual(tokenColor, expectedColor)
            XCTAssertEqual(
                inspector.textStorage?.attribute(
                    .foregroundColor,
                    at: 0,
                    effectiveRange: nil
                ) as? NSColor,
                .textColor
            )
        }
    }

    func testInspectorDoesNotCopyJSONTabIntoBodyEditsDuringBreakpoint() throws {
        let compact = #"{"z":1,"a":2}"#
        let pretty = "{\n  \"a\" : 2,\n  \"z\" : 1\n}"
        let flowID = FlowID()
        let snapshot = TrafficConsoleSnapshot(
            capture: .stopped,
            workspaceWarning: nil,
            certificateTrust: nil,
            allFlowCount: 1,
            applications: [],
            pinnedDomains: [],
            domains: [],
            selectedSource: .allTraffic,
            displayFilter: .all,
            visibleRows: [],
            selectedFlowID: flowID,
            inspection: TrafficFlowInspection(
                flowID: flowID,
                title: "POST https://api.example.com/v1",
                request: TrafficMessageInspection(
                    title: "Request",
                    headers: "POST /v1 HTTP/1.1\nHost: api.example.com",
                    body: .content(metadata: "11 B", value: compact),
                    json: .content(metadata: "11 B", value: pretty),
                    bodyContentType: "application/json"
                ),
                response: nil,
                rules: "No rules applied to this flow.",
                breakpoint: TrafficBreakpointInspection(phase: .request, canEditBody: true)
            )
        )

        let controller = InspectorViewController()
        _ = controller.view
        controller.render(snapshot)
        let sectionSelector = try XCTUnwrap(
            Self.descendant(
                of: NSSegmentedControl.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.section"
                }
            )
        )
        let inspector = try XCTUnwrap(
            Self.descendant(
                of: NSTextView.self,
                in: controller.view,
                matching: {
                    $0.accessibilityIdentifier() == "inspector.request.content"
                }
            )
        )

        let bodySegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "Body"
            }
        )
        let jsonSegment = try XCTUnwrap(
            (0..<sectionSelector.segmentCount).first {
                sectionSelector.label(forSegment: $0) == "JSON"
            }
        )

        sectionSelector.selectedSegment = jsonSegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        XCTAssertTrue(inspector.string.contains(pretty))

        sectionSelector.selectedSegment = bodySegment
        sectionSelector.sendAction(sectionSelector.action, to: sectionSelector.target)
        XCTAssertEqual(inspector.string, compact)
        XCTAssertFalse(inspector.string.contains(pretty))
    }

    private static var captureConfiguration: CaptureConfiguration {
        CaptureConfiguration(
            proxy: ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                interceptHTTPS: false
            ),
            configuresSystemProxy: false
        )
    }

    private static let singleMessageDescriptorSet = Data([
        0x0A, 0x2C,  // FileDescriptorSet.file
        0x0A, 0x0D,  // FileDescriptorProto.name
        0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x2E, 0x70, 0x72, 0x6F, 0x74, 0x6F,
        0x12, 0x07,  // FileDescriptorProto.package
        0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
        0x22, 0x12,  // FileDescriptorProto.message_type
        0x0A, 0x04, 0x55, 0x73, 0x65, 0x72,  // DescriptorProto.name = User
        0x12, 0x0A,  // DescriptorProto.field
        0x0A, 0x02, 0x69, 0x64,  // FieldDescriptorProto.name = id
        0x18, 0x01,  // number = 1
        0x20, 0x01,  // label = optional
        0x28, 0x05  // type = int32
    ])

    private static func makeFlow(
        index: Int,
        host: String,
        statusCode: Int,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        method: HTTPMethod? = nil,
        responseContentType: String = "application/octet-stream",
        source: FlowSource = .desktopProxy,
        requestHeaderValue: String? = nil,
        requestContentType: String = "text/plain",
        requestContentEncoding: String? = nil,
        requestGRPCEncoding: String? = nil,
        requestCookieValues: [String] = [],
        responseSetCookieValues: [String] = [],
        sessionID: SessionID = SessionID()
    ) throws -> Flow {
        var requestHeaders = HTTPHeaders()
        try requestHeaders.append(name: "Host", value: host)
        try requestHeaders.append(name: "Accept", value: "application/json")
        if let requestHeaderValue {
            try requestHeaders.append(name: "X-Debug-Label", value: requestHeaderValue)
        }
        for value in requestCookieValues {
            try requestHeaders.append(name: "Cookie", value: value)
        }
        if let requestBody {
            try requestHeaders.append(name: "Content-Type", value: requestContentType)
            try requestHeaders.append(name: "Content-Length", value: "\(requestBody.count)")
            if let requestContentEncoding {
                try requestHeaders.append(name: "Content-Encoding", value: requestContentEncoding)
            }
            if let requestGRPCEncoding {
                try requestHeaders.append(name: "grpc-encoding", value: requestGRPCEncoding)
            }
        }
        var request = HTTPRequest(
            method: method ?? (index.isMultiple(of: 2) ? .get : .post),
            url: try XCTUnwrap(URL(string: "https://\(host)/v1/items/\(index)?source=test")),
            headers: requestHeaders
        )
        if let requestBody {
            request.attachBody(
                BodyReference(
                    inline: requestBody,
                    metadata: BodyMetadata(
                        contentType: requestContentType,
                        contentEncoding: requestContentEncoding
                    )
                )
            )
        }

        var responseHeaders = HTTPHeaders()
        try responseHeaders.append(name: "Content-Type", value: responseContentType)
        for value in responseSetCookieValues {
            try responseHeaders.append(name: "Set-Cookie", value: value)
        }
        var response = try HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: "Result",
            headers: responseHeaders
        )
        if let responseBody {
            response.attachBody(
                BodyReference(
                    inline: responseBody,
                    metadata: BodyMetadata(contentType: responseContentType)
                )
            )
        }

        var flow = Flow(
            sessionID: sessionID,
            source: source,
            request: request,
            connection: ConnectionInfo(
                protocolKind: .https,
                upstreamHost: host,
                upstreamPort: 443,
                tlsIntercepted: true
            ),
            startedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
        try flow.transition(to: .receivingRequest)
        try flow.transition(to: .connectingUpstream)
        try flow.transition(to: .receivingResponse)
        flow.attachResponse(response)
        flow.markCompleted(at: Date(timeIntervalSince1970: TimeInterval(index) + 0.25))
        try flow.transition(to: .completed)
        return flow
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            )
        )
        bitmap.setColor(
            NSColor(deviceRed: 0.1, green: 0.45, blue: 0.9, alpha: 1),
            atX: 0,
            y: 0
        )
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private static func descendant<T: NSView>(
        of type: T.Type,
        in root: NSView,
        matching predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = root as? T, predicate(match) {
            return match
        }
        for subview in root.subviews {
            if let match = descendant(of: type, in: subview, matching: predicate) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not satisfied before timeout")
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not satisfied before timeout")
    }
}

@MainActor
private final class RecordingTableView: NSTableView {
    private(set) var fullReloadCount = 0
    private(set) var insertedRowIndexes: [IndexSet] = []
    private(set) var removedRowIndexes: [IndexSet] = []
    private(set) var movedRows: [(from: Int, to: Int)] = []
    private(set) var dataSourceRowCountsDuringRemovals: [Int] = []
    var clickedRowOverride: Int?

    override var clickedRow: Int {
        clickedRowOverride ?? super.clickedRow
    }

    override func reloadData() {
        fullReloadCount += 1
        super.reloadData()
    }

    override func insertRows(
        at indexes: IndexSet,
        withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        insertedRowIndexes.append(indexes)
        super.insertRows(at: indexes, withAnimation: animationOptions)
    }

    override func removeRows(
        at indexes: IndexSet,
        withAnimation animationOptions: NSTableView.AnimationOptions
    ) {
        if let numberOfRows = dataSource?.numberOfRows {
            dataSourceRowCountsDuringRemovals.append(numberOfRows(self))
        }
        removedRowIndexes.append(indexes)
        super.removeRows(at: indexes, withAnimation: animationOptions)
    }

    override func moveRow(at oldIndex: Int, to newIndex: Int) {
        movedRows.append((from: oldIndex, to: newIndex))
        super.moveRow(at: oldIndex, to: newIndex)
    }

    func resetRecordedUpdates() {
        fullReloadCount = 0
        insertedRowIndexes = []
        removedRowIndexes = []
        movedRows = []
        dataSourceRowCountsDuringRemovals = []
    }
}

private actor RecordingCaptureController: TrafficCaptureControlling {
    private var recordedCalls: [String] = []
    private var stopError: CaptureCoordinatorError?

    init(stopError: CaptureCoordinatorError? = nil) {
        self.stopError = stopError
    }

    func recoverInterruptedCapture() {
        recordedCalls.append("recover")
    }

    func start(configuration: CaptureConfiguration) -> CaptureContext {
        recordedCalls.append("start")
        return CaptureContext(
            sessionID: SessionID(),
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 59_090),
            startedAt: Date(timeIntervalSince1970: 1_000),
            configuration: configuration
        )
    }

    func stop() throws {
        recordedCalls.append("stop")
        if let stopError {
            self.stopError = nil
            throw stopError
        }
    }

    func calls() -> [String] {
        recordedCalls
    }
}

private actor FinishedEventSource: TrafficFlowEventStreaming {
    func makeEventStream() -> AsyncStream<FlowEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private actor RecordingRuleProfileStore: RuleProfileStoring {
    private var profiles: [RuleProfile] = []

    func list() -> [RuleProfile] {
        profiles
    }

    func save(_ profile: RuleProfile) -> RuleProfile {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = profiles.first {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
        let saved = RuleProfile(
            id: existing?.id ?? profile.id,
            name: name,
            rules: profile.rules,
            mappedLocals: profile.mappedLocals,
            createdAt: existing?.createdAt ?? profile.createdAt,
            updatedAt: profile.updatedAt
        )
        profiles.removeAll { $0.id == saved.id }
        profiles.append(saved)
        return saved
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
    }
}

private actor InlineBodyReader: TrafficBodyReading {
    func read(_ reference: BodyReference) throws -> Data {
        guard case .inline(let data) = reference.storage else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }
}

private actor TrackingTrafficBodyReader: TrafficBodyReading {
    private let externalPayloads: [BodyID: Data]
    private var recordedReadIDs: [BodyID] = []

    init(externalPayloads: [BodyID: Data]) {
        self.externalPayloads = externalPayloads
    }

    func read(_ reference: BodyReference) throws -> Data {
        recordedReadIDs.append(reference.id)
        switch reference.storage {
        case .inline(let data):
            return data
        case .external(let id):
            guard let data = externalPayloads[id] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return data
        }
    }

    func readIDs() -> [BodyID] {
        recordedReadIDs
    }
}

private actor StaticWebSocketFrameLoader: TrafficWebSocketFrameLoading {
    private let frames: [CapturedWebSocketFrame]

    init(frames: [CapturedWebSocketFrame]) {
        self.frames = frames
    }

    func listWebSocketFrames(for flowID: FlowID) -> [CapturedWebSocketFrame] {
        frames.filter { $0.flowID == flowID }
    }
}

private actor StaticServerSentEventLoader: TrafficServerSentEventLoading {
    private let events: [CapturedServerSentEvent]

    init(events: [CapturedServerSentEvent]) {
        self.events = events
    }

    func listServerSentEvents(for flowID: FlowID) -> [CapturedServerSentEvent] {
        events.filter { $0.flowID == flowID }
    }
}

private actor RecordingTrafficWebSocketComposer: TrafficWebSocketComposing {
    private let openFlowIDs: Set<FlowID>
    private var recordedRequests: [WebSocketComposeRequest] = []
    private var recordedReconnectRequests: [(WebSocketReconnectRequest, SessionID)] = []
    private var recordedDisconnectFlowIDs: [FlowID] = []
    private let reconnectResult: Flow?

    init(openFlowIDs: Set<FlowID>, reconnectResult: Flow? = nil) {
        self.openFlowIDs = openFlowIDs
        self.reconnectResult = reconnectResult
    }

    func isConnectionOpen(for flowID: FlowID) -> Bool {
        openFlowIDs.contains(flowID)
    }

    func send(_ request: WebSocketComposeRequest) {
        recordedRequests.append(request)
    }

    func reconnect(
        _ request: WebSocketReconnectRequest,
        sessionID: SessionID
    ) throws -> Flow {
        recordedReconnectRequests.append((request, sessionID))
        guard let reconnectResult else {
            throw WebSocketReconnectError.unavailable
        }
        return reconnectResult
    }

    func disconnect(flowID: FlowID) {
        recordedDisconnectFlowIDs.append(flowID)
    }

    func requests() -> [WebSocketComposeRequest] {
        recordedRequests
    }

    func reconnectRequests() -> [(WebSocketReconnectRequest, SessionID)] {
        recordedReconnectRequests
    }

    func disconnectFlowIDs() -> [FlowID] {
        recordedDisconnectFlowIDs
    }
}

private actor InlineBodyStore: BodyStore {
    func beginWrite(
        metadata _: BodyMetadata,
        maximumByteCount _: Int64?
    ) throws -> any BodyWriter {
        throw CocoaError(.fileWriteUnknown)
    }

    func read(_ reference: BodyReference) throws -> Data {
        guard case .inline(let data) = reference.storage else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func remove(_: BodyReference) {}
}

private actor RecordingRequestReplayer: TrafficRequestReplaying {
    private let result: Flow
    private var requests: [(request: HTTPRequest, sessionID: SessionID)] = []

    init(result: Flow) {
        self.result = result
    }

    func repeatRequest(_ request: HTTPRequest, sessionID: SessionID) -> Flow {
        requests.append((request, sessionID))
        return result
    }

    func receivedRequests() -> [(request: HTTPRequest, sessionID: SessionID)] {
        requests
    }
}

private actor RecordingHARImporter: TrafficHARImporting {
    private let result: HARImportResult
    private var fileURLs: [URL] = []

    init(result: HARImportResult) {
        self.result = result
    }

    func importHAR(from fileURL: URL) -> HARImportResult {
        fileURLs.append(fileURL)
        return result
    }

    func importedURLs() -> [URL] {
        fileURLs
    }
}

private actor RecordingPortableSessionTransfer: TrafficPortableSessionTransferring {
    struct Calls: Sendable {
        let importedURLs: [URL]
        let exports: [(sessionID: SessionID, fileURL: URL)]
    }

    private let result: PortableSessionImportResult
    private var importedURLs: [URL] = []
    private var exports: [(sessionID: SessionID, fileURL: URL)] = []

    init(result: PortableSessionImportResult) {
        self.result = result
    }

    func importSession(from fileURL: URL) -> PortableSessionImportResult {
        importedURLs.append(fileURL)
        return result
    }

    func exportSession(sessionID: SessionID, to fileURL: URL) {
        exports.append((sessionID, fileURL))
    }

    func calls() -> Calls {
        Calls(importedURLs: importedURLs, exports: exports)
    }
}

private actor RecordingSessionService: TrafficSessionLoading {
    private var flows: [Flow]
    private var sessions: [Session]
    private var didClear = false
    private let loadError: (any Error)?
    private let composeSessionID: SessionID
    private var composeSessionRequests = 0
    private var removedSessions: [SessionID] = []
    private var loadSessionsCalls = 0

    init(
        flows: [Flow] = [],
        sessions: [Session] = [],
        loadError: (any Error)? = nil,
        composeSessionID: SessionID = SessionID()
    ) {
        self.flows = flows
        self.sessions = sessions
        self.loadError = loadError
        self.composeSessionID = composeSessionID
    }

    func loadWorkspace() throws -> [Flow] {
        if let loadError {
            throw loadError
        }
        return flows
    }

    func loadSessions() throws -> [Session] {
        loadSessionsCalls += 1
        if let loadError {
            throw loadError
        }
        return sessions
    }

    func renameSession(sessionID: SessionID, to name: String?) throws -> Session? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return nil
        }
        try sessions[index].rename(to: name)
        return sessions[index]
    }

    func removeSession(sessionID: SessionID) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        guard sessions[index].state != .recording else {
            throw ProxyLensError.cannotRemoveRecordingSession
        }
        sessions.remove(at: index)
        flows.removeAll { $0.sessionID == sessionID }
        removedSessions.append(sessionID)
    }

    func clearWorkspace() {
        flows = []
        sessions = []
        didClear = true
    }

    func sessionIDForNewFlow() -> SessionID {
        composeSessionRequests += 1
        return composeSessionID
    }

    func updateAnnotation(_ annotation: FlowAnnotation?, for flowID: FlowID) -> Flow? {
        guard let index = flows.firstIndex(where: { $0.id == flowID }) else {
            return nil
        }
        flows[index].setAnnotation(annotation)
        return flows[index]
    }

    func cleared() -> Bool {
        didClear
    }

    func composeSessionRequestCount() -> Int {
        composeSessionRequests
    }

    func removedSessionIDs() -> [SessionID] {
        removedSessions
    }

    func loadSessionsCallCount() -> Int {
        loadSessionsCalls
    }
}

private actor RecordingCertificateTrust: TrafficCertificateTrusting {
    private var currentState: CertificateTrustState
    private var installError: (any Error)?
    private var recordedCalls: [String] = []
    private var exported: [URL] = []

    init(state: CertificateTrustState) {
        currentState = state
    }

    func state() -> CertificateTrustState {
        recordedCalls.append("state")
        return currentState
    }

    func install() throws {
        recordedCalls.append("install")
        if let installError {
            self.installError = nil
            throw installError
        }
        currentState = .trusted
    }

    func remove() {
        recordedCalls.append("remove")
        if currentState != .notGenerated {
            currentState = .untrusted
        }
    }

    func exportRootCertificate(to url: URL) throws {
        recordedCalls.append("export")
        exported.append(url)
        try Data().write(to: url)
    }

    func failNextInstall(_ error: any Error) {
        installError = error
    }

    func calls() -> [String] {
        recordedCalls
    }

    func exportedURLs() -> [URL] {
        exported
    }
}
