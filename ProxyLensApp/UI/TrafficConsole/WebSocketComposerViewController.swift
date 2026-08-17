import AppKit
import Foundation
import ProxyLensApplication
import ProxyLensCore

@MainActor
final class WebSocketComposerViewController: NSViewController, NSTextViewDelegate {
    typealias SendHandler = (
        WebSocketFrameDirection,
        WebSocketComposePayloadEncoding,
        String
    ) async throws -> Void

    private let flowTitle: String
    private let sendHandler: SendHandler
    private let directionSelector = NSSegmentedControl(
        labels: ["To Server", "To Client"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let encodingSelector = NSSegmentedControl(
        labels: ["Text", "Binary (Base64)"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let payloadTextView = NSTextView()
    private let payloadScrollView = NSScrollView()
    private let payloadHelpField = NSTextField(wrappingLabelWithString: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let formatJSONButton = NSButton(title: "Format JSON", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send Frame", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var isApplyingHighlight = false
    private var sendTask: Task<Void, Never>?

    init(flowTitle: String, sendHandler: @escaping SendHandler) {
        self.flowTitle = flowTitle
        self.sendHandler = sendHandler
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 680, height: 470)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        sendTask?.cancel()
    }

    override func loadView() {
        configureSelectors()
        configureEditor()
        configureActions()

        let titleField = NSTextField(labelWithString: "Compose WebSocket Frame")
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.setAccessibilityIdentifier("webSocketComposer.title")

        let explanationField = NSTextField(
            wrappingLabelWithString:
                "Send a new frame on the selected live connection. To Server behaves like the client; To Client behaves like the server."
        )
        explanationField.textColor = .secondaryLabelColor

        let connectionField = NSTextField(labelWithString: flowTitle)
        connectionField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        connectionField.lineBreakMode = .byTruncatingMiddle
        connectionField.toolTip = flowTitle
        connectionField.setAccessibilityIdentifier("webSocketComposer.connection")
        connectionField.setAccessibilityLabel("Selected WebSocket connection")

        let directionLabel = Self.fieldLabel("Direction")
        let encodingLabel = Self.fieldLabel("Payload type")
        let payloadLabel = Self.fieldLabel("Payload")

        let directionRow = NSStackView(views: [directionLabel, directionSelector])
        directionRow.orientation = .horizontal
        directionRow.alignment = .centerY
        directionRow.spacing = 10

        let encodingRow = NSStackView(views: [encodingLabel, encodingSelector, formatJSONButton])
        encodingRow.orientation = .horizontal
        encodingRow.alignment = .centerY
        encodingRow.spacing = 10

        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = NSStackView(views: [statusField, flexibleSpace, cancelButton, sendButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        for child in [
            titleField,
            explanationField,
            connectionField,
            directionRow,
            encodingRow,
            payloadLabel,
            payloadHelpField,
            payloadScrollView,
            actionRow
        ] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            titleField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            explanationField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            explanationField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            explanationField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
            connectionField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            connectionField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            connectionField.topAnchor.constraint(
                equalTo: explanationField.bottomAnchor, constant: 8),
            directionRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            directionRow.topAnchor.constraint(equalTo: connectionField.bottomAnchor, constant: 14),
            encodingRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            encodingRow.trailingAnchor.constraint(lessThanOrEqualTo: titleField.trailingAnchor),
            encodingRow.topAnchor.constraint(equalTo: directionRow.bottomAnchor, constant: 10),
            directionLabel.widthAnchor.constraint(equalToConstant: 82),
            encodingLabel.widthAnchor.constraint(equalTo: directionLabel.widthAnchor),
            payloadLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            payloadLabel.topAnchor.constraint(equalTo: encodingRow.bottomAnchor, constant: 14),
            payloadHelpField.leadingAnchor.constraint(
                greaterThanOrEqualTo: payloadLabel.trailingAnchor,
                constant: 10
            ),
            payloadHelpField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            payloadHelpField.centerYAnchor.constraint(equalTo: payloadLabel.centerYAnchor),
            payloadScrollView.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            payloadScrollView.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            payloadScrollView.topAnchor.constraint(equalTo: payloadLabel.bottomAnchor, constant: 6),
            payloadScrollView.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -12),
            actionRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            actionRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        view = container
        updateEncodingPresentation()
        applySyntaxHighlighting()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(payloadTextView)
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingHighlight, notification.object as? NSTextView === payloadTextView else {
            return
        }
        clearStatus()
        applySyntaxHighlighting()
    }

    private func configureSelectors() {
        directionSelector.selectedSegment = 0
        directionSelector.segmentStyle = .separated
        directionSelector.setAccessibilityIdentifier("webSocketComposer.direction")
        directionSelector.setAccessibilityLabel("WebSocket frame direction")
        directionSelector.setAccessibilityHelp(
            "Choose whether the frame is sent to the upstream server or downstream client"
        )

        encodingSelector.selectedSegment = 0
        encodingSelector.segmentStyle = .separated
        encodingSelector.target = self
        encodingSelector.action = #selector(encodingChanged(_:))
        encodingSelector.setAccessibilityIdentifier("webSocketComposer.encoding")
        encodingSelector.setAccessibilityLabel("WebSocket payload type")
    }

    private func configureEditor() {
        payloadTextView.delegate = self
        payloadTextView.isEditable = true
        payloadTextView.isSelectable = true
        payloadTextView.isRichText = false
        payloadTextView.allowsUndo = true
        payloadTextView.usesFindBar = true
        payloadTextView.isIncrementalSearchingEnabled = true
        payloadTextView.isAutomaticQuoteSubstitutionEnabled = false
        payloadTextView.isAutomaticDashSubstitutionEnabled = false
        payloadTextView.isAutomaticTextReplacementEnabled = false
        payloadTextView.textContainerInset = NSSize(width: 10, height: 10)
        payloadTextView.backgroundColor = .textBackgroundColor
        payloadTextView.isHorizontallyResizable = false
        payloadTextView.isVerticallyResizable = true
        payloadTextView.autoresizingMask = [.width]
        payloadTextView.textContainer?.widthTracksTextView = true
        payloadTextView.setAccessibilityIdentifier("webSocketComposer.payload")
        payloadTextView.setAccessibilityLabel("WebSocket frame payload")

        payloadScrollView.documentView = payloadTextView
        payloadScrollView.hasVerticalScroller = true
        payloadScrollView.autohidesScrollers = true
        payloadScrollView.borderType = .bezelBorder

        payloadHelpField.font = .systemFont(ofSize: 10, weight: .regular)
        payloadHelpField.textColor = .secondaryLabelColor
        payloadHelpField.alignment = .right
        payloadHelpField.setAccessibilityIdentifier("webSocketComposer.payloadHelp")

        statusField.font = .systemFont(ofSize: 11, weight: .regular)
        statusField.textColor = .systemRed
        statusField.maximumNumberOfLines = 2
        statusField.setAccessibilityIdentifier("webSocketComposer.status")
        statusField.setAccessibilityLabel("WebSocket composer status")
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureActions() {
        formatJSONButton.bezelStyle = .rounded
        formatJSONButton.target = self
        formatJSONButton.action = #selector(formatJSON(_:))
        formatJSONButton.setAccessibilityIdentifier("webSocketComposer.formatJSON")
        formatJSONButton.setAccessibilityLabel("Format JSON payload")

        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendFrame(_:))
        sendButton.setAccessibilityIdentifier("webSocketComposer.send")
        sendButton.setAccessibilityLabel("Send WebSocket frame")

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.setAccessibilityIdentifier("webSocketComposer.cancel")
    }

    @objc private func encodingChanged(_ sender: NSSegmentedControl) {
        clearStatus()
        updateEncodingPresentation()
        applySyntaxHighlighting()
    }

    @objc private func formatJSON(_ sender: NSButton) {
        let data = Data(payloadTextView.string.utf8)
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let formatted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]
            )
            guard let value = String(data: formatted, encoding: .utf8) else {
                return
            }
            payloadTextView.string = value
            clearStatus()
            applySyntaxHighlighting()
        } catch {
            showStatus("The text payload is not valid JSON.")
        }
    }

    @objc private func sendFrame(_ sender: NSButton) {
        guard sendTask == nil else {
            return
        }
        let direction: WebSocketFrameDirection =
            directionSelector.selectedSegment == 1 ? .serverToClient : .clientToServer
        let encoding: WebSocketComposePayloadEncoding =
            encodingSelector.selectedSegment == 1 ? .base64 : .text
        let payload = payloadTextView.string

        setSending(true)
        sendTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                sendTask = nil
                setSending(false)
            }
            do {
                try await sendHandler(direction, encoding, payload)
                dismiss(self)
            } catch {
                showStatus(error.localizedDescription)
            }
        }
    }

    @objc private func cancel(_ sender: NSButton) {
        sendTask?.cancel()
        dismiss(self)
    }

    private func updateEncodingPresentation() {
        let isBinary = encodingSelector.selectedSegment == 1
        formatJSONButton.isEnabled = !isBinary
        payloadHelpField.stringValue =
            isBinary
            ? "Enter Base64-encoded bytes. Maximum decoded size: 1 MB."
            : "Text is sent as UTF-8. Valid JSON can be formatted and highlighted."
        payloadTextView.setAccessibilityHelp(payloadHelpField.stringValue)
    }

    private func applySyntaxHighlighting() {
        let text = payloadTextView.string
        let language: InspectorSyntaxHighlighter.Language =
            encodingSelector.selectedSegment == 0 && Self.isJSON(text) ? .json : .plainText
        let selection = payloadTextView.selectedRanges
        isApplyingHighlight = true
        payloadTextView.textStorage?.setAttributedString(
            InspectorSyntaxHighlighter.highlight(text, as: language)
        )
        payloadTextView.selectedRanges = selection
        payloadTextView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        isApplyingHighlight = false
    }

    private func setSending(_ isSending: Bool) {
        directionSelector.isEnabled = !isSending
        encodingSelector.isEnabled = !isSending
        payloadTextView.isEditable = !isSending
        formatJSONButton.isEnabled = !isSending && encodingSelector.selectedSegment == 0
        cancelButton.isEnabled = !isSending
        sendButton.isEnabled = !isSending
        sendButton.title = isSending ? "Sending…" : "Send Frame"
        if isSending {
            statusField.textColor = .secondaryLabelColor
            statusField.stringValue = "Sending frame…"
        }
    }

    private func clearStatus() {
        statusField.stringValue = ""
        statusField.textColor = .systemRed
    }

    private func showStatus(_ message: String) {
        statusField.textColor = .systemRed
        statusField.stringValue = message
        NSAccessibility.post(element: statusField, notification: .valueChanged)
    }

    private static func fieldLabel(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.alignment = .right
        return field
    }

    private static func isJSON(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return
            (try? JSONSerialization.jsonObject(
                with: Data(trimmed.utf8),
                options: [.fragmentsAllowed]
            )) != nil
    }
}

@MainActor
final class WebSocketReconnectViewController: NSViewController, NSTextViewDelegate {
    typealias ConnectHandler = (
        String,
        String,
        WebSocketComposePayloadEncoding,
        String,
        Bool
    ) async throws -> Void

