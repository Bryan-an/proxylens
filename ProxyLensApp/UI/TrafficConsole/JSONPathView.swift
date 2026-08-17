import AppKit
import ProxyLensCore

/// A small, local JSONPath query surface for the derived JSON inspector view.
@MainActor
final class JSONPathView: NSView, NSTextFieldDelegate {
    private let queryField = NSTextField()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "")
    private let resultTextView = NSTextView()
    private var jsonText: String?

    init(accessibilityPrefix: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureQueryField(accessibilityPrefix: accessibilityPrefix)
        configureRunButton(accessibilityPrefix: accessibilityPrefix)
        configureStatusField()
        configureResultView(accessibilityPrefix: accessibilityPrefix)

        let queryStack = NSStackView(views: [queryField, runButton, statusField])
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
            queryField.stringValue = "$"
        }

        guard let nextJSON else {
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

        queryField.isEnabled = true
        runButton.isEnabled = true
        executeQuery(nextJSON)
    }

    private func configureQueryField(accessibilityPrefix: String) {
        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.placeholderString = "$.users[*].id"
        queryField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        queryField.stringValue = "$"
        queryField.target = self
        queryField.action = #selector(runQuery)
        queryField.delegate = self
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        queryField.setAccessibilityIdentifier("\(accessibilityPrefix).jsonpath.query")
        queryField.toolTip = "Supported: $.key, [0], ['key'], and wildcards"
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        guard selector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        runQuery()
        return true
    }

    private func executeQuery(_ json: String) {
        switch JSONPathBodyView.evaluate(json: json, query: queryField.stringValue) {
        case .unavailable(let reason):
            statusField.stringValue = "Not available"
            resultTextView.string = reason
            resultTextView.textColor = .secondaryLabelColor
        case .matches(let matches):
            statusField.stringValue =
                matches.isEmpty
                ? "No matches" : "\(matches.count) match\(matches.count == 1 ? "" : "es")"
            resultTextView.textColor = .textColor
            resultTextView.textStorage?.setAttributedString(render(matches))
        }
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
}
