import AppKit
import ProxyLensCore

enum TrafficRuleDraftError: Error, Equatable, LocalizedError {
    case missingName
    case missingMatcherValue
    case missingScriptSource
    case invalidRegularExpression
    case unsupportedPhase

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Enter a rule name."
        case .missingMatcherValue:
            "Enter a matcher value."
        case .missingScriptSource:
            "Enter JavaScript source for the rule."
        case .invalidRegularExpression:
            "Enter a valid regular expression."
        case .unsupportedPhase:
            "The selected action cannot run in that phase."
        }
    }
}

enum TrafficRuleActionKind: String, CaseIterable {
    case dnsSpoof
    case block
    case allow
    case breakpoint
    case noCache
    case script

    var title: String {
        switch self {
        case .dnsSpoof:
            "DNS Spoof"
        case .block:
            "Block"
        case .allow:
            "Allow"
        case .breakpoint:
            "Breakpoint"
        case .noCache:
            "No Cache"
        case .script:
            "Script"
        }
    }

    var allowedPhases: [RulePhase] {
        switch self {
        case .dnsSpoof:
            [.connection]
        case .block:
            [.requestHeaders, .requestBody]
        case .allow:
            [.requestHeaders]
        case .breakpoint:
            [.requestHeaders, .requestBody, .responseHeaders, .webSocketFrame]
        case .noCache:
            [.requestHeaders, .responseHeaders]
        case .script:
            [.requestHeaders, .requestBody, .responseHeaders, .responseBody]
        }
    }

    var ruleAction: RuleAction? {
        switch self {
        case .dnsSpoof:
            nil
        case .block:
            .block(reason: "Blocked by ProxyLens")
        case .allow:
            .allow
        case .breakpoint:
            .breakpoint
        case .noCache:
            .noCache
        case .script:
            nil
        }
    }

    init?(ruleAction: RuleAction) {
        switch ruleAction {
        case .dnsSpoof:
            self = .dnsSpoof
        case .block:
            self = .block
        case .allow:
            self = .allow
        case .breakpoint:
            self = .breakpoint
        case .noCache:
            self = .noCache
        case .script:
            self = .script
        case .mapLocal, .mapRemote, .replaceBody, .throttle, .redirect, .annotate:
            return nil
        }
    }
}

enum TrafficRuleMatcherKind: String, CaseIterable {
    case any
    case host
    case path
    case method
    case contentType
    case source

    var title: String {
        switch self {
        case .any:
            "All Traffic"
        case .host:
            "Host"
        case .path:
            "Path"
        case .method:
            "Method"
        case .contentType:
            "Content Type"
        case .source:
            "Source"
        }
    }
}

enum TrafficRulePatternKind: String, CaseIterable {
    case exact
    case wildcard
    case regularExpression

    var title: String {
        switch self {
        case .exact:
            "Is Exactly"
        case .wildcard:
            "Wildcard"
        case .regularExpression:
            "Regular Expression"
        }
    }
}

struct TrafficRuleDraft {
    let id: RuleID?
    let name: String
    let priority: Int
    let action: TrafficRuleActionKind
    let phase: RulePhase
    let matcher: TrafficRuleMatcherKind
    let patternKind: TrafficRulePatternKind
    let matcherValue: String
    let actionValue: String
    let scriptSource: String
    let enabled: Bool
    private let originalAction: RuleAction?

    init(
        id: RuleID? = nil,
        name: String,
        priority: Int,
        action: TrafficRuleActionKind,
        phase: RulePhase,
        matcher: TrafficRuleMatcherKind,
        patternKind: TrafficRulePatternKind,
        matcherValue: String,
        actionValue: String = "",
        scriptSource: String = "",
        enabled: Bool = true,
        originalAction: RuleAction? = nil
    ) {
        self.id = id
        self.name = name
        self.priority = priority
        self.action = action
        self.phase = phase
        self.matcher = matcher
        self.patternKind = patternKind
        self.matcherValue = matcherValue
        self.actionValue = actionValue
        self.scriptSource = scriptSource
        self.enabled = enabled
        self.originalAction = originalAction
    }