    private let draft: TrafficWebSocketReconnectDraft
    private let connectHandler: ConnectHandler
    private let urlField = NSTextField()
    private let headersTextView = NSTextView()
    private let headersScrollView = NSScrollView()
    private let encodingSelector = NSSegmentedControl(
        labels: ["Text", "Binary (Base64)"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let formatJSONButton = NSButton(title: "Format JSON", target: nil, action: nil)
    private let payloadTextView = NSTextView()
    private let payloadScrollView = NSScrollView()
    private let payloadMessageField = NSTextField(wrappingLabelWithString: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let replayButton = NSButton(title: "Connect & Replay", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var isApplyingHighlight = false
    private var connectionTask: Task<Void, Never>?

    init(draft: TrafficWebSocketReconnectDraft, connectHandler: @escaping ConnectHandler) {
        self.draft = draft
        self.connectHandler = connectHandler
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 760, height: 650)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        connectionTask?.cancel()
    }

    override func loadView() {
        configureURLField()
        configureEditor(
            headersTextView,
            scrollView: headersScrollView,
            identifier: "webSocketReconnect.headers",
            label: "WebSocket request headers"
        )
        configureEditor(
            payloadTextView,
            scrollView: payloadScrollView,
            identifier: "webSocketReconnect.payload",
            label: "WebSocket replay payload"
        )
        configurePayloadControls()
        configureActions()

        headersTextView.string = draft.headersText
        payloadTextView.string = draft.payload
        encodingSelector.selectedSegment = draft.payloadEncoding == .base64 ? 1 : 0
        payloadMessageField.stringValue = draft.payloadStatusMessage ?? ""

        let titleField = NSTextField(labelWithString: "Reconnect WebSocket")
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.setAccessibilityIdentifier("webSocketReconnect.title")
        let explanationField = NSTextField(
            wrappingLabelWithString:
                "Open a fresh client connection. Transport headers are rebuilt automatically, and an optional replay is always sent to the server."
        )
        explanationField.textColor = .secondaryLabelColor

        let urlLabel = Self.fieldLabel("URL")
        let headersLabel = Self.fieldLabel("Request headers")
        let payloadLabel = Self.fieldLabel("Replay payload")
        let payloadHeader = NSStackView(views: [
            payloadLabel,
            encodingSelector,
            formatJSONButton
        ])
        payloadHeader.orientation = .horizontal
        payloadHeader.alignment = .centerY
        payloadHeader.spacing = 8

        let flexibleSpace = NSView()
        flexibleSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [
            statusField,
            flexibleSpace,
            cancelButton,
            connectButton,
            replayButton
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        for child in [
            titleField,
            explanationField,
            urlLabel,
            urlField,
            headersLabel,
            headersScrollView,
            payloadHeader,
            payloadMessageField,
            payloadScrollView,
            actions
        ] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            titleField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            explanationField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            explanationField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            explanationField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
            urlLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            urlLabel.topAnchor.constraint(equalTo: explanationField.bottomAnchor, constant: 14),
            urlField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            urlField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            urlField.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 5),
            headersLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            headersLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 12),
            headersScrollView.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            headersScrollView.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            headersScrollView.topAnchor.constraint(equalTo: headersLabel.bottomAnchor, constant: 5),
            headersScrollView.heightAnchor.constraint(equalToConstant: 145),
            payloadHeader.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            payloadHeader.topAnchor.constraint(
                equalTo: headersScrollView.bottomAnchor, constant: 12),
            payloadMessageField.leadingAnchor.constraint(
                greaterThanOrEqualTo: payloadHeader.trailingAnchor,
                constant: 10
            ),
            payloadMessageField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            payloadMessageField.centerYAnchor.constraint(equalTo: payloadHeader.centerYAnchor),
            payloadScrollView.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            payloadScrollView.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            payloadScrollView.topAnchor.constraint(
                equalTo: payloadHeader.bottomAnchor, constant: 5),
            payloadScrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            replayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 125)
        ])
        view = container
        updatePayloadPresentation()
        applyHighlighting(to: headersTextView, as: .httpHeaders)
        applyPayloadHighlighting()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(urlField)
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingHighlight, let textView = notification.object as? NSTextView else {
            return
        }
        clearStatus()
        if textView === headersTextView {
            applyHighlighting(to: textView, as: .httpHeaders)
        } else if textView === payloadTextView {
            applyPayloadHighlighting()
        }
    }

