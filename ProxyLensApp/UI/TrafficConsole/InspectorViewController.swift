import AppKit
import ProxyLensCore
import UniformTypeIdentifiers

private enum MessageInspectorSection: String {
    case headers = "Headers"
    case query = "Query"
    case cookies = "Cookies"
    case body = "Body"
    case preview = "Preview"
    case json = "JSON"
    case jsonPath = "JSONPath"
    case tree = "Tree"
    case xml = "XML"
    case form = "Form"
    case graphql = "GraphQL"
    case protobuf = "Protobuf"
    case hex = "Hex"
    case raw = "Raw"
}

@MainActor
final class InspectorViewController: NSViewController {
    private let viewModel: TrafficConsoleViewModel?
    private let summaryMethodField = NSTextField(labelWithString: "")
    private let summaryStatusField = NSTextField(labelWithString: "")
    private let summaryLockImageView = NSImageView()
    private let summaryURLField = NSTextField(labelWithString: "No Flow Selected")
    private let summaryMetadataField = NSTextField(labelWithString: "")
    private let annotationBar = FlowAnnotationBar(frame: .zero)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let modeSelector = NSSegmentedControl(
        labels: ["Content", "Rules", "Timing", "Frames", "Events"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let requestPane = MessageInspectorPaneViewController(
        title: "Request",
        accessibilityPrefix: "inspector.request",
        sections: [
            .headers, .query, .cookies, .body, .preview, .json, .jsonPath, .tree, .xml, .form,
            .graphql, .protobuf, .hex, .raw
        ]
    )
    private let responsePane = MessageInspectorPaneViewController(
        title: "Response",
        accessibilityPrefix: "inspector.response",
        sections: [
            .headers, .cookies, .body, .preview, .json, .jsonPath, .tree, .xml, .form,
            .protobuf, .hex, .raw
        ]
    )
    private let contentSplitViewController = NSSplitViewController()
    private let rulesTextView = NSTextView()
    private let rulesScrollView = NSScrollView()
    private let timingView = TrafficTimingView(frame: .zero)
    private let webSocketFramesController = WebSocketFramesViewController()
    private let serverSentEventsController = ServerSentEventsViewController()
    private var inspection = TrafficFlowInspection.empty
    private var editedHeaders: [Int: String] = [:]
    private var editedBodies: [Int: String] = [:]
    private var hasUserEdits = false

    init(viewModel: TrafficConsoleViewModel? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        configureSummary()
        configureAnnotations()
        configureBreakpointControls()
        configureModeSelector()
        configureMessagePanes()
        configureRulesView()
        timingView.translatesAutoresizingMaskIntoConstraints = false
        webSocketFramesController.onFrameSelection = { [weak self] frameID in
            self?.viewModel?.selectWebSocketFrame(frameID)
        }
        webSocketFramesController.onDirectionFilterChange = { [weak self] filter in
            self?.viewModel?.setWebSocketDirectionFilter(filter)
        }
        webSocketFramesController.onSearchTextChange = { [weak self] query in
            self?.viewModel?.setWebSocketSearchText(query)
        }
        webSocketFramesController.onPayloadModeChange = { [weak self] mode in
            self?.viewModel?.setWebSocketPayloadMode(mode)
        }
        webSocketFramesController.onCompose = { [weak self] in
            self?.presentWebSocketComposer()
        }
        webSocketFramesController.onReconnect = { [weak self] in
            self?.presentWebSocketReconnect()
        }
        webSocketFramesController.onDisconnect = { [weak self] in
            self?.disconnectWebSocket()
        }
        webSocketFramesController.onExport = { [weak self] in
            self?.exportWebSocketFrames()
        }
        serverSentEventsController.onEventSelection = { [weak self] eventID in
            self?.viewModel?.selectServerSentEvent(eventID)
        }
        serverSentEventsController.onSearchTextChange = { [weak self] query in
            self?.viewModel?.setServerSentEventSearchText(query)
        }
        serverSentEventsController.onExport = { [weak self] in
            self?.exportServerSentEvents()
        }
        let webSocketFramesView = webSocketFramesController.view
        webSocketFramesView.translatesAutoresizingMaskIntoConstraints = false
        let serverSentEventsView = serverSentEventsController.view
        serverSentEventsView.translatesAutoresizingMaskIntoConstraints = false

        let breakpointStack = NSStackView(views: [continueButton, abortButton])
        breakpointStack.translatesAutoresizingMaskIntoConstraints = false
        breakpointStack.orientation = .horizontal
        breakpointStack.spacing = 8
        breakpointStack.alignment = .centerY

        let summaryStack = NSStackView(views: [
            summaryMethodField,
            summaryStatusField,
            summaryLockImageView,
            summaryURLField,
            summaryMetadataField,
            modeSelector,
            breakpointStack
        ])
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        summaryStack.orientation = .horizontal
        summaryStack.spacing = 7
        summaryStack.distribution = .fill
        summaryStack.alignment = .centerY
        summaryStack.setHuggingPriority(.defaultHigh, for: .vertical)

        let contentSplitView = contentSplitViewController.view
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        addChild(contentSplitViewController)
        addChild(webSocketFramesController)
        addChild(serverSentEventsController)
        container.addSubview(summaryStack)
        container.addSubview(annotationBar)
        container.addSubview(contentSplitView)
        container.addSubview(rulesScrollView)
        container.addSubview(timingView)
        container.addSubview(webSocketFramesView)
        container.addSubview(serverSentEventsView)
        NSLayoutConstraint.activate([
            summaryStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            summaryStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            summaryStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            annotationBar.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: 8
            ),
            annotationBar.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -8
            ),
            annotationBar.topAnchor.constraint(equalTo: summaryStack.bottomAnchor, constant: 5),
            contentSplitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentSplitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentSplitView.topAnchor.constraint(
                equalTo: annotationBar.bottomAnchor, constant: 7),
            contentSplitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rulesScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rulesScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rulesScrollView.topAnchor.constraint(
                equalTo: annotationBar.bottomAnchor, constant: 7),
            rulesScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            timingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            timingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            timingView.topAnchor.constraint(equalTo: annotationBar.bottomAnchor, constant: 7),
            timingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webSocketFramesView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webSocketFramesView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webSocketFramesView.topAnchor.constraint(
                equalTo: annotationBar.bottomAnchor, constant: 7),
            webSocketFramesView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            serverSentEventsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            serverSentEventsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            serverSentEventsView.topAnchor.constraint(
                equalTo: annotationBar.bottomAnchor, constant: 7),
            serverSentEventsView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
        render(.initial)
    }

    func render(_ snapshot: TrafficConsoleSnapshot) {
        let previousFlowID = inspection.flowID
        let previousBreakpoint = inspection.breakpoint
        inspection = snapshot.inspection
        if previousFlowID != inspection.flowID || previousBreakpoint != inspection.breakpoint {
            editedHeaders.removeAll()
            editedBodies.removeAll()
            hasUserEdits = false
        }
        updateSummary()
        annotationBar.render(
            annotation: inspection.annotation,
            hasSelection: inspection.flowID != nil,
            resetEdits: previousFlowID != inspection.flowID
        )
        let isPaused = inspection.breakpoint != nil
        continueButton.isHidden = !isPaused
        abortButton.isHidden = !isPaused
        continueButton.isEnabled = isPaused
        abortButton.isEnabled = isPaused
        modeSelector.isEnabled = inspection.flowID != nil
        modeSelector.setEnabled(inspection.webSocket != nil, forSegment: 3)
        modeSelector.setEnabled(inspection.serverSentEvents != nil, forSegment: 4)
        if inspection.flowID == nil {
            modeSelector.selectedSegment = 0
        } else if inspection.breakpoint?.phase == .webSocketResponse {
            modeSelector.selectedSegment = 3
        } else if inspection.webSocket == nil, modeSelector.selectedSegment == 3 {
            modeSelector.selectedSegment = 0
        } else if inspection.serverSentEvents == nil, modeSelector.selectedSegment == 4 {
            modeSelector.selectedSegment = 0
        }
        rulesTextView.string = inspection.rules
        timingView.render(inspection.timing)
        webSocketFramesController.render(
            inspection.webSocket,
            breakpoint: inspection.breakpoint?.webSocketFrame,
            resetBreakpoint: previousFlowID != inspection.flowID
        )
        serverSentEventsController.render(inspection.serverSentEvents)
        updateModeVisibility()

        if hasUserEdits, previousFlowID == inspection.flowID {
            updateEditingState()
            return
        }

        updateMessagePane(requestPane, messageIndex: 0, message: inspection.request)
        updateMessagePane(responsePane, messageIndex: 1, message: inspection.response)
    }

    private func configureSummary() {
        configureBadge(
            summaryMethodField,
            identifier: "inspector.summary.method",
            minimumWidth: 46
        )
        configureBadge(
            summaryStatusField,
            identifier: "inspector.summary.status",
            minimumWidth: 62
        )

        summaryLockImageView.translatesAutoresizingMaskIntoConstraints = false
        summaryLockImageView.image = NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: "Secure connection"
        )
        summaryLockImageView.contentTintColor = .secondaryLabelColor
        summaryLockImageView.imageScaling = .scaleProportionallyDown
        summaryLockImageView.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            summaryLockImageView.widthAnchor.constraint(equalToConstant: 13),
            summaryLockImageView.heightAnchor.constraint(equalToConstant: 13)
        ])

