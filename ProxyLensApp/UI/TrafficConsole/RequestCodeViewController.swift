import AppKit
import ProxyLensApplication

@MainActor
final class RequestCodeViewController: NSViewController {
    private let snippets: [RequestCodeLanguage: String]
    private let languagePopup = NSPopUpButton()
    private let sourceTextView = NSTextView()

    init(snippets: [RequestCodeSnippet]) {
        self.snippets = Dictionary(
            uniqueKeysWithValues: snippets.map { ($0.language, $0.source) }
        )
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 880, height: 620)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("requestCode")

        let title = NSTextField(labelWithString: "Generate Request Code")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Choose a client or language, then copy the generated request to your editor or terminal."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor

        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityIdentifier("requestCode.language")
        for language in RequestCodeLanguage.allCases where snippets[language] != nil {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }

        configureSourceTextView()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = sourceTextView

        let copyButton = NSButton(
            title: "Copy to Clipboard",
            target: self,
            action: #selector(copySource)
        )
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.setAccessibilityIdentifier("requestCode.copy")

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("requestCode.close")

        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(languagePopup)
        container.addSubview(scrollView)
        container.addSubview(copyButton)
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            languagePopup.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            languagePopup.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: languagePopup.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -16),
            closeButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            copyButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
        ])

        view = container
        renderSelectedLanguage()
    }

    private func configureSourceTextView() {
        sourceTextView.isEditable = false
        sourceTextView.isSelectable = true
        sourceTextView.isRichText = true
        sourceTextView.drawsBackground = true
        sourceTextView.backgroundColor = .textBackgroundColor
        sourceTextView.textContainerInset = NSSize(width: 12, height: 12)
        sourceTextView.isHorizontallyResizable = true
        sourceTextView.isVerticallyResizable = true
        sourceTextView.autoresizingMask = [.width]
        sourceTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        sourceTextView.textContainer?.widthTracksTextView = false
        sourceTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        sourceTextView.setAccessibilityIdentifier("requestCode.source")
    }

    @objc private func languageChanged() {
        renderSelectedLanguage()
    }

    private func renderSelectedLanguage() {
        guard let language = selectedLanguage,
            let source = snippets[language]
        else {
            sourceTextView.string = ""
            return
        }
        sourceTextView.textStorage?.setAttributedString(
            RequestCodeSyntaxHighlighter.highlight(source)
        )
        sourceTextView.scrollToBeginningOfDocument(nil)
    }

    @objc private func copySource() {
        guard let language = selectedLanguage,
            let source = snippets[language]
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }

    private var selectedLanguage: RequestCodeLanguage? {
        guard let rawValue = languagePopup.selectedItem?.representedObject as? String else {
            return nil
        }
        return RequestCodeLanguage(rawValue: rawValue)
    }

    @objc private func close() {
        dismiss(nil)
    }
}

private enum RequestCodeSyntaxHighlighter {
    static func highlight(_ source: String) -> NSAttributedString {
        let fullRange = NSRange(source.startIndex..., in: source)
        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
        )

        apply(
            pattern: #"\b(import|const|let|var|await|try|print|return|new)\b"#,
            color: InspectorSyntaxPalette.key,
            to: result,
            range: fullRange
        )
        apply(
            pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"#,
            color: InspectorSyntaxPalette.string,
            to: result,
            range: fullRange
        )
        apply(
            pattern: #"\b(true|false|null|nil)\b"#,
            color: InspectorSyntaxPalette.literal,
            to: result,
            range: fullRange
        )
        apply(
            pattern: #"(?m)^(//|#).*"#,
            color: NSColor.secondaryLabelColor,
            to: result,
            range: fullRange
        )
        return result
    }

    private static func apply(
        pattern: String,
        color: NSColor,
        to result: NSMutableAttributedString,
        range: NSRange
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return
        }
        for match in expression.matches(in: result.string, range: range) {
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
