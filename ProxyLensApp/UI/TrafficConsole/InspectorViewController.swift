import AppKit
import ProxyLensCore

@MainActor
final class InspectorViewController: NSViewController {
    private let viewModel: TrafficConsoleViewModel?
    private let titleField = NSTextField(labelWithString: "No Flow Selected")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let modeSelector = NSSegmentedControl(
        labels: ["Content", "Rules"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let requestPane = MessageInspectorPaneViewController(
        title: "Request",
        accessibilityPrefix: "inspector.request"
    )
    private let responsePane = MessageInspectorPaneViewController(
        title: "Response",
        accessibilityPrefix: "inspector.response"
    )
    private let contentSplitViewController = NSSplitViewController()
    private let rulesTextView = NSTextView()
    private let rulesScrollView = NSScrollView()
    private var inspection = TrafficFlowInspection.empty
    private var editedHeaders: [Int: String] = [:]
    private var editedBodies: [Int: String] = [:]
    private var hasUserEdits = false
    private var didSetInitialContentPosition = false

    init(viewModel: TrafficConsoleViewModel? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        configureTitle()
        configureBreakpointControls()
        configureModeSelector()
        configureMessagePanes()
        configureRulesView()

        let breakpointStack = NSStackView(views: [continueButton, abortButton])
        breakpointStack.translatesAutoresizingMaskIntoConstraints = false
        breakpointStack.orientation = .horizontal
        breakpointStack.spacing = 8
        breakpointStack.alignment = .centerY

        let selectorSpacer = NSView()
        selectorSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectorSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let modeStack = NSStackView(views: [modeSelector, selectorSpacer])
        modeStack.translatesAutoresizingMaskIntoConstraints = false
        modeStack.orientation = .horizontal
        modeStack.spacing = 8
        modeStack.distribution = .fill

        let contentSplitView = contentSplitViewController.view
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        addChild(contentSplitViewController)
        container.addSubview(titleField)
        container.addSubview(breakpointStack)
        container.addSubview(modeStack)
        container.addSubview(contentSplitView)
        container.addSubview(rulesScrollView)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(
                equalTo: breakpointStack.leadingAnchor,
                constant: -8
            ),
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            breakpointStack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -10
            ),
            breakpointStack.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            modeStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            modeStack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -10
            ),
            modeStack.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            contentSplitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentSplitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentSplitView.topAnchor.constraint(equalTo: modeStack.bottomAnchor, constant: 8),
            contentSplitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rulesScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rulesScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rulesScrollView.topAnchor.constraint(equalTo: modeStack.bottomAnchor, constant: 8),
            rulesScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
        render(.initial)
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        let splitView = contentSplitViewController.splitView
        guard !didSetInitialContentPosition,
            contentSplitViewController.splitViewItems.count == 2,
            splitView.bounds.width > 0
        else {
            return
        }

        didSetInitialContentPosition = true
        splitView.setPosition(splitView.bounds.width * 0.5, ofDividerAt: 0)
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

        titleField.stringValue = inspection.title
        let isPaused = inspection.breakpoint != nil
        continueButton.isHidden = !isPaused
        abortButton.isHidden = !isPaused
        continueButton.isEnabled = isPaused
        abortButton.isEnabled = isPaused
        modeSelector.isEnabled = inspection.flowID != nil
        if inspection.flowID == nil {
            modeSelector.selectedSegment = 0
        }
        rulesTextView.string = inspection.rules
        updateModeVisibility()

        if hasUserEdits, previousFlowID == inspection.flowID {
            updateEditingState()
            return
        }

        updateMessagePane(requestPane, messageIndex: 0, message: inspection.request)
        updateMessagePane(responsePane, messageIndex: 1, message: inspection.response)
    }