    init?(rule: Rule) {
        guard
            let action = TrafficRuleActionKind(ruleAction: rule.action),
            let matcherConfiguration = Self.matcherConfiguration(for: rule.matcher),
            action.allowedPhases.contains(rule.phase)
        else {
            return nil
        }

        self.init(
            id: rule.id,
            name: rule.name,
            priority: rule.priority,
            action: action,
            phase: rule.phase,
            matcher: matcherConfiguration.matcher,
            patternKind: matcherConfiguration.pattern,
            matcherValue: matcherConfiguration.value,
            actionValue: Self.actionValue(for: rule.action),
            scriptSource: Self.scriptSource(for: rule.action),
            enabled: rule.enabled,
            originalAction: rule.action
        )
    }

    func makeRule() throws -> Rule {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw TrafficRuleDraftError.missingName
        }
        guard action.allowedPhases.contains(phase) else {
            throw TrafficRuleDraftError.unsupportedPhase
        }

        return Rule(
            id: id ?? RuleID(),
            name: normalizedName,
            enabled: enabled,
            priority: priority,
            phase: phase,
            matcher: try makeMatcher(),
            action: try resolvedAction()
        )
    }

    func updating(
        name: String,
        priority: Int,
        action: TrafficRuleActionKind,
        phase: RulePhase,
        matcher: TrafficRuleMatcherKind,
        patternKind: TrafficRulePatternKind,
        matcherValue: String,
        actionValue: String,
        scriptSource: String,
        enabled: Bool
    ) -> TrafficRuleDraft {
        TrafficRuleDraft(
            id: id,
            name: name,
            priority: priority,
            action: action,
            phase: phase,
            matcher: matcher,
            patternKind: patternKind,
            matcherValue: matcherValue,
            actionValue: actionValue,
            scriptSource: scriptSource,
            enabled: enabled,
            originalAction: originalAction
        )
    }

    private func resolvedAction() throws -> RuleAction {
        if action == .dnsSpoof {
            return .dnsSpoof(try DNSSpoofSpec(address: actionValue))
        }
        if action == .script {
            guard !scriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TrafficRuleDraftError.missingScriptSource
            }
            return .script(try ScriptRuleSpec(source: scriptSource))
        }
        guard let originalAction,
            TrafficRuleActionKind(ruleAction: originalAction) == action
        else {
            guard let ruleAction = action.ruleAction else {
                throw TrafficRuleDraftError.unsupportedPhase
            }
            return ruleAction
        }
        return originalAction
    }

    private static func scriptSource(for action: RuleAction) -> String {
        guard case .script(let spec) = action else {
            return ""
        }
        return spec.source
    }

    private static func actionValue(for action: RuleAction) -> String {
        guard case .dnsSpoof(let spec) = action else {
            return ""
        }
        return spec.address
    }

    private func makeMatcher() throws -> Matcher {
        guard matcher != .any else {
            return .any
        }

        let value = matcherValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw TrafficRuleDraftError.missingMatcherValue
        }
        if matcher == .method {
            return .method(HTTPMethod(rawValue: value))
        }

        let pattern: StringPattern
        switch patternKind {
        case .exact:
            pattern = .exact(value)
        case .wildcard:
            pattern = .wildcard(value)
        case .regularExpression:
            guard (try? NSRegularExpression(pattern: value)) != nil else {
                throw TrafficRuleDraftError.invalidRegularExpression
            }
            pattern = .regularExpression(value)
        }

        switch matcher {
        case .any, .method:
            return .any
        case .host:
            return .host(pattern)
        case .path:
            return .path(pattern)
        case .contentType:
            return .contentType(pattern)
        case .source:
            return .source(pattern)
        }
    }

    private static func matcherConfiguration(for matcher: Matcher) -> (
        matcher: TrafficRuleMatcherKind,
        pattern: TrafficRulePatternKind,
        value: String
    )? {
        switch matcher {
        case .any:
            return (.any, .exact, "")
        case .method(let method):
            return (.method, .exact, method.rawValue)
        case .host(let pattern):
            return configuration(kind: .host, pattern: pattern)
        case .path(let pattern):
            return configuration(kind: .path, pattern: pattern)
        case .contentType(let pattern):
            return configuration(kind: .contentType, pattern: pattern)
        case .source(let pattern):
            return configuration(kind: .source, pattern: pattern)
        case .query, .header, .status, .graphqlOperation, .allOf, .anyOf, .not:
            return nil
        }
    }

    private static func configuration(
        kind: TrafficRuleMatcherKind,
        pattern: StringPattern
    ) -> (matcher: TrafficRuleMatcherKind, pattern: TrafficRulePatternKind, value: String)? {
        guard !pattern.caseSensitive else {
            return nil
        }
        let patternKind: TrafficRulePatternKind
        switch pattern.kind {
        case .exact:
            patternKind = .exact
        case .wildcard:
            patternKind = .wildcard
        case .regularExpression:
            patternKind = .regularExpression
        }
        return (kind, patternKind, pattern.value)
    }
}

