import AppKit
import ProxyLensCore

@MainActor
final class InspectorViewController: NSViewController, NSTextViewDelegate {
    private let viewModel: TrafficConsoleViewModel?
    private let titleField = NSTextField(labelWithString: "No Flow Selected")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private let messageSelector = NSSegmentedControl(
        labels: ["Request", "Response", "Rules"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sectionSelector = NSSegmentedControl(
        labels: ["Headers", "Body", "JSON"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let textView = NSTextView()
    private var inspection = TrafficFlowInspection.empty
    private var editedHeaders: [Int: String] = [:]
    private var editedBodies: [Int: String] = [:]
    private var hasUserEdits = false
    private var displayedMessageSegment = 0
    private var displayedSectionSegment = 0

    init(viewModel: TrafficConsoleViewModel? = nil) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        messageSelector.translatesAutoresizingMaskIntoConstraints = false
        messageSelector.selectedSegment = 0
        messageSelector.target = self
        messageSelector.action = #selector(selectionChanged)
        messageSelector.setAccessibilityIdentifier("inspector.message")

        sectionSelector.translatesAutoresizingMaskIntoConstraints = false
        sectionSelector.selectedSegment = 0
        sectionSelector.target = self
        sectionSelector.action = #selector(selectionChanged)
        sectionSelector.setAccessibilityIdentifier("inspector.section")

        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityIdentifier("inspector.content")
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

        let breakpointStack = NSStackView(views: [continueButton, abortButton])
        breakpointStack.translatesAutoresizingMaskIntoConstraints = false
        breakpointStack.orientation = .horizontal
        breakpointStack.spacing = 8
        breakpointStack.alignment = .centerY

        messageSelector.setContentHuggingPriority(.required, for: .horizontal)
        sectionSelector.setContentHuggingPriority(.required, for: .horizontal)

        let selectorSpacer = NSView()
        selectorSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectorSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let selectorStack = NSStackView(
            views: [messageSelector, sectionSelector, selectorSpacer]
        )
        selectorStack.translatesAutoresizingMaskIntoConstraints = false
        selectorStack.orientation = .horizontal
        selectorStack.spacing = 8
        selectorStack.distribution = .fill

        let container = NSView()
        container.addSubview(titleField)
        container.addSubview(breakpointStack)
        container.addSubview(selectorStack)
        container.addSubview(scrollView)
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
            selectorStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            selectorStack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -10),
            selectorStack.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: selectorStack.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
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
        titleField.stringValue = inspection.title
        let isPaused = inspection.breakpoint != nil
        continueButton.isHidden = !isPaused
        abortButton.isHidden = !isPaused
        continueButton.isEnabled = isPaused
        abortButton.isEnabled = isPaused
        messageSelector.isEnabled = inspection.flowID != nil
        messageSelector.setEnabled(inspection.request != nil, forSegment: 0)
        messageSelector.setEnabled(inspection.response != nil, forSegment: 1)
        messageSelector.setEnabled(inspection.flowID != nil, forSegment: 2)
        sectionSelector.isEnabled =
            inspection.request != nil && messageSelector.selectedSegment != 2
        if inspection.response == nil, messageSelector.selectedSegment == 1 {
            messageSelector.selectedSegment = 0
        }
        if previousBreakpoint == nil, let breakpoint = inspection.breakpoint {
            messageSelector.selectedSegment = breakpoint.phase == .response ? 1 : 0
        }
        if hasUserEdits, previousFlowID == inspection.flowID {
            updateEditingState()
            return
        }
        updateContent()
    }

    @objc private func selectionChanged(_ sender: Any?) {
        saveCurrentEdits()
        updateContent()
    }

    func textDidChange(_ notification: Notification) {
        guard textView.isEditable else {
            return
        }
        hasUserEdits = true
        saveCurrentEdits()
    }

    private func updateContent() {
        sectionSelector.isEnabled = inspection.flowID != nil && messageSelector.selectedSegment != 2
        defer { rememberDisplayedSelection() }
        if messageSelector.selectedSegment == 2 {
            textView.string = inspection.rules
            textView.isEditable = false
            textView.scrollToBeginningOfDocument(nil)
            return
        }
        guard let message = selectedMessage else {
            textView.string = "Select a captured flow to inspect its request and response."
            textView.isEditable = false
            return
        }
        if sectionSelector.selectedSegment == 0 {
            textView.string =
                editedHeaders[messageSelector.selectedSegment] ?? message.headers
        } else if sectionSelector.selectedSegment == 2 {
            textView.string = Self.bodyText(message.json, editable: false)
        } else if let editedBody = editedBodies[messageSelector.selectedSegment] {
            textView.string = editedBody
        } else {
            textView.string = Self.bodyText(message.body, editable: isEditingCurrentMessage)
        }
        updateEditingState()
        textView.scrollToBeginningOfDocument(nil)
    }

    private func updateEditingState() {
        textView.isEditable = isEditingCurrentSection
    }

    private func rememberDisplayedSelection() {
        displayedMessageSegment = messageSelector.selectedSegment
        displayedSectionSegment = sectionSelector.selectedSegment
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

    private var selectedMessage: TrafficMessageInspection? {
        messageSelector.selectedSegment == 1 ? inspection.response : inspection.request
    }

    private var isEditingCurrentMessage: Bool {
        isEditingMessage(messageSelector.selectedSegment)
    }

    private var isEditingCurrentSection: Bool {
        guard isEditingCurrentMessage, messageSelector.selectedSegment != 2 else {
            return false
        }
        if sectionSelector.selectedSegment == 0 {
            return true
        }
        if sectionSelector.selectedSegment == 1 {
            return inspection.breakpoint?.canEditBody == true
        }
        return false
    }

    private func saveCurrentEdits() {
        guard isEditingMessage(displayedMessageSegment), displayedMessageSegment != 2 else {
            return
        }
        if displayedSectionSegment == 0 {
            editedHeaders[displayedMessageSegment] = textView.string
        } else if displayedSectionSegment == 1, inspection.breakpoint?.canEditBody == true {
            editedBodies[displayedMessageSegment] = textView.string
        }
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
}