        summaryURLField.translatesAutoresizingMaskIntoConstraints = false
        summaryURLField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summaryURLField.lineBreakMode = .byTruncatingMiddle
        summaryURLField.maximumNumberOfLines = 1
        summaryURLField.isSelectable = true
        summaryURLField.setAccessibilityIdentifier("inspector.summary.url")
        summaryURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryURLField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryMetadataField.translatesAutoresizingMaskIntoConstraints = false
        summaryMetadataField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        summaryMetadataField.textColor = .secondaryLabelColor
        summaryMetadataField.lineBreakMode = .byTruncatingTail
        summaryMetadataField.setAccessibilityIdentifier("inspector.summary.metadata")
        summaryMetadataField.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureAnnotations() {
        annotationBar.saveHandler = { [weak self] annotation in
            guard let self else {
                return
            }
            guard let flowID = inspection.flowID, let viewModel else {
                throw ProxyLensError.unsupportedOperation("Flow annotations are not available")
            }
            try await viewModel.updateAnnotation(annotation, for: flowID)
        }
    }

    private func configureBadge(
        _ field: NSTextField,
        identifier: String,
        minimumWidth: CGFloat
    ) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        field.alignment = .center
        field.drawsBackground = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.setAccessibilityIdentifier(identifier)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
    }

    private func configureBreakpointControls() {
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.bezelStyle = .rounded
        continueButton.target = self
        continueButton.action = #selector(continueBreakpoint)
        continueButton.setAccessibilityIdentifier("inspector.continue")

        abortButton.translatesAutoresizingMaskIntoConstraints = false
        abortButton.bezelStyle = .rounded
        abortButton.target = self
        abortButton.action = #selector(abortBreakpoint)
        abortButton.setAccessibilityIdentifier("inspector.abort")
    }

    private func configureModeSelector() {
        modeSelector.translatesAutoresizingMaskIntoConstraints = false
        modeSelector.selectedSegment = 0
        modeSelector.segmentStyle = .separated
        modeSelector.controlSize = .small
        modeSelector.target = self
        modeSelector.action = #selector(modeSelectionChanged)
        modeSelector.setAccessibilityIdentifier("inspector.mode")
        modeSelector.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func updateSummary() {
        guard let summary = inspection.summary else {
            summaryMethodField.isHidden = true
            summaryStatusField.isHidden = true
            summaryLockImageView.isHidden = true
            summaryMetadataField.isHidden = true
            summaryURLField.stringValue = inspection.title
            summaryURLField.toolTip = inspection.title
            return
        }

        let methodColor = Self.methodColor(summary.method)
        summaryMethodField.isHidden = false
        summaryMethodField.stringValue = summary.method
        summaryMethodField.textColor = methodColor
        summaryMethodField.backgroundColor = methodColor.withAlphaComponent(0.14)

        let statusColor = Self.statusColor(summary)
        summaryStatusField.isHidden = false
        summaryStatusField.stringValue = Self.statusText(summary)
        summaryStatusField.textColor = statusColor
        summaryStatusField.backgroundColor = statusColor.withAlphaComponent(0.14)

        summaryLockImageView.isHidden = !summary.usesTLS
        summaryURLField.stringValue = summary.url
        summaryURLField.toolTip = summary.url
        summaryMetadataField.isHidden = false
        summaryMetadataField.stringValue = [
            Self.formattedDuration(summary.duration),
            Self.formattedByteCount(summary.byteCount)
        ].joined(separator: "  •  ")
    }

    private func configureMessagePanes() {
        requestPane.onSelectionChange = { [weak self] pane in
            self?.selectionChanged(in: pane, messageIndex: 0)
        }
        requestPane.onTextChange = { [weak self] pane in
            self?.textChanged(in: pane, messageIndex: 0)
        }
        requestPane.onProtobufImport = { [weak self] in
            self?.presentProtobufDescriptorImporter()
        }
        requestPane.onProtobufMessageTypeChange = { [weak self] messageType in
            self?.selectProtobufMessageType(messageType, direction: .request)
        }
        responsePane.onSelectionChange = { [weak self] pane in
            self?.selectionChanged(in: pane, messageIndex: 1)
        }
        responsePane.onTextChange = { [weak self] pane in
            self?.textChanged(in: pane, messageIndex: 1)
        }
        responsePane.onProtobufImport = { [weak self] in
            self?.presentProtobufDescriptorImporter()
        }
        responsePane.onProtobufMessageTypeChange = { [weak self] messageType in
            self?.selectProtobufMessageType(messageType, direction: .response)
        }

        contentSplitViewController.splitView.isVertical = true
        contentSplitViewController.splitView.dividerStyle = .thin
        contentSplitViewController.splitView.setAccessibilityIdentifier(
            "inspector.split.messages"
        )

        let requestItem = NSSplitViewItem(viewController: requestPane)
        requestItem.minimumThickness = 260
        requestItem.preferredThicknessFraction = 0.5

        let responseItem = NSSplitViewItem(viewController: responsePane)
        responseItem.minimumThickness = 260
        responseItem.preferredThicknessFraction = 0.5

        contentSplitViewController.addSplitViewItem(requestItem)
        contentSplitViewController.addSplitViewItem(responseItem)
    }

    private func presentProtobufDescriptorImporter() {
        guard let window = view.window, let viewModel else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Protobuf Descriptor Set"
        panel.message = "Choose a compiled FileDescriptorSet generated by protoc."
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["desc", "pb", "protoset"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.beginSheetModal(for: window) { [weak self, weak viewModel] response in
            guard response == .OK, let url = panel.url, let self, let viewModel else {
                return
            }
            Task { @MainActor in
                do {
                    try await viewModel.importProtobufDescriptorSet(from: url)
                } catch {
                    self.presentProtobufError(error)
                }
            }
        }
    }

    private func selectProtobufMessageType(
        _ messageType: String?,
        direction: TrafficMessageDirection
    ) {
        guard let viewModel else {
            return
        }
        Task { @MainActor [weak self, weak viewModel] in
            do {
                try await viewModel?.selectProtobufMessageType(
                    messageType,
                    direction: direction
                )
            } catch {
                self?.presentProtobufError(error)
            }
        }
    }

    private func presentProtobufError(_ error: Error) {
        guard let window = view.window else {
            return
        }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func configureRulesView() {
        rulesTextView.isEditable = false
        rulesTextView.isSelectable = true
        rulesTextView.isRichText = false
        rulesTextView.usesFindBar = true
        rulesTextView.isIncrementalSearchingEnabled = true
        rulesTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        rulesTextView.textContainerInset = NSSize(width: 10, height: 10)
        rulesTextView.backgroundColor = .textBackgroundColor
        rulesTextView.setAccessibilityIdentifier("inspector.rules.content")
        rulesTextView.isHorizontallyResizable = true
        rulesTextView.isVerticallyResizable = true
        rulesTextView.autoresizingMask = [.width]
        rulesTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        rulesTextView.textContainer?.widthTracksTextView = false

        rulesScrollView.translatesAutoresizingMaskIntoConstraints = false
        rulesScrollView.documentView = rulesTextView
        rulesScrollView.hasVerticalScroller = true
        rulesScrollView.hasHorizontalScroller = true
        rulesScrollView.autohidesScrollers = true
        rulesScrollView.borderType = .noBorder
    }

    @objc private func modeSelectionChanged(_ sender: Any?) {
        updateModeVisibility()
        if modeSelector.selectedSegment == 1 {
            rulesTextView.scrollToBeginningOfDocument(nil)
        }
    }

    private func updateModeVisibility() {
        let hasSelection = inspection.flowID != nil
        let showsRules = modeSelector.selectedSegment == 1 && hasSelection
        let showsTiming = modeSelector.selectedSegment == 2 && hasSelection
        let showsFrames = modeSelector.selectedSegment == 3 && inspection.webSocket != nil
        let showsEvents =
            modeSelector.selectedSegment == 4 && inspection.serverSentEvents != nil
        contentSplitViewController.view.isHidden =
            showsRules || showsTiming || showsFrames || showsEvents
        rulesScrollView.isHidden = !showsRules
        timingView.isHidden = !showsTiming
        webSocketFramesController.view.isHidden = !showsFrames
        serverSentEventsController.view.isHidden = !showsEvents
    }

    private func selectionChanged(
        in pane: MessageInspectorPaneViewController,
        messageIndex: Int
    ) {
        saveCurrentEdits(in: pane, messageIndex: messageIndex)
        let message = messageIndex == 0 ? inspection.request : inspection.response
        updateMessagePane(pane, messageIndex: messageIndex, message: message)
    }

    private func textChanged(
        in pane: MessageInspectorPaneViewController,
        messageIndex: Int
    ) {
        guard pane.isContentEditable else {
            return
        }
        hasUserEdits = true
        saveCurrentEdits(in: pane, messageIndex: messageIndex)
    }

    private func updateMessagePane(
        _ pane: MessageInspectorPaneViewController,
        messageIndex: Int,
        message: TrafficMessageInspection?
    ) {
        guard let message else {
            let placeholder =
                messageIndex == 0
                ? "Select a captured flow to inspect its request."
                : "No response has been captured for this flow."
            pane.display(
                placeholder,
                isEditable: false,
                isSelectorEnabled: false
            )
            return
        }

        let content: String
        var syntaxLanguage = InspectorSyntaxHighlighter.Language.plainText
        var highlightedRange: NSRange?
        var protobufSchema: TrafficProtobufSchemaInspection?
        switch pane.selectedSection {
        case .headers:
            content = editedHeaders[messageIndex] ?? message.headers
            syntaxLanguage = .httpHeaders
        case .query:
            content = message.query ?? "No query parameters."
            syntaxLanguage = .urlEncodedForm
        case .cookies:
            content = message.cookies
            syntaxLanguage = .urlEncodedForm
        case .preview:
            pane.displayImage(message.image, isSelectorEnabled: true)
            return
        case .json:
            content = Self.bodyText(message.json, editable: false)
            highlightedRange = Self.bodyContentRange(message.json, editable: false)
            if highlightedRange != nil {
                syntaxLanguage = .json
            }
        case .tree:
            pane.displayTree(message.jsonTree, isSelectorEnabled: true)
            return
        case .jsonPath:
            pane.displayJSONPath(message.json, isSelectorEnabled: true)
            return
        case .xml:
            content = Self.bodyText(message.xml, editable: false)
            highlightedRange = Self.bodyContentRange(message.xml, editable: false)
            if highlightedRange != nil {
                syntaxLanguage = .xml
            }
        case .form:
            content = Self.bodyText(message.form, editable: false)
            highlightedRange = Self.bodyContentRange(message.form, editable: false)
            if highlightedRange != nil {
                syntaxLanguage = .urlEncodedForm
            }
        case .graphql:
            content = Self.bodyText(message.graphql, editable: false)
            highlightedRange = Self.bodyContentRange(message.graphql, editable: false)
            if highlightedRange != nil {
                syntaxLanguage = .graphql
            }
        case .protobuf:
            content = Self.bodyText(message.protobuf, editable: false)
            highlightedRange = Self.bodyContentRange(message.protobuf, editable: false)
            protobufSchema = message.protobufSchema
            if highlightedRange != nil {
                syntaxLanguage = .protobuf
            }
        case .hex:
            content = Self.bodyText(message.hex, editable: false)
        case .body:
            if let editedBody = editedBodies[messageIndex] {
                content = editedBody
                syntaxLanguage = InspectorSyntaxHighlighter.language(
                    forContentType: message.bodyContentType
                )
            } else {
                let isEditable = isEditingMessage(messageIndex)
                content = Self.bodyText(
                    message.body,
                    editable: isEditable
                )
                highlightedRange = Self.bodyContentRange(message.body, editable: isEditable)
                if highlightedRange != nil {
                    syntaxLanguage = InspectorSyntaxHighlighter.language(
                        forContentType: message.bodyContentType
                    )
                }
            }
        case .raw:
            let raw = Self.rawText(
                message,
                editedHeaders: editedHeaders[messageIndex],
                editedBody: editedBodies[messageIndex]
            )
            content = raw.content
            syntaxLanguage = .httpHeaders
            highlightedRange = raw.headerRange
        }

        pane.display(
            content,
            language: syntaxLanguage,
            highlightedRange: highlightedRange,
            isEditable: isEditingSection(
                pane.selectedSection,
                messageIndex: messageIndex
            ),
            isSelectorEnabled: true,
            protobufSchema: protobufSchema
        )
    }

    private func updateEditingState() {
        requestPane.isContentEditable = isEditingSection(
            requestPane.selectedSection,
            messageIndex: 0
        )
        responsePane.isContentEditable = isEditingSection(
            responsePane.selectedSection,
            messageIndex: 1
        )
    }

    private func isEditingMessage(_ messageIndex: Int) -> Bool {
        guard let breakpoint = inspection.breakpoint else {
            return false
        }
        switch breakpoint.phase {
        case .request:
            return messageIndex == 0
        case .response:
            return messageIndex == 1
        case .webSocketResponse:
            return false
        }
    }

    private func isEditingSection(
        _ section: MessageInspectorSection,
        messageIndex: Int
    ) -> Bool {
        guard isEditingMessage(messageIndex) else {
            return false
        }
        if section == .headers {
            return true
        }
        if section == .body {
            return inspection.breakpoint?.canEditBody == true
        }
        return false
    }

    private func saveCurrentEdits(
        in pane: MessageInspectorPaneViewController,
        messageIndex: Int
    ) {
        guard isEditingMessage(messageIndex) else {
            return
        }
        if pane.displayedSection == .headers {
            editedHeaders[messageIndex] = pane.content
        } else if pane.displayedSection == .body,
            inspection.breakpoint?.canEditBody == true
        {
            editedBodies[messageIndex] = pane.content
        }
    }

    private func saveCurrentEdits() {
        saveCurrentEdits(in: requestPane, messageIndex: 0)
        saveCurrentEdits(in: responsePane, messageIndex: 1)
    }

    @objc private func continueBreakpoint() {
        guard let breakpoint = inspection.breakpoint else {
            return
        }
        if breakpoint.phase == .webSocketResponse {
            let payload = webSocketFramesController.pendingBreakpointPayloadText()
            Task { @MainActor in
                do {
                    try await viewModel?.continueBreakpoint(
                        headersText: "",
                        bodyText: nil,
                        webSocketPayloadText: payload
                    )
                } catch {
                    let alert = NSAlert(error: error)
                    if let window = view.window {
                        await alert.beginSheetModal(for: window)
                    } else {
                        alert.runModal()
                    }
                }
            }
            return
        }
        saveCurrentEdits()
        let messageIndex = breakpoint.phase == .response ? 1 : 0
        let headersText: String
        if let edited = editedHeaders[messageIndex] {
            headersText = edited
        } else if messageIndex == 1 {
            headersText = inspection.response?.headers ?? ""
        } else {
            headersText = inspection.request?.headers ?? ""
        }
        let bodyText = editedBodies[messageIndex]
        Task { @MainActor in
            do {
                try await viewModel?.continueBreakpoint(
                    headersText: headersText,
                    bodyText: bodyText
                )
            } catch {
                let alert = NSAlert(error: error)
                if let window = view.window {
                    await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    @objc private func abortBreakpoint() {
        viewModel?.abortBreakpoint()
    }

    private func exportWebSocketFrames() {
        guard let flowID = inspection.flowID, let viewModel else {
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export WebSocket Frames"
        panel.nameFieldStringValue = "ProxyLens WebSocket Frames.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else {
                return
            }
            Task { @MainActor in
                do {
                    try await viewModel.writeWebSocketFrames(
                        flowID: flowID,
                        to: destination
                    )
                } catch {
                    self?.presentWebSocketExportError(error)
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    private func exportServerSentEvents() {
        guard let flowID = inspection.flowID, let viewModel else {
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Server-Sent Events"
        panel.nameFieldStringValue = "ProxyLens Server-Sent Events.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else {
                return
            }
            Task { @MainActor in
                do {
                    try await viewModel.writeServerSentEvents(
                        flowID: flowID,
                        to: destination
                    )
                } catch {
                    self?.presentWebSocketExportError(error)
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    private func presentWebSocketComposer() {
        guard inspection.webSocket?.canCompose == true, let viewModel else {
            return
        }
        let composer = WebSocketComposerViewController(flowTitle: inspection.title) {
            direction,
            encoding,
            payload in
            try await viewModel.sendWebSocketMessage(
                direction: direction,
                payloadEncoding: encoding,
                payload: payload
            )
        }
        presentAsSheet(composer)
    }

    private func presentWebSocketReconnect() {
        guard inspection.webSocket?.canReconnect == true, let viewModel else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                let draft = try await viewModel.webSocketReconnectDraft()
                let controller = WebSocketReconnectViewController(draft: draft) {
                    urlText,
                    headersText,
                    encoding,
                    payload,
                    replayPayload in
                    try await viewModel.reconnectWebSocket(
                        urlText: urlText,
                        headersText: headersText,
                        payloadEncoding: encoding,
                        payload: payload,
                        replayPayload: replayPayload
                    )
                }
                presentAsSheet(controller)
            } catch {
                presentWebSocketExportError(error)
            }
        }
    }

    private func disconnectWebSocket() {
        guard inspection.webSocket?.canDisconnect == true, let viewModel else {
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await viewModel.disconnectSelectedWebSocket()
            } catch {
                self?.presentWebSocketExportError(error)
            }
        }
    }

    private func presentWebSocketExportError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func bodyText(_ body: TrafficBodyPresentation, editable: Bool) -> String {
        switch body {
        case .none(let message):
            return editable ? "" : message
        case .loading(let metadata):
            return "\(metadata)\n\nLoading captured bytes…"
        case .content(let metadata, let value):
            return editable ? value : "\(metadata)\n\n\(value)"
        case .failed(let metadata, let message):
            return "\(metadata)\n\nUnable to read captured bytes:\n\(message)"
        }
    }

    private static func bodyContentRange(
        _ body: TrafficBodyPresentation,
        editable: Bool
    ) -> NSRange? {
        guard case .content(let metadata, let value) = body else {
            return nil
        }
        return NSRange(
            location: editable ? 0 : metadata.utf16.count + 2,
            length: value.utf16.count
        )
    }

    private static func rawText(
        _ message: TrafficMessageInspection,
        editedHeaders: String?,
        editedBody: String?
    ) -> (content: String, headerRange: NSRange) {
        let headers = editedHeaders ?? message.headers
        let body: String?
        if let editedBody {
            body = editedBody
        } else {
            switch message.body {
            case .none:
                body = nil
            case .loading:
                body = "Loading captured bytes…"
            case .content(_, let value):
                body = value
            case .failed(_, let error):
                body = "Unable to read captured bytes:\n\(error)"
            }
        }
        let content = body.map { "\(headers)\n\n\($0)" } ?? headers
        return (
            content,
            NSRange(location: 0, length: headers.utf16.count)
        )
    }

    private static func methodColor(_ method: String) -> NSColor {
        switch method {
        case "GET": .systemBlue
        case "POST": .systemGreen
        case "PUT", "PATCH": .systemOrange
        case "DELETE": .systemRed
        default: .labelColor
        }
    }

    private static func statusColor(_ summary: TrafficFlowSummaryInspection) -> NSColor {
        if let statusCode = summary.statusCode {
            switch statusCode {
            case 200..<300: return .systemGreen
            case 300..<400: return .systemBlue
            case 400..<500: return .systemOrange
            default: return .systemRed
            }
        }
        switch summary.state {
        case .failed, .cancelled: return .systemRed
        case .paused: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private static func statusText(_ summary: TrafficFlowSummaryInspection) -> String {
        if let statusCode = summary.statusCode {
            if let reason = summary.statusReason, !reason.isEmpty {
                return "\(statusCode) \(reason)"
            }
            return String(statusCode)
        }
        switch summary.state {
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .created, .receivingRequest, .connectingUpstream, .receivingResponse:
            return "Pending"
        }
    }

    private static func formattedDuration(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "—"
        }
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1_000)
        }
        return String(format: "%.2f s", duration)
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        if byteCount < 1_000 {
            return "\(byteCount) B"
        }
        if byteCount < 1_000_000 {
            return String(format: "%.1f KB", Double(byteCount) / 1_000)
        }
        return String(format: "%.1f MB", Double(byteCount) / 1_000_000)
    }
}

@MainActor
private final class MessageInspectorPaneViewController: NSViewController, NSTextViewDelegate {
    let paneTitle: String
    let accessibilityPrefix: String
    let sections: [MessageInspectorSection]
    let sectionSelector: NSSegmentedControl
    private let titleField: NSTextField
    private let sectionPopup = NSPopUpButton()
    private let selectorHostView = NSView()
    private let protobufToolbar = NSStackView()
    private let protobufImportButton = NSButton(title: "Import…", target: nil, action: nil)
    private let protobufDescriptorField = NSTextField(labelWithString: "No descriptor")
    private let protobufMessageTypePopup = NSPopUpButton()
    let textView = NSTextView()
    private let contentScrollView = NSScrollView()
    private var contentConstraints: [ObjectIdentifier: [NSLayoutConstraint]] = [:]
    private var contentViews: [NSView] = []
    let jsonTreeView: JSONTreeView
    let jsonPathView: JSONPathView
    let imagePreviewView: ImagePreviewView
    var onSelectionChange: ((MessageInspectorPaneViewController) -> Void)?
    var onTextChange: ((MessageInspectorPaneViewController) -> Void)?
    var onProtobufImport: (() -> Void)?
    var onProtobufMessageTypeChange: ((String?) -> Void)?
    private(set) var displayedSection: MessageInspectorSection
    private let expandedSelectorWidth: CGFloat
    private var expandedSelectorConstraints: [NSLayoutConstraint] = []
    private var compactSelectorConstraints: [NSLayoutConstraint] = []
    private var usesCompactSelector = true
    private var isUpdatingContent = false

    var selectedSection: MessageInspectorSection {
        let selectedSegment = sectionSelector.selectedSegment
        guard sections.indices.contains(selectedSegment) else {
            return sections[0]
        }
        return sections[selectedSegment]
    }

    var content: String {
        textView.string
    }

    var isContentEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    init(
        title: String,
        accessibilityPrefix: String,
        sections: [MessageInspectorSection]
    ) {
        let sectionLabels = sections.map(\.rawValue)
        let sizingSelector = NSSegmentedControl(
            labels: sectionLabels,
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        sizingSelector.segmentStyle = .separated
        sizingSelector.controlSize = .small

        self.paneTitle = title
        self.accessibilityPrefix = accessibilityPrefix
        self.sections = sections
        self.sectionSelector = NSSegmentedControl(
            labels: sectionLabels,
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        self.expandedSelectorWidth = sizingSelector.fittingSize.width
        self.jsonTreeView = JSONTreeView(
            accessibilityIdentifier: "\(accessibilityPrefix).tree"
        )
        self.jsonPathView = JSONPathView(accessibilityPrefix: accessibilityPrefix)
        self.imagePreviewView = ImagePreviewView(accessibilityPrefix: accessibilityPrefix)
        self.titleField = NSTextField(labelWithString: title)
        self.displayedSection = sections[0]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)

        sectionSelector.translatesAutoresizingMaskIntoConstraints = false
        sectionSelector.selectedSegment = 0
        sectionSelector.segmentStyle = .separated
        sectionSelector.controlSize = .small
        sectionSelector.target = self
        sectionSelector.action = #selector(selectionChanged)
        sectionSelector.setAccessibilityIdentifier("\(accessibilityPrefix).section")
        sectionSelector.setAccessibilityLabel("\(paneTitle) inspector view")
        sectionSelector.setContentHuggingPriority(.required, for: .horizontal)
        sectionSelector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sectionSelector.isHidden = true

        sectionPopup.translatesAutoresizingMaskIntoConstraints = false
        sectionPopup.addItems(withTitles: sections.map(\.rawValue))
        sectionPopup.selectItem(at: 0)
        sectionPopup.controlSize = .small
        sectionPopup.target = self
        sectionPopup.action = #selector(compactSelectionChanged)
        sectionPopup.setAccessibilityIdentifier("\(accessibilityPrefix).section.compact")
        sectionPopup.setAccessibilityLabel("\(paneTitle) inspector view")
        sectionPopup.setContentHuggingPriority(.required, for: .horizontal)
        sectionPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        sectionPopup.isHidden = false

        selectorHostView.translatesAutoresizingMaskIntoConstraints = false
        selectorHostView.setContentHuggingPriority(.required, for: .horizontal)
        selectorHostView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectorHostView.addSubview(sectionSelector)
        selectorHostView.addSubview(sectionPopup)
        expandedSelectorConstraints = selectorConstraints(for: sectionSelector)
        compactSelectorConstraints = selectorConstraints(for: sectionPopup)
        NSLayoutConstraint.activate(compactSelectorConstraints)

        let selectorSpacer = NSView()
        selectorSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectorSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [
            titleField, selectorHostView, selectorSpacer
        ])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.distribution = .fill
        headerStack.alignment = .centerY

        protobufImportButton.translatesAutoresizingMaskIntoConstraints = false
        protobufImportButton.controlSize = .small
        protobufImportButton.bezelStyle = .rounded
        protobufImportButton.target = self
        protobufImportButton.action = #selector(importProtobufDescriptor)
        protobufImportButton.toolTip = "Import a compiled Protobuf FileDescriptorSet"
        protobufImportButton.setAccessibilityIdentifier(
            "\(accessibilityPrefix).protobuf.import"
        )
        protobufImportButton.setAccessibilityLabel("Import Protobuf descriptor set")
        protobufImportButton.setContentHuggingPriority(.required, for: .horizontal)

        protobufDescriptorField.translatesAutoresizingMaskIntoConstraints = false
        protobufDescriptorField.font = .systemFont(ofSize: 10)
        protobufDescriptorField.textColor = .secondaryLabelColor
        protobufDescriptorField.lineBreakMode = .byTruncatingMiddle
        protobufDescriptorField.maximumNumberOfLines = 1
        protobufDescriptorField.setAccessibilityIdentifier(
            "\(accessibilityPrefix).protobuf.descriptor"
        )
        protobufDescriptorField.setAccessibilityLabel("Imported Protobuf descriptor")
        protobufDescriptorField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        protobufDescriptorField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        protobufMessageTypePopup.translatesAutoresizingMaskIntoConstraints = false
        protobufMessageTypePopup.controlSize = .small
        protobufMessageTypePopup.target = self
        protobufMessageTypePopup.action = #selector(protobufMessageTypeChanged)
        protobufMessageTypePopup.setAccessibilityIdentifier(
            "\(accessibilityPrefix).protobuf.messageType"
        )
        protobufMessageTypePopup.setAccessibilityLabel("Protobuf message type")
        protobufMessageTypePopup.toolTip = "Choose the root message type for this payload"
        protobufMessageTypePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        protobufMessageTypePopup.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        protobufToolbar.translatesAutoresizingMaskIntoConstraints = false
        protobufToolbar.orientation = .horizontal
        protobufToolbar.spacing = 6
        protobufToolbar.alignment = .centerY
        protobufToolbar.addArrangedSubview(protobufImportButton)
        protobufToolbar.addArrangedSubview(protobufDescriptorField)
        protobufToolbar.addArrangedSubview(protobufMessageTypePopup)
        protobufToolbar.isHidden = true

        let chromeStack = NSStackView(views: [headerStack, protobufToolbar])
        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        chromeStack.orientation = .vertical
        chromeStack.spacing = 5
        chromeStack.alignment = .leading

        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityIdentifier("\(accessibilityPrefix).content")
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.documentView = textView
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.borderType = .noBorder

        let container = NSView()
        container.setAccessibilityIdentifier(accessibilityPrefix)
        container.addSubview(chromeStack)
        NSLayoutConstraint.activate([
            chromeStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            chromeStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            chromeStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            headerStack.widthAnchor.constraint(equalTo: chromeStack.widthAnchor),
            protobufToolbar.widthAnchor.constraint(lessThanOrEqualTo: chromeStack.widthAnchor),
            protobufMessageTypePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])

        // Only one of these fills the region under the chrome at a time. A hidden view still takes
        // part in Auto Layout, so leaving them all pinned lets the one with the smallest fitting
        // height dictate the region and pushes the chrome into the leftover space. Constraints are
        // therefore activated for the visible view alone.
        contentViews = [contentScrollView, jsonTreeView, jsonPathView, imagePreviewView]
        for contentView in contentViews {
            container.addSubview(contentView)
            contentView.isHidden = true
            contentConstraints[ObjectIdentifier(contentView)] = [
                contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: chromeStack.bottomAnchor, constant: 8),
                contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ]
        }
        view = container
        showContentView(contentScrollView)
    }

    /// Makes `contentView` the only content view participating in the layout of the region below
    /// the chrome.
    private func showContentView(_ contentView: NSView) {
        for candidate in contentViews where candidate !== contentView {
            NSLayoutConstraint.deactivate(contentConstraints[ObjectIdentifier(candidate)] ?? [])
            candidate.isHidden = true
        }
        NSLayoutConstraint.activate(contentConstraints[ObjectIdentifier(contentView)] ?? [])
        contentView.isHidden = false
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        let horizontalInsets: CGFloat = 24
        let requiredWidth =
            titleField.fittingSize.width + expandedSelectorWidth + horizontalInsets
        setUsesCompactSelector(view.bounds.width < requiredWidth)
    }

    private func selectorConstraints(for control: NSControl) -> [NSLayoutConstraint] {
        [
            control.leadingAnchor.constraint(equalTo: selectorHostView.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: selectorHostView.trailingAnchor),
            control.topAnchor.constraint(equalTo: selectorHostView.topAnchor),
            control.bottomAnchor.constraint(equalTo: selectorHostView.bottomAnchor)
        ]
    }

    private func setUsesCompactSelector(_ compact: Bool) {
        guard compact != usesCompactSelector else {
            return
        }

        NSLayoutConstraint.deactivate(
            usesCompactSelector ? compactSelectorConstraints : expandedSelectorConstraints
        )
        usesCompactSelector = compact
        sectionSelector.isHidden = compact
        sectionPopup.isHidden = !compact
        NSLayoutConstraint.activate(
            compact ? compactSelectorConstraints : expandedSelectorConstraints
        )
    }

    func display(
        _ content: String,
        language: InspectorSyntaxHighlighter.Language = .plainText,
        highlightedRange: NSRange? = nil,
        isEditable: Bool,
        isSelectorEnabled: Bool,
        protobufSchema: TrafficProtobufSchemaInspection? = nil
    ) {
        isUpdatingContent = true
        showContentView(contentScrollView)
        textView.textStorage?.setAttributedString(
            InspectorSyntaxHighlighter.highlight(
                content,
                as: language,
                in: highlightedRange
            )
        )
        textView.isEditable = isEditable
        sectionSelector.isEnabled = isSelectorEnabled
        sectionPopup.isEnabled = isSelectorEnabled
        updateProtobufToolbar(protobufSchema)
        displayedSection = selectedSection
        textView.scrollToBeginningOfDocument(nil)
        isUpdatingContent = false
    }

    func displayTree(
        _ presentation: TrafficJSONTreePresentation,
        isSelectorEnabled: Bool
    ) {
        isUpdatingContent = true
        textView.isEditable = false
        showContentView(jsonTreeView)
        protobufToolbar.isHidden = true
        jsonTreeView.display(presentation)
        sectionSelector.isEnabled = isSelectorEnabled
        sectionPopup.isEnabled = isSelectorEnabled
        displayedSection = selectedSection
        isUpdatingContent = false
    }

    func displayJSONPath(
        _ presentation: TrafficBodyPresentation,
        isSelectorEnabled: Bool
    ) {
        isUpdatingContent = true
        textView.isEditable = false
        showContentView(jsonPathView)
        protobufToolbar.isHidden = true
        jsonPathView.display(presentation)
        sectionSelector.isEnabled = isSelectorEnabled
        sectionPopup.isEnabled = isSelectorEnabled
        displayedSection = selectedSection
        isUpdatingContent = false
    }

    func displayImage(
        _ presentation: TrafficImagePresentation,
        isSelectorEnabled: Bool
    ) {
        isUpdatingContent = true
        textView.isEditable = false
        showContentView(imagePreviewView)
        protobufToolbar.isHidden = true
        imagePreviewView.display(presentation)
        sectionSelector.isEnabled = isSelectorEnabled
        sectionPopup.isEnabled = isSelectorEnabled
        displayedSection = selectedSection
        isUpdatingContent = false
    }

    @objc private func selectionChanged(_ sender: Any?) {
        sectionPopup.selectItem(at: sectionSelector.selectedSegment)
        onSelectionChange?(self)
    }

    @objc private func compactSelectionChanged(_ sender: Any?) {
        sectionSelector.selectedSegment = sectionPopup.indexOfSelectedItem
        onSelectionChange?(self)
    }

    @objc private func importProtobufDescriptor(_ sender: Any?) {
        onProtobufImport?()
    }

    @objc private func protobufMessageTypeChanged(_ sender: Any?) {
        let index = protobufMessageTypePopup.indexOfSelectedItem
        onProtobufMessageTypeChange?(
            index <= 0 ? nil : protobufMessageTypePopup.titleOfSelectedItem)
    }

    private func updateProtobufToolbar(
        _ schema: TrafficProtobufSchemaInspection?
    ) {
        guard let schema else {
            protobufToolbar.isHidden = true
            return
        }

        protobufToolbar.isHidden = false
        protobufDescriptorField.stringValue = schema.descriptorName ?? "No descriptor"
        protobufDescriptorField.toolTip = schema.descriptorName
        let titles = ["Schema-less"] + schema.messageTypeNames
        if protobufMessageTypePopup.itemTitles != titles {
            protobufMessageTypePopup.removeAllItems()
            protobufMessageTypePopup.addItems(withTitles: titles)
        }
        if let selected = schema.selectedMessageType,
            let index = titles.firstIndex(of: selected)
        {
            protobufMessageTypePopup.selectItem(at: index)
        } else {
            protobufMessageTypePopup.selectItem(at: 0)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingContent, textView.isEditable else {
            return
        }
        onTextChange?(self)
    }
}
