import AppKit
import ProxyLensCore

enum TrafficRuleDraftError: Error, Equatable, LocalizedError {
    case missingName
    case missingMatcherValue
    case invalidRegularExpression
    case unsupportedPhase

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Enter a rule name."
        case .missingMatcherValue:
            "Enter a matcher value."
        case .invalidRegularExpression:
            "Enter a valid regular expression."
        case .unsupportedPhase:
            "The selected action cannot run in that phase."
        }
    }
}

enum TrafficRuleActionKind: String, CaseIterable {
    case block
    case allow
    case breakpoint
    case noCache

    var title: String {
        switch self {
        case .block:
            "Block"
        case .allow:
            "Allow"
        case .breakpoint:
            "Breakpoint"
        case .noCache:
            "No Cache"
        }
    }

    var allowedPhases: [RulePhase] {
        switch self {
        case .block:
            [.requestHeaders, .requestBody]
        case .allow:
            [.requestHeaders]
        case .breakpoint:
            [.requestHeaders, .requestBody, .responseHeaders]
        case .noCache:
            [.requestHeaders, .responseHeaders]
        }
    }

    var ruleAction: RuleAction {
        switch self {
        case .block:
            .block(reason: "Blocked by ProxyLens")
        case .allow:
            .allow
        case .breakpoint:
            .breakpoint
        case .noCache:
            .noCache
        }
    }

    init?(ruleAction: RuleAction) {
        switch ruleAction {
        case .block:
            self = .block
        case .allow:
            self = .allow
        case .breakpoint:
            self = .breakpoint
        case .noCache:
            self = .noCache
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
            action: resolvedAction
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
            enabled: enabled,
            originalAction: originalAction
        )
    }

    private var resolvedAction: RuleAction {
        guard let originalAction,
            TrafficRuleActionKind(ruleAction: originalAction) == action
        else {
            return action.ruleAction
        }
        return originalAction
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
final class TrafficRuleEditorViewController: NSViewController {
    var onSubmit: ((Rule) -> Void)?
    var onCancel: (() -> Void)?

    private let initialDraft: TrafficRuleDraft?

    private let nameField = NSTextField()
    private let actionPopup = NSPopUpButton()
    private let phasePopup = NSPopUpButton()
    private let matcherPopup = NSPopUpButton()
    private let patternPopup = NSPopUpButton()
    private let valueField = NSTextField()
    private let priorityField = NSTextField(string: "10")
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let errorField = NSTextField(wrappingLabelWithString: "")
    private var phaseChoices: [RulePhase] = []

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
                "Create a live rule with a bounded matcher. Mapping and body-file actions remain available from a captured flow."
        )
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        configureControls()
        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Action"), actionPopup],
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
            errorField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            errorField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            errorField.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            cancelButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            createButton.trailingAnchor.constraint(
                equalTo: cancelButton.leadingAnchor, constant: -8),
            createButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: 560, height: 430)
        view = container
        applyInitialDraft()
        updatePhaseChoices()
        if let initialDraft, let index = phaseChoices.firstIndex(of: initialDraft.phase) {
            phasePopup.selectItem(at: index)
        }
        updateMatcherControls()
    }

    private func configureControls() {
        nameField.placeholderString = "e.g. Pause staging API"
        nameField.setAccessibilityIdentifier("ruleEditor.name")

        actionPopup.addItems(withTitles: TrafficRuleActionKind.allCases.map(\.title))
        actionPopup.target = self
        actionPopup.action = #selector(actionChanged)
        actionPopup.setAccessibilityIdentifier("ruleEditor.action")

        phasePopup.setAccessibilityIdentifier("ruleEditor.phase")

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

    @objc private func actionChanged() {
        updatePhaseChoices()
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