    private func configureTitle() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        modeSelector.target = self
        modeSelector.action = #selector(modeSelectionChanged)
        modeSelector.setAccessibilityIdentifier("inspector.mode")
        modeSelector.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureMessagePanes() {
        requestPane.onSelectionChange = { [weak self] pane in
            self?.selectionChanged(in: pane, messageIndex: 0)
        }
        requestPane.onTextChange = { [weak self] pane in
            self?.textChanged(in: pane, messageIndex: 0)
        }
        responsePane.onSelectionChange = { [weak self] pane in
            self?.selectionChanged(in: pane, messageIndex: 1)
        }
        responsePane.onTextChange = { [weak self] pane in
            self?.textChanged(in: pane, messageIndex: 1)
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
        let showsRules = modeSelector.selectedSegment == 1 && inspection.flowID != nil
        contentSplitViewController.view.isHidden = showsRules
        rulesScrollView.isHidden = !showsRules
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
        if pane.selectedSectionSegment == 0 {
            content = editedHeaders[messageIndex] ?? message.headers
            syntaxLanguage = .httpHeaders
        } else if pane.selectedSectionSegment == 2 {
            content = Self.bodyText(message.json, editable: false)
            highlightedRange = Self.bodyContentRange(message.json, editable: false)
            if highlightedRange != nil {
                syntaxLanguage = .json
            }
        } else if let editedBody = editedBodies[messageIndex] {
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

        pane.display(
            content,
            language: syntaxLanguage,
            highlightedRange: highlightedRange,
            isEditable: isEditingSection(
                pane.selectedSectionSegment,
                messageIndex: messageIndex
            ),
            isSelectorEnabled: true
        )
    }

    private func updateEditingState() {
        requestPane.isContentEditable = isEditingSection(
            requestPane.selectedSectionSegment,
            messageIndex: 0
        )
        responsePane.isContentEditable = isEditingSection(
            responsePane.selectedSectionSegment,
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
        }
    }

    private func isEditingSection(_ sectionIndex: Int, messageIndex: Int) -> Bool {
        guard isEditingMessage(messageIndex) else {
            return false
        }
        if sectionIndex == 0 {
            return true
        }
        if sectionIndex == 1 {
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
        if pane.displayedSectionSegment == 0 {
            editedHeaders[messageIndex] = pane.content
        } else if pane.displayedSectionSegment == 1,
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
        saveCurrentEdits()
        guard let breakpoint = inspection.breakpoint else {
            return
        }
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
}

@MainActor
private final class MessageInspectorPaneViewController: NSViewController, NSTextViewDelegate {
    let paneTitle: String
    let accessibilityPrefix: String
    let sectionSelector = NSSegmentedControl(
        labels: ["Headers", "Body", "JSON"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let textView = NSTextView()
    var onSelectionChange: ((MessageInspectorPaneViewController) -> Void)?
    var onTextChange: ((MessageInspectorPaneViewController) -> Void)?
    private(set) var displayedSectionSegment = 0
    private var isUpdatingContent = false

    var selectedSectionSegment: Int {
        sectionSelector.selectedSegment
    }

    var content: String {
        textView.string
    }

    var isContentEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    init(title: String, accessibilityPrefix: String) {
        self.paneTitle = title
        self.accessibilityPrefix = accessibilityPrefix
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let titleField = NSTextField(labelWithString: paneTitle)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)

        sectionSelector.translatesAutoresizingMaskIntoConstraints = false
        sectionSelector.selectedSegment = 0
        sectionSelector.target = self
        sectionSelector.action = #selector(selectionChanged)
        sectionSelector.setAccessibilityIdentifier("\(accessibilityPrefix).section")
        sectionSelector.setContentHuggingPriority(.required, for: .horizontal)

        let selectorSpacer = NSView()
        selectorSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectorSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [titleField, sectionSelector, selectorSpacer])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.distribution = .fill
        headerStack.alignment = .centerY

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

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let container = NSView()
        container.setAccessibilityIdentifier(accessibilityPrefix)
        container.addSubview(headerStack)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    func display(
        _ content: String,
        language: InspectorSyntaxHighlighter.Language = .plainText,
        highlightedRange: NSRange? = nil,
        isEditable: Bool,
        isSelectorEnabled: Bool
    ) {
        isUpdatingContent = true
        textView.textStorage?.setAttributedString(
            InspectorSyntaxHighlighter.highlight(
                content,
                as: language,
                in: highlightedRange
            )
        )
        textView.isEditable = isEditable
        sectionSelector.isEnabled = isSelectorEnabled
        displayedSectionSegment = sectionSelector.selectedSegment
        textView.scrollToBeginningOfDocument(nil)
        isUpdatingContent = false
    }

    @objc private func selectionChanged(_ sender: Any?) {
        onSelectionChange?(self)
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingContent, textView.isEditable else {
            return
        }
        onTextChange?(self)
    }
}