@MainActor
final class TrafficRuleEditorViewController: NSViewController, NSTextViewDelegate {
    var onSubmit: ((Rule) -> Void)?
    var onCancel: (() -> Void)?

    private let initialDraft: TrafficRuleDraft?

    private let nameField = NSTextField()
    private let actionPopup = NSPopUpButton()
    private let actionValueLabel = NSTextField(labelWithString: "Address")
    private let actionValueField = NSTextField()
    private let phasePopup = NSPopUpButton()
    private let matcherPopup = NSPopUpButton()
    private let patternPopup = NSPopUpButton()
    private let valueField = NSTextField()
    private let priorityField = NSTextField(string: "10")
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let scriptSection = NSView()
    private let scriptTextView = NSTextView()
    private let scriptScrollView = NSScrollView()
    private let scriptByteCountField = NSTextField(labelWithString: "")
    private let scriptHelpField = NSTextField(wrappingLabelWithString: "")
    private let errorField = NSTextField(wrappingLabelWithString: "")
    private var phaseChoices: [RulePhase] = []
    private var scriptSectionHeightConstraint: NSLayoutConstraint?
    private var lastSeededScriptTemplate: String?
    private var isApplyingScriptHighlight = false

    init(draft: TrafficRuleDraft? = nil) {
        initialDraft = draft
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("ruleEditor")

        let title = NSTextField(labelWithString: initialDraft == nil ? "New Rule" : "Edit Rule")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Create a live rule with a bounded matcher. Body scripts run in an isolated worker."
        )
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        configureControls()
        configureScriptSection()
        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Action"), actionPopup],
            [actionValueLabel, actionValueField],
            [label("Phase"), phasePopup],
            [label("Match"), matcherPopup],
            [label("Comparison"), patternPopup],
            [label("Value"), valueField],
            [label("Priority"), priorityField],
            [NSView(), enabledButton]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        errorField.translatesAutoresizingMaskIntoConstraints = false
        errorField.textColor = .systemRed
        errorField.isHidden = true
        errorField.setAccessibilityIdentifier("ruleEditor.error")

