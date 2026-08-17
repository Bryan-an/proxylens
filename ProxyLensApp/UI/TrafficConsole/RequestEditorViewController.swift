import AppKit
import ProxyLensApplication
import ProxyLensCore

@MainActor
final class RequestEditorViewController: NSViewController, NSTextViewDelegate {
    private let draft: TrafficRequestEditDraft
    private let allowsCURLImport: Bool
    private let composerStore: (any TrafficRequestComposerStoring)?
    private let initialBodyText: String
    private var bodyLanguage: InspectorSyntaxHighlighter.Language
    private let headersTextView = NSTextView()
    private let bodyTextView = NSTextView()
    private let bodyMessageField = NSTextField(wrappingLabelWithString: "")
    private let importCURLButton = NSButton()
    private let historyButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let presetsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let savePresetButton = NSButton()
    private var bodyHighlightTask: Task<Void, Never>?

    init(
        draft: TrafficRequestEditDraft,
        allowsCURLImport: Bool = false,
        composerStore: (any TrafficRequestComposerStoring)? = nil
    ) {
        self.draft = draft
        self.allowsCURLImport = allowsCURLImport
        self.composerStore = composerStore
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
        importCURLButton.title = "Import cURL from Clipboard"
        importCURLButton.bezelStyle = .rounded
        importCURLButton.target = self
        importCURLButton.action = #selector(importCURLFromPasteboard(_:))
        importCURLButton.isHidden = !allowsCURLImport
        importCURLButton.setAccessibilityIdentifier("requestEditor.importCURL")
        importCURLButton.setAccessibilityLabel("Import cURL from Clipboard")
        let bodyLabel = NSTextField(labelWithString: "Body")
        bodyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        bodyLabel.setAccessibilityIdentifier("requestEditor.body.label")

        bodyMessageField.stringValue = draft.bodyMessage ?? ""
        bodyMessageField.textColor = .secondaryLabelColor
        bodyMessageField.maximumNumberOfLines = 2
        bodyMessageField.isHidden = draft.bodyMessage == nil
        bodyMessageField.setAccessibilityIdentifier("requestEditor.body.message")

        configureComposerControls()

        let headersScrollView = makeScrollView(documentView: headersTextView)
        let bodyScrollView = makeScrollView(documentView: bodyTextView)
        for child in [
            headersLabel,
            importCURLButton,
            headersScrollView,
            bodyLabel,
            bodyMessageField,
            bodyScrollView
        ] {
            child.translatesAutoresizingMaskIntoConstraints = false
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        let composerControls: NSStackView?
        if composerStore != nil {
            let controls = NSStackView(views: [historyButton, presetsButton, savePresetButton])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 8
            controls.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(controls)
            composerControls = controls
        } else {
            composerControls = nil
        }
        container.addSubview(headersLabel)
        container.addSubview(importCURLButton)
        container.addSubview(headersScrollView)
        container.addSubview(bodyLabel)
        container.addSubview(bodyMessageField)
        container.addSubview(bodyScrollView)
        NSLayoutConstraint.activate([
            headersLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            importCURLButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            importCURLButton.centerYAnchor.constraint(equalTo: headersLabel.centerYAnchor),
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
        if let composerControls {
            NSLayoutConstraint.activate([
                composerControls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                composerControls.topAnchor.constraint(equalTo: container.topAnchor),
                composerControls.heightAnchor.constraint(equalToConstant: 28),
                headersLabel.topAnchor.constraint(
                    equalTo: composerControls.bottomAnchor,
                    constant: 8
                )
            ])
        } else {
            headersLabel.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        }
        view = container
    }

    func importCURLCommand(_ command: String) throws {
        let request = try CURLRequestImporter.parse(command)
        let importedBody: String
        if let data = request.body?.inlineData {
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProxyLensError.unsupportedOperation(
                    "Binary cURL bodies cannot be edited as text"
                )
            }
            importedBody = text
        } else {
            importedBody = ""
        }

        headersText = HTTPMessageText.requestHeaders(request)
        bodyLanguage = Self.bodyLanguage(
            contentType: Self.contentType(in: headersText),
            bodyText: importedBody
        )
        bodyText = Self.formattedBodyText(importedBody, language: bodyLanguage)
        bodyMessageField.stringValue = ""
        bodyMessageField.textColor = .secondaryLabelColor
        bodyMessageField.isHidden = true
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

    @objc private func importCURLFromPasteboard(_ sender: NSButton) {
        guard
            let command = NSPasteboard.general.string(forType: .string),
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showImportMessage("Copy a cURL command to the clipboard, then try again.")
            return
        }

        do {
            try importCURLCommand(command)
        } catch {
            showImportMessage(error.localizedDescription)
        }
    }

    private func showImportMessage(_ message: String) {
        bodyMessageField.stringValue = message
        bodyMessageField.textColor = .systemRed
        bodyMessageField.isHidden = false
    }

    private func configureComposerControls() {
        guard composerStore != nil else {
            return
        }

        for popup in [historyButton, presetsButton] {
            popup.autoenablesItems = false
            popup.bezelStyle = .rounded
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        historyButton.setAccessibilityIdentifier("requestEditor.history")
        historyButton.setAccessibilityLabel("Request composer history")
        presetsButton.setAccessibilityIdentifier("requestEditor.presets")
        presetsButton.setAccessibilityLabel("Request composer presets")

        savePresetButton.title = "Save Preset…"
        savePresetButton.bezelStyle = .rounded
        savePresetButton.target = self
        savePresetButton.action = #selector(savePreset(_:))
        savePresetButton.setAccessibilityIdentifier("requestEditor.savePreset")
        savePresetButton.setAccessibilityLabel("Save current request as a preset")
        reloadComposerMenus()
    }

    private func reloadComposerMenus() {
        guard let composerStore else {
            return
        }
        populateComposerMenu(
            historyButton,
            title: "History",
            emptyTitle: "No recent requests",
            entries: composerStore.history,
            action: #selector(selectHistory(_:))
        )
        populateComposerMenu(
            presetsButton,
            title: "Presets",
            emptyTitle: "No saved presets",
            entries: composerStore.presets,
            action: #selector(selectPreset(_:))
        )
    }

    private func populateComposerMenu(
        _ popup: NSPopUpButton,
        title: String,
        emptyTitle: String,
        entries: [TrafficRequestComposerEntry],
        action: Selector
    ) {
        popup.removeAllItems()
        popup.addItem(withTitle: title)
        popup.item(at: 0)?.isEnabled = false
        if entries.isEmpty {
            popup.addItem(withTitle: emptyTitle)
            popup.item(at: 1)?.isEnabled = false
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            popup.menu?.addItem(item)
        }
    }

    @objc private func selectHistory(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? TrafficRequestComposerEntry else {
            return
        }
        loadComposerEntry(entry)
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? TrafficRequestComposerEntry else {
            return
        }
        loadComposerEntry(entry)
    }

    private func loadComposerEntry(_ entry: TrafficRequestComposerEntry) {
        headersText = entry.headersText
        bodyLanguage = Self.bodyLanguage(
            contentType: Self.contentType(in: entry.headersText),
            bodyText: entry.bodyText
        )
        bodyText = Self.formattedBodyText(entry.bodyText, language: bodyLanguage)
        bodyMessageField.stringValue = ""
        bodyMessageField.textColor = .secondaryLabelColor
        bodyMessageField.isHidden = true
    }

    @objc private func savePreset(_: NSButton) {
        Task { @MainActor [weak self] in
            await self?.presentSavePreset()
        }
    }

    private func presentSavePreset() async {
        guard let composerStore else {
            return
        }
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Preset name"
        nameField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let alert = NSAlert()
        alert.messageText = "Save Request Preset"
        alert.informativeText = "Give this request a reusable local name."
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Save")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else {
            return
        }

        do {
            _ = try composerStore.savePreset(
                name: nameField.stringValue,
                headersText: headersText,
                bodyText: bodyText
            )
            reloadComposerMenus()
        } catch {
            showImportMessage(error.localizedDescription)
        }
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