    private func configureURLField() {
        urlField.stringValue = draft.urlText
        urlField.placeholderString = "wss://example.com/socket"
        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.setAccessibilityIdentifier("webSocketReconnect.url")
        urlField.setAccessibilityLabel("WebSocket URL")
        urlField.setAccessibilityHelp(
            "Enter an absolute ws or wss URL without credentials or a fragment"
        )
    }

    private func configureEditor(
        _ textView: NSTextView,
        scrollView: NSScrollView,
        identifier: String,
        label: String
    ) {
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier(identifier)
        textView.setAccessibilityLabel(label)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
    }

    private func configurePayloadControls() {
        encodingSelector.segmentStyle = .separated
        encodingSelector.target = self
        encodingSelector.action = #selector(encodingChanged(_:))
        encodingSelector.setAccessibilityIdentifier("webSocketReconnect.encoding")
        encodingSelector.setAccessibilityLabel("WebSocket replay payload type")

        formatJSONButton.bezelStyle = .rounded
        formatJSONButton.target = self
        formatJSONButton.action = #selector(formatJSON(_:))
        formatJSONButton.setAccessibilityIdentifier("webSocketReconnect.formatJSON")
        formatJSONButton.setAccessibilityLabel("Format JSON replay payload")

        payloadMessageField.font = .systemFont(ofSize: 10, weight: .regular)
        payloadMessageField.textColor = .secondaryLabelColor
        payloadMessageField.alignment = .right
        payloadMessageField.maximumNumberOfLines = 2
        payloadMessageField.setAccessibilityIdentifier("webSocketReconnect.payloadMessage")
    }