        let createButton = NSButton(
            title: initialDraft == nil ? "Create Rule" : "Save Changes",
            target: self,
            action: #selector(submit)
        )
        createButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.setAccessibilityIdentifier("ruleEditor.create")

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("ruleEditor.cancel")

        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)
        container.addSubview(scriptSection)
        container.addSubview(errorField)
        container.addSubview(createButton)
        container.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            scriptSection.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scriptSection.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scriptSection.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            errorField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            errorField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            errorField.topAnchor.constraint(equalTo: scriptSection.bottomAnchor, constant: 10),
            cancelButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            createButton.trailingAnchor.constraint(
                equalTo: cancelButton.leadingAnchor, constant: -8),
            createButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor)
        ])

        view = container
        applyInitialDraft()
        updatePhaseChoices()
        if let initialDraft, let index = phaseChoices.firstIndex(of: initialDraft.phase) {
            phasePopup.selectItem(at: index)
        }
        updateMatcherControls()
        updateActionControls()
        updateScriptControls()
    }

    private func configureControls() {
        nameField.placeholderString = "e.g. Pause staging API"
        nameField.setAccessibilityIdentifier("ruleEditor.name")

        actionPopup.addItems(withTitles: TrafficRuleActionKind.allCases.map(\.title))
        actionPopup.target = self
        actionPopup.action = #selector(actionChanged)
        actionPopup.setAccessibilityIdentifier("ruleEditor.action")

        actionValueLabel.textColor = .secondaryLabelColor
        actionValueField.placeholderString = "127.0.0.1 or ::1"
        actionValueField.setAccessibilityIdentifier("ruleEditor.actionValue")
        actionValueField.setAccessibilityLabel("DNS spoof address")
        actionValueField.setAccessibilityHelp(
            "Enter a numeric IPv4 or IPv6 destination. Hostnames and ports are not accepted."
        )

        phasePopup.setAccessibilityIdentifier("ruleEditor.phase")
        phasePopup.target = self
        phasePopup.action = #selector(phaseChanged)

        matcherPopup.addItems(withTitles: TrafficRuleMatcherKind.allCases.map(\.title))
        matcherPopup.target = self
        matcherPopup.action = #selector(matcherChanged)
        matcherPopup.setAccessibilityIdentifier("ruleEditor.matcher")

        patternPopup.addItems(withTitles: TrafficRulePatternKind.allCases.map(\.title))
        patternPopup.setAccessibilityIdentifier("ruleEditor.pattern")
        valueField.setAccessibilityIdentifier("ruleEditor.value")
        priorityField.setAccessibilityIdentifier("ruleEditor.priority")
        enabledButton.state = .on
        enabledButton.setAccessibilityIdentifier("ruleEditor.enabled")
    }

    private func configureScriptSection() {
        scriptSection.translatesAutoresizingMaskIntoConstraints = false
        scriptSection.setAccessibilityIdentifier("ruleEditor.scriptSection")

        let scriptLabel = NSTextField(labelWithString: "JavaScript")
        scriptLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        scriptLabel.translatesAutoresizingMaskIntoConstraints = false

        scriptByteCountField.alignment = .right
        scriptByteCountField.textColor = .secondaryLabelColor
        scriptByteCountField.translatesAutoresizingMaskIntoConstraints = false
        scriptByteCountField.setAccessibilityIdentifier("ruleEditor.scriptByteCount")

        scriptTextView.delegate = self
        scriptTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scriptTextView.textContainerInset = NSSize(width: 8, height: 8)
        scriptTextView.isAutomaticQuoteSubstitutionEnabled = false
        scriptTextView.isAutomaticDashSubstitutionEnabled = false
        scriptTextView.isAutomaticTextReplacementEnabled = false
        scriptTextView.isHorizontallyResizable = true
        scriptTextView.isVerticallyResizable = true
        scriptTextView.autoresizingMask = [.width]
        scriptTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scriptTextView.textContainer?.widthTracksTextView = false
        scriptTextView.usesFindBar = true
        scriptTextView.isIncrementalSearchingEnabled = true
        scriptTextView.setAccessibilityIdentifier("ruleEditor.scriptSource")
        scriptTextView.setAccessibilityLabel("JavaScript source")
        scriptTextView.setAccessibilityHelp(
            "Define onRequest(context) or onResponse(context) and return the edited message."
        )

        scriptScrollView.documentView = scriptTextView
        scriptScrollView.borderType = .bezelBorder
        scriptScrollView.hasVerticalScroller = true
        scriptScrollView.hasHorizontalScroller = true
        scriptScrollView.autohidesScrollers = true
        scriptScrollView.translatesAutoresizingMaskIntoConstraints = false

        scriptHelpField.stringValue =
            "Runs in an isolated worker. Header phases cannot read or replace bodies. Async functions are not supported yet."
        scriptHelpField.textColor = .secondaryLabelColor
        scriptHelpField.maximumNumberOfLines = 2
        scriptHelpField.translatesAutoresizingMaskIntoConstraints = false
        scriptHelpField.setAccessibilityIdentifier("ruleEditor.scriptHelp")

        scriptSection.addSubview(scriptLabel)
        scriptSection.addSubview(scriptByteCountField)
        scriptSection.addSubview(scriptScrollView)
        scriptSection.addSubview(scriptHelpField)
        NSLayoutConstraint.activate([
            scriptLabel.leadingAnchor.constraint(equalTo: scriptSection.leadingAnchor),
            scriptLabel.topAnchor.constraint(equalTo: scriptSection.topAnchor),
            scriptByteCountField.trailingAnchor.constraint(equalTo: scriptSection.trailingAnchor),
            scriptByteCountField.centerYAnchor.constraint(equalTo: scriptLabel.centerYAnchor),
            scriptScrollView.leadingAnchor.constraint(equalTo: scriptSection.leadingAnchor),
            scriptScrollView.trailingAnchor.constraint(equalTo: scriptSection.trailingAnchor),
            scriptScrollView.topAnchor.constraint(equalTo: scriptLabel.bottomAnchor, constant: 6),
            scriptScrollView.heightAnchor.constraint(equalToConstant: 190),
            scriptHelpField.leadingAnchor.constraint(equalTo: scriptSection.leadingAnchor),
            scriptHelpField.trailingAnchor.constraint(equalTo: scriptSection.trailingAnchor),
            scriptHelpField.topAnchor.constraint(
                equalTo: scriptScrollView.bottomAnchor, constant: 6),
            scriptHelpField.bottomAnchor.constraint(equalTo: scriptSection.bottomAnchor)
        ])
        let heightConstraint = scriptSection.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        scriptSectionHeightConstraint = heightConstraint
    }

    private func applyInitialDraft() {
        guard let initialDraft else {
            return
        }
        nameField.stringValue = initialDraft.name
        priorityField.integerValue = initialDraft.priority
        enabledButton.state = initialDraft.enabled ? .on : .off
        actionPopup.selectItem(
            at: TrafficRuleActionKind.allCases.firstIndex(of: initialDraft.action)!)
        matcherPopup.selectItem(
            at: TrafficRuleMatcherKind.allCases.firstIndex(of: initialDraft.matcher)!)
        patternPopup.selectItem(
            at: TrafficRulePatternKind.allCases.firstIndex(of: initialDraft.patternKind)!)
        valueField.stringValue = initialDraft.matcherValue
        actionValueField.stringValue = initialDraft.actionValue
        scriptTextView.string = initialDraft.scriptSource
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.textColor = .secondaryLabelColor
        return field
    }

    private var selectedAction: TrafficRuleActionKind {
        TrafficRuleActionKind.allCases[max(0, actionPopup.indexOfSelectedItem)]
    }

    private var selectedMatcher: TrafficRuleMatcherKind {
        TrafficRuleMatcherKind.allCases[max(0, matcherPopup.indexOfSelectedItem)]
    }

    private var selectedPattern: TrafficRulePatternKind {
        TrafficRulePatternKind.allCases[max(0, patternPopup.indexOfSelectedItem)]
    }

    private func updatePhaseChoices() {
        let previous =
            phaseChoices.indices.contains(phasePopup.indexOfSelectedItem)
            ? phaseChoices[phasePopup.indexOfSelectedItem] : nil
        phaseChoices = selectedAction.allowedPhases
        phasePopup.removeAllItems()
        phasePopup.addItems(withTitles: phaseChoices.map(Self.phaseTitle))
        if let previous, let index = phaseChoices.firstIndex(of: previous) {
            phasePopup.selectItem(at: index)
        }
    }

    private func updateMatcherControls() {
        let matcher = selectedMatcher
        let hasValue = matcher != .any
        valueField.isEnabled = hasValue
        patternPopup.isEnabled = hasValue && matcher != .method
        valueField.placeholderString = matcher == .method ? "GET" : "Matcher value"
    }

    private func updateActionControls() {
        let showsAddress = selectedAction == .dnsSpoof
        actionValueLabel.isHidden = !showsAddress
        actionValueField.isHidden = !showsAddress
        actionValueField.isEnabled = showsAddress
    }

    private var selectedPhase: RulePhase? {
        guard phaseChoices.indices.contains(phasePopup.indexOfSelectedItem) else {
            return nil
        }
        return phaseChoices[phasePopup.indexOfSelectedItem]
    }

    private func updateScriptControls() {
        let showsScript = selectedAction == .script
        scriptSection.isHidden = !showsScript
        scriptScrollView.isHidden = !showsScript
        scriptSectionHeightConstraint?.constant = showsScript ? 260 : 0
        preferredContentSize = NSSize(
            width: showsScript ? 720 : 560,
            height: showsScript ? 700 : 430
        )

        guard showsScript, let phase = selectedPhase else {
            return
        }
        seedScriptTemplateIfNeeded(for: phase)
        applyScriptHighlighting()
        updateScriptByteCount()
    }

    private func seedScriptTemplateIfNeeded(for phase: RulePhase) {
        let currentSource = scriptTextView.string
        guard
            currentSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || currentSource == lastSeededScriptTemplate
        else {
            return
        }
        let template = Self.scriptTemplate(for: phase)
        scriptTextView.string = template
        lastSeededScriptTemplate = template
    }

    private func updateScriptByteCount() {
        let byteCount = scriptTextView.string.utf8.count
        let maximum = ScriptExecutionLimits.maximumSourceByteCount
        scriptByteCountField.stringValue = "\(byteCount.formatted()) / \(maximum.formatted()) bytes"
        scriptByteCountField.textColor = byteCount > maximum ? .systemRed : .secondaryLabelColor
        scriptByteCountField.setAccessibilityLabel(
            "JavaScript source size: \(byteCount) of \(maximum) bytes"
        )
    }

    private func applyScriptHighlighting() {
        guard !isApplyingScriptHighlight else {
            return
        }
        let selection = scriptTextView.selectedRanges
        isApplyingScriptHighlight = true
        scriptTextView.textStorage?.setAttributedString(
            InspectorSyntaxHighlighter.highlight(scriptTextView.string, as: .javaScript)
        )
        scriptTextView.selectedRanges = selection
        scriptTextView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        isApplyingScriptHighlight = false
    }

    @objc private func actionChanged() {
        updatePhaseChoices()
        updateActionControls()
        updateScriptControls()
    }

    @objc private func phaseChanged() {
        updateScriptControls()
    }

    @objc private func matcherChanged() {
        updateMatcherControls()
    }

    @objc private func submit() {
        guard phaseChoices.indices.contains(phasePopup.indexOfSelectedItem) else {
            return
        }
        do {
            let values = (
                name: nameField.stringValue,
                priority: priorityField.integerValue,
                action: selectedAction,
                phase: phaseChoices[phasePopup.indexOfSelectedItem],
                matcher: selectedMatcher,
                patternKind: selectedPattern,
                matcherValue: valueField.stringValue,
                actionValue: actionValueField.stringValue,
                scriptSource: scriptTextView.string,
                enabled: enabledButton.state == .on
            )
            let draft =
                initialDraft?.updating(
                    name: values.name,
                    priority: values.priority,
                    action: values.action,
                    phase: values.phase,
                    matcher: values.matcher,
                    patternKind: values.patternKind,
                    matcherValue: values.matcherValue,
                    actionValue: values.actionValue,
                    scriptSource: values.scriptSource,
                    enabled: values.enabled
                )
                ?? TrafficRuleDraft(
                    name: values.name,
                    priority: values.priority,
                    action: values.action,
                    phase: values.phase,
                    matcher: values.matcher,
                    patternKind: values.patternKind,
                    matcherValue: values.matcherValue,
                    actionValue: values.actionValue,
                    scriptSource: values.scriptSource,
                    enabled: values.enabled
                )
            let rule = try draft.makeRule()
            errorField.isHidden = true
            onSubmit?(rule)
        } catch {
            errorField.stringValue = error.localizedDescription
            errorField.isHidden = false
        }
    }

    @objc private func cancel() {
        onCancel?()
    }

    func textDidChange(_ notification: Notification) {
        guard
            !isApplyingScriptHighlight,
            let textView = notification.object as? NSTextView,
            textView === scriptTextView
        else {
            return
        }
        applyScriptHighlighting()
        updateScriptByteCount()
    }

    private static func scriptTemplate(for phase: RulePhase) -> String {
        switch phase {
        case .requestHeaders:
            """
            function onRequest(context) {
              // Edit context.request.headers, method, or url.
              // WebSocket handshakes support ws/wss URL and ordinary header edits.
              // The method and upgrade-critical headers are protected.
              context.request.headers.push({ name: "X-ProxyLens", value: "request" });
              context.log("Request headers updated");
              return context.request;
            }
            """
        case .requestBody:
            """
            function onRequest(context) {
              // Edit context.request.headers, body, method, or url.
              context.log("Request script applied");
              return context.request;
            }
            """
        case .responseHeaders:
            """
            function onResponse(context) {
              // Edit context.response.headers or statusCode.
              // WebSocket handshakes support ordinary response header edits.
              // The 101 status and upgrade-critical headers are protected.
              context.response.headers.push({ name: "X-ProxyLens", value: "response" });
              context.log("Response headers updated");
              return context.response;
            }
            """
        case .responseBody:
            """
            function onResponse(context) {
              // Edit context.response.headers, body, or statusCode.
              context.log("Response script applied");
              return context.response;
            }
            """
        case .connection, .webSocketFrame:
            ""
        }
    }

    private static func phaseTitle(_ phase: RulePhase) -> String {
        switch phase {
        case .connection:
            "Connection"
        case .requestHeaders:
            "Request Headers"
        case .requestBody:
            "Request Body"
        case .responseHeaders:
            "Response Headers"
        case .responseBody:
            "Response Body"
        case .webSocketFrame:
            "WebSocket Frame"
        }
    }
}
