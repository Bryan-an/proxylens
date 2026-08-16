import AppKit
import ProxyLensCore

@MainActor
final class RequestEditorViewController: NSViewController, NSTextViewDelegate {
    private let draft: TrafficRequestEditDraft
    private let initialBodyText: String
    private var bodyLanguage: InspectorSyntaxHighlighter.Language
    private let headersTextView = NSTextView()
    private let bodyTextView = NSTextView()
    private let bodyMessageField = NSTextField(wrappingLabelWithString: "")
    private var bodyHighlightTask: Task<Void, Never>?

    init(draft: TrafficRequestEditDraft) {
        self.draft = draft
        let contentType = Self.contentType(in: draft.headersText)
        bodyLanguage = Self.bodyLanguage(
            contentType: contentType,
            bodyText: draft.bodyText
        )
        initialBodyText = Self.formattedBodyText(
            draft.bodyText,
            language: bodyLanguage
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var headersText: String {
        get { headersTextView.string }
        set {
            headersTextView.string = newValue
            applySyntaxHighlighting(to: headersTextView, as: .httpHeaders)
        }
    }

    var bodyText: String {
        get { bodyTextView.string }
        set {
            bodyTextView.string = newValue
            applySyntaxHighlighting(to: bodyTextView, as: bodyLanguage)
        }
    }

    var changedBodyText: String? {
        guard draft.canEditBody, bodyText != initialBodyText else {
            return nil
        }
        return bodyText
    }

    var initialFirstResponder: NSView {
        headersTextView
    }

    override func loadView() {
        configureTextView(headersTextView, identifier: "requestEditor.headers")
        configureTextView(bodyTextView, identifier: "requestEditor.body")
        headersTextView.delegate = self
        bodyTextView.delegate = self
        headersText = draft.headersText
        bodyText = initialBodyText
        bodyTextView.isEditable = draft.canEditBody
        if !draft.canEditBody {
            bodyTextView.backgroundColor = .controlBackgroundColor
        }

        let headersLabel = NSTextField(labelWithString: "Request line and headers")
        headersLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headersLabel.setAccessibilityIdentifier("requestEditor.headers.label")
        let bodyLabel = NSTextField(labelWithString: "Body")
        bodyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        bodyLabel.setAccessibilityIdentifier("requestEditor.body.label")

        bodyMessageField.stringValue = draft.bodyMessage ?? ""
        bodyMessageField.textColor = .secondaryLabelColor
        bodyMessageField.maximumNumberOfLines = 2
        bodyMessageField.isHidden = draft.bodyMessage == nil
        bodyMessageField.setAccessibilityIdentifier("requestEditor.body.message")

        let headersScrollView = makeScrollView(documentView: headersTextView)
        let bodyScrollView = makeScrollView(documentView: bodyTextView)
        for child in [headersLabel, headersScrollView, bodyLabel, bodyMessageField, bodyScrollView]
        {
            child.translatesAutoresizingMaskIntoConstraints = false
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        container.addSubview(headersLabel)
        container.addSubview(headersScrollView)
        container.addSubview(bodyLabel)
        container.addSubview(bodyMessageField)
        container.addSubview(bodyScrollView)
        NSLayoutConstraint.activate([
            headersLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headersLabel.topAnchor.constraint(equalTo: container.topAnchor),
            headersScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headersScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headersScrollView.topAnchor.constraint(equalTo: headersLabel.bottomAnchor, constant: 6),
            headersScrollView.heightAnchor.constraint(equalToConstant: 210),
            bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: headersScrollView.bottomAnchor, constant: 12),
            bodyMessageField.leadingAnchor.constraint(
                greaterThanOrEqualTo: bodyLabel.trailingAnchor,
                constant: 12
            ),
            bodyMessageField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyMessageField.centerYAnchor.constraint(equalTo: bodyLabel.centerYAnchor),
            bodyScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyScrollView.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 6),
            bodyScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else {
            return
        }
        guard textView === bodyTextView else {
            applySyntaxHighlighting(to: textView, as: .httpHeaders)
            refreshBodyHighlighting()
            return
        }
        refreshBodyHighlighting()
    }

    private func refreshBodyHighlighting() {
        bodyHighlightTask?.cancel()
        bodyHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else {
                return
            }
            self.bodyLanguage = Self.bodyLanguage(
                contentType: Self.contentType(in: self.headersText),
                bodyText: self.bodyText
            )
            self.applySyntaxHighlighting(to: self.bodyTextView, as: self.bodyLanguage)
        }
    }

    private func configureTextView(_ textView: NSTextView, identifier: String) {
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.setAccessibilityIdentifier(identifier)
        textView.setAccessibilityLabel(
            identifier == "requestEditor.headers" ? "Request line and headers" : "Request body"
        )
    }

    private func makeScrollView(documentView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    private func applySyntaxHighlighting(
        to textView: NSTextView,
        as language: InspectorSyntaxHighlighter.Language
    ) {
        guard let textStorage = textView.textStorage else {
            return
        }
        let text = textView.string
        let range = NSRange(location: 0, length: (text as NSString).length)
        let highlighted = InspectorSyntaxHighlighter.highlight(text, as: language)
        let selection = textView.selectedRanges

        textStorage.beginEditing()
        highlighted.enumerateAttributes(in: range) { attributes, attributeRange, _ in
            textStorage.setAttributes(attributes, range: attributeRange)
        }
        textStorage.endEditing()
        textView.selectedRanges = selection
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
    }

    private static func bodyLanguage(
        contentType: String?,
        bodyText: String
    ) -> InspectorSyntaxHighlighter.Language {
        if isJSON(contentType: contentType) {
            return .json
        }
        let sniffedBody = JSONBodyView.render(
            data: Data(bodyText.utf8),
            contentType: nil,
            contentEncoding: nil,
            isTruncated: false
        )
        if case .prettyPrinted = sniffedBody {
            return .json
        }
        return InspectorSyntaxHighlighter.language(forContentType: contentType)
    }

    private static func formattedBodyText(
        _ bodyText: String,
        language: InspectorSyntaxHighlighter.Language
    ) -> String {
        guard language == .json else {
            return bodyText
        }
        switch JSONBodyView.render(
            data: Data(bodyText.utf8),
            contentType: "application/json",
            contentEncoding: nil,
            isTruncated: false
        ) {
        case .prettyPrinted(let formatted):
            return formatted
        case .unavailable:
            return bodyText
        }
    }

    private static func contentType(in headersText: String) -> String? {
        for line in headersText.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
                fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Content-Type") == .orderedSame
            else {
                continue
            }
            return fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func isJSON(contentType: String?) -> Bool {
        guard
            let mediaType = contentType?
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            return false
        }
        return mediaType == "application/json" || mediaType == "text/json"
            || mediaType.hasSuffix("+json")
    }
}