    private func configureActions() {
        statusField.font = .systemFont(ofSize: 11, weight: .regular)
        statusField.textColor = .systemRed
        statusField.maximumNumberOfLines = 2
        statusField.setAccessibilityIdentifier("webSocketReconnect.status")
        statusField.setAccessibilityLabel("WebSocket reconnect status")
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.setAccessibilityIdentifier("webSocketReconnect.cancel")

        connectButton.bezelStyle = .rounded
        connectButton.target = self
        connectButton.action = #selector(connectOnly(_:))
        connectButton.setAccessibilityIdentifier("webSocketReconnect.connect")
        connectButton.setAccessibilityLabel("Connect without replaying a message")

        replayButton.bezelStyle = .rounded
        replayButton.keyEquivalent = "\r"
        replayButton.target = self
        replayButton.action = #selector(connectAndReplay(_:))
        replayButton.setAccessibilityIdentifier("webSocketReconnect.connectAndReplay")
        replayButton.setAccessibilityLabel("Connect and replay the message to the server")
    }

    @objc private func encodingChanged(_ sender: NSSegmentedControl) {
        clearStatus()
        updatePayloadPresentation()
        applyPayloadHighlighting()
    }

    @objc private func formatJSON(_ sender: NSButton) {
        do {
            let object = try JSONSerialization.jsonObject(
                with: Data(payloadTextView.string.utf8),
                options: [.fragmentsAllowed]
            )
            let formatted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]
            )
            guard let value = String(data: formatted, encoding: .utf8) else {
                return
            }
            payloadTextView.string = value
            clearStatus()
            applyPayloadHighlighting()
        } catch {
            showStatus("The text payload is not valid JSON.")
        }
    }

    @objc private func connectOnly(_ sender: NSButton) {
        connect(replayPayload: false)
    }

    @objc private func connectAndReplay(_ sender: NSButton) {
        connect(replayPayload: true)
    }

    @objc private func cancel(_ sender: NSButton) {
        connectionTask?.cancel()
        dismiss(self)
    }

    private func connect(replayPayload: Bool) {
        guard connectionTask == nil else {
            return
        }
        let encoding: WebSocketComposePayloadEncoding =
            encodingSelector.selectedSegment == 1 ? .base64 : .text
        setConnecting(true)
        connectionTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                connectionTask = nil
                setConnecting(false)
            }
            do {
                try await connectHandler(
                    urlField.stringValue,
                    headersTextView.string,
                    encoding,
                    payloadTextView.string,
                    replayPayload
                )
                dismiss(self)
            } catch {
                showStatus(error.localizedDescription)
            }
        }
    }

    private func updatePayloadPresentation() {
        let isBinary = encodingSelector.selectedSegment == 1
        formatJSONButton.isEnabled = !isBinary && connectionTask == nil
        payloadTextView.setAccessibilityHelp(
            isBinary
                ? "Enter Base64-encoded bytes. Maximum decoded size: 1 MB."
                : "Text is sent as UTF-8. Valid JSON can be formatted and highlighted."
        )
    }

    private func applyPayloadHighlighting() {
        let language: InspectorSyntaxHighlighter.Language =
            encodingSelector.selectedSegment == 0 && Self.isJSON(payloadTextView.string)
            ? .json
            : .plainText
        applyHighlighting(to: payloadTextView, as: language)
    }

    private func applyHighlighting(
        to textView: NSTextView,
        as language: InspectorSyntaxHighlighter.Language
    ) {
        let selection = textView.selectedRanges
        isApplyingHighlight = true
        textView.textStorage?.setAttributedString(
            InspectorSyntaxHighlighter.highlight(textView.string, as: language)
        )
        textView.selectedRanges = selection
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        isApplyingHighlight = false
    }

    private func setConnecting(_ isConnecting: Bool) {
        urlField.isEnabled = !isConnecting
        headersTextView.isEditable = !isConnecting
        encodingSelector.isEnabled = !isConnecting
        payloadTextView.isEditable = !isConnecting
        cancelButton.isEnabled = !isConnecting
        connectButton.isEnabled = !isConnecting
        replayButton.isEnabled = !isConnecting
        formatJSONButton.isEnabled = !isConnecting && encodingSelector.selectedSegment == 0
        if isConnecting {
            statusField.textColor = .secondaryLabelColor
            statusField.stringValue = "Opening WebSocket connection…"
        }
    }

    private func clearStatus() {
        statusField.stringValue = ""
        statusField.textColor = .systemRed
    }

    private func showStatus(_ message: String) {
        statusField.textColor = .systemRed
        statusField.stringValue = message
        NSAccessibility.post(element: statusField, notification: .valueChanged)
    }

    private static func fieldLabel(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        return field
    }

    private static func isJSON(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return
            (try? JSONSerialization.jsonObject(
                with: Data(trimmed.utf8),
                options: [.fragmentsAllowed]
            )) != nil
    }
}
