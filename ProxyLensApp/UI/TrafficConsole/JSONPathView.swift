import AppKit
import ProxyLensCore

/// A small, local JSONPath and jq query surface for the derived JSON inspector view.
@MainActor
final class JSONPathView: NSView, NSTextFieldDelegate {
    private enum QueryMode: String, CaseIterable {
        case jsonPath = "JSONPath"
        case jq

        var defaultQuery: String {
            switch self {
            case .jsonPath:
                "$"
            case .jq:
                "."
            }
        }

        var placeholder: String {
            switch self {
            case .jsonPath:
                "$.users[*].id"
            case .jq:
                ".users[] | select(.active == true) | .id"
            }
        }

        var toolTip: String {
            switch self {
            case .jsonPath:
                "Supported: $.key, [0], ['key'], and wildcards"
            case .jq:
                "Supported: paths, iteration, pipes, and select comparisons"
            }
        }
    }

    private let modePopup = NSPopUpButton()
    private let queryField = NSTextField()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "")
    private let resultTextView = NSTextView()
    private var jsonText: String?
    private var currentMode = QueryMode.jsonPath
    private var queryDrafts: [QueryMode: String] = [
        .jsonPath: QueryMode.jsonPath.defaultQuery,
        .jq: QueryMode.jq.defaultQuery
    ]

    init(accessibilityPrefix: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureModePopup(accessibilityPrefix: accessibilityPrefix)
        configureQueryField(accessibilityPrefix: accessibilityPrefix)
        configureRunButton(accessibilityPrefix: accessibilityPrefix)
        configureStatusField()
        configureResultView(accessibilityPrefix: accessibilityPrefix)

        let queryStack = NSStackView(views: [modePopup, queryField, runButton, statusField])
        queryStack.translatesAutoresizingMaskIntoConstraints = false
        queryStack.orientation = .horizontal
        queryStack.spacing = 8
        queryStack.alignment = .centerY
        queryStack.distribution = .fill

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = resultTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        addSubview(queryStack)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            queryStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            queryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            queryStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            modePopup.widthAnchor.constraint(equalToConstant: 86),
            runButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: queryStack.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ presentation: TrafficBodyPresentation) {
        let nextJSON: String?
        switch presentation {
        case .content(_, let value):
            nextJSON = value
        case .none, .loading, .failed:
            nextJSON = nil
        }

        if nextJSON != jsonText {
            jsonText = nextJSON
            queryDrafts = [
                .jsonPath: QueryMode.jsonPath.defaultQuery,
                .jq: QueryMode.jq.defaultQuery
            ]
            queryField.stringValue = draft(for: currentMode)
        }

        guard let nextJSON else {
            modePopup.isEnabled = false
            queryField.isEnabled = false
            runButton.isEnabled = false
            switch presentation {
            case .none(let message), .loading(let message), .failed(_, let message):
                statusField.stringValue = message
                resultTextView.string = message
            case .content:
                break
            }
            return
        }

        modePopup.isEnabled = true
        queryField.isEnabled = true
        runButton.isEnabled = true
        executeQuery(nextJSON)
    }

    private func configureModePopup(accessibilityPrefix: String) {
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        modePopup.addItems(withTitles: QueryMode.allCases.map(\.rawValue))
        modePopup.selectItem(withTitle: currentMode.rawValue)
        modePopup.controlSize = .small
        modePopup.target = self
        modePopup.action = #selector(queryModeChanged)
        modePopup.setAccessibilityIdentifier("\(accessibilityPrefix).jsonquery.mode")
        modePopup.setAccessibilityLabel("JSON query language")
        modePopup.toolTip = "Choose JSONPath or the safe local jq subset"
        modePopup.setContentHuggingPriority(.required, for: .horizontal)
        modePopup.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureQueryField(accessibilityPrefix: String) {
        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.placeholderString = currentMode.placeholder
        queryField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        queryField.stringValue = currentMode.defaultQuery
        queryField.target = self
        queryField.action = #selector(runQuery)
        queryField.delegate = self
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        queryField.setAccessibilityIdentifier("\(accessibilityPrefix).jsonpath.query")
        queryField.toolTip = currentMode.toolTip
    }

    private func configureRunButton(accessibilityPrefix: String) {
        runButton.translatesAutoresizingMaskIntoConstraints = false
        runButton.bezelStyle = .rounded
        runButton.controlSize = .small
        runButton.target = self
        runButton.action = #selector(runQuery)
        runButton.setAccessibilityIdentifier("\(accessibilityPrefix).jsonpath.run")
    }

    private func configureStatusField() {
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.maximumNumberOfLines = 1
        statusField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureResultView(accessibilityPrefix: String) {
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.isRichText = false
        resultTextView.usesFindBar = true
        resultTextView.isIncrementalSearchingEnabled = true
        resultTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultTextView.textContainerInset = NSSize(width: 10, height: 10)
        resultTextView.backgroundColor = .textBackgroundColor
        resultTextView.setAccessibilityIdentifier("\(accessibilityPrefix).jsonpath.result")
        resultTextView.isHorizontallyResizable = true
        resultTextView.isVerticallyResizable = true
        resultTextView.autoresizingMask = [.width]
        resultTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        resultTextView.textContainer?.widthTracksTextView = false
    }

    @objc private func runQuery() {
        guard let jsonText else {
            return
        }
        executeQuery(jsonText)
    }

    @objc private func queryModeChanged() {
        queryDrafts[currentMode] = queryField.stringValue
        guard let title = modePopup.selectedItem?.title,
            let selectedMode = QueryMode(rawValue: title)
        else {
            modePopup.selectItem(withTitle: currentMode.rawValue)
            return
        }
        currentMode = selectedMode
        queryField.stringValue = draft(for: selectedMode)
        queryField.placeholderString = selectedMode.placeholder
        queryField.toolTip = selectedMode.toolTip
        runQuery()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        guard selector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        runQuery()
        return true
    }

    private func executeQuery(_ json: String) {
        queryDrafts[currentMode] = queryField.stringValue
        switch currentMode {
        case .jsonPath:
            executeJSONPath(json)
        case .jq:
            executeJQ(json)
        }
    }

    private func executeJSONPath(_ json: String) {
        switch JSONPathBodyView.evaluate(json: json, query: queryField.stringValue) {
        case .unavailable(let reason):
            showUnavailable(reason)
        case .matches(let matches):
            statusField.stringValue =
                matches.isEmpty
                ? "No matches" : "\(matches.count) match\(matches.count == 1 ? "" : "es")"
            resultTextView.textColor = .textColor
            resultTextView.textStorage?.setAttributedString(render(matches))
        }
    }

    private func executeJQ(_ json: String) {
        switch JQBodyView.evaluate(json: json, query: queryField.stringValue) {
        case .unavailable(let reason):
            showUnavailable(reason)
        case .values(let values):
            statusField.stringValue =
                values.isEmpty
                ? "No values" : "\(values.count) value\(values.count == 1 ? "" : "s")"
            resultTextView.textColor = .textColor
            resultTextView.textStorage?.setAttributedString(renderJQ(values))
        }
    }

    private func showUnavailable(_ reason: String) {
        statusField.stringValue = "Not available"
        resultTextView.string = reason
        resultTextView.textColor = .secondaryLabelColor
    }

    private func draft(for mode: QueryMode) -> String {
        queryDrafts[mode] ?? mode.defaultQuery
    }

    private func render(_ matches: [JSONPathBodyView.Match]) -> NSAttributedString {
        guard !matches.isEmpty else {
            return NSAttributedString(
                string: "No values matched this JSONPath.",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }

        let result = NSMutableAttributedString()
        for (index, match) in matches.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            let path = NSAttributedString(
                string: match.path + "\n",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: InspectorSyntaxPalette.key
                ]
            )
            result.append(path)
            result.append(
                InspectorSyntaxHighlighter.highlight(
                    match.value,
                    as: .json
                )
            )
        }
        return result
    }

    private func renderJQ(_ values: [String]) -> NSAttributedString {
        guard !values.isEmpty else {
            return NSAttributedString(
                string: "No values matched this jq expression.",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }

        let result = NSMutableAttributedString()
        for (index, value) in values.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(InspectorSyntaxHighlighter.highlight(value, as: .json))
        }
        return result
    }
}
