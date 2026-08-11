import AppKit

@MainActor
final class InspectorViewController: NSViewController {
    private let titleField = NSTextField(labelWithString: "No Flow Selected")
    private let messageSelector = NSSegmentedControl(
        labels: ["Request", "Response"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sectionSelector = NSSegmentedControl(
        labels: ["Headers", "Body"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let textView = NSTextView()
    private var inspection = TrafficFlowInspection.empty

    override func loadView() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1

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

        let selectorStack = NSStackView(views: [messageSelector, sectionSelector])
        selectorStack.translatesAutoresizingMaskIntoConstraints = false
        selectorStack.orientation = .horizontal
        selectorStack.spacing = 8
        selectorStack.distribution = .fillEqually

        let container = NSView()
        container.addSubview(titleField)
        container.addSubview(selectorStack)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
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
        inspection = snapshot.inspection
        titleField.stringValue = inspection.title
        messageSelector.isEnabled = inspection.request != nil
        messageSelector.setEnabled(inspection.response != nil, forSegment: 1)
        sectionSelector.isEnabled = inspection.request != nil
        if inspection.response == nil, messageSelector.selectedSegment == 1 {
            messageSelector.selectedSegment = 0
        }
        updateContent()
    }

    @objc private func selectionChanged(_ sender: Any?) {
        updateContent()
    }

    private func updateContent() {
        guard let message = selectedMessage else {
            textView.string = "Select a captured flow to inspect its request and response."
            return
        }
        if sectionSelector.selectedSegment == 0 {
            textView.string = message.headers
        } else {
            textView.string = Self.bodyText(message.body)
        }
        textView.scrollToBeginningOfDocument(nil)
    }

    private var selectedMessage: TrafficMessageInspection? {
        messageSelector.selectedSegment == 1 ? inspection.response : inspection.request
    }

    private static func bodyText(_ body: TrafficBodyPresentation) -> String {
        switch body {
        case .none(let message):
            return message
        case .loading(let metadata):
            return "\(metadata)\n\nLoading captured bytes…"
        case .content(let metadata, let value):
            return "\(metadata)\n\n\(value)"
        case .failed(let metadata, let message):
            return "\(metadata)\n\nUnable to read captured bytes:\n\(message)"
        }
    }
}
