import AppKit

@MainActor
final class FlowComparisonViewController: NSViewController {
    private enum Side {
        case left
        case right
    }

    private let comparison: TrafficFlowComparison
    private let messageSelector = NSSegmentedControl(
        labels: ["Request", "Response"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let presentationSelector = NSSegmentedControl(
        labels: ["Side by Side", "Unified"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let summaryLabel = NSTextField(labelWithString: "")
    private let leftTitleLabel = NSTextField(labelWithString: "")
    private let rightTitleLabel = NSTextField(labelWithString: "")
    private let leftTextView = NSTextView()
    private let rightTextView = NSTextView()
    private let leftScrollView = NSScrollView()
    private let rightScrollView = NSScrollView()
    private let unifiedTextView = NSTextView()
    private let unifiedScrollView = NSScrollView()
    private let splitView = NSSplitView()
    private var isSynchronizingScroll = false

    init(comparison: TrafficFlowComparison) {
        self.comparison = comparison
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 1_100, height: 680)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("flowComparison")

        let title = NSTextField(labelWithString: "Compare Flows")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Review aligned request or response lines. Red is the first flow; green is the second."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor

        messageSelector.translatesAutoresizingMaskIntoConstraints = false
        messageSelector.target = self
        messageSelector.action = #selector(messageSelectionChanged)
        messageSelector.selectedSegment = 0
        messageSelector.setAccessibilityIdentifier("flowComparison.message")

        presentationSelector.translatesAutoresizingMaskIntoConstraints = false
        presentationSelector.target = self
        presentationSelector.action = #selector(presentationSelectionChanged)
        presentationSelector.selectedSegment = 0
        presentationSelector.setAccessibilityIdentifier("flowComparison.presentation")

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right

        configureTitleLabel(leftTitleLabel, title: comparison.leftTitle)
        configureTitleLabel(rightTitleLabel, title: comparison.rightTitle)
        configureTextView(leftTextView, accessibilityIdentifier: "flowComparison.left")
        configureTextView(rightTextView, accessibilityIdentifier: "flowComparison.right")
        configureTextView(unifiedTextView, accessibilityIdentifier: "flowComparison.unified")
        configureScrollView(leftScrollView, documentView: leftTextView)
        configureScrollView(rightScrollView, documentView: rightTextView)
        configureScrollView(unifiedScrollView, documentView: unifiedTextView)

        let leftPane = comparisonPane(title: leftTitleLabel, scrollView: leftScrollView)
        let rightPane = comparisonPane(title: rightTitleLabel, scrollView: rightScrollView)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setPosition(preferredContentSize.width / 2, ofDividerAt: 0)

        let copyButton = NSButton(title: "Copy Diff", target: self, action: #selector(copyDiff))
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .rounded
        copyButton.setAccessibilityIdentifier("flowComparison.copy")

        let exportButton = NSButton(
            title: "Export Diff…",
            target: self,
            action: #selector(exportDiff)
        )
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .rounded
        exportButton.setAccessibilityIdentifier("flowComparison.export")

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("flowComparison.close")

        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(messageSelector)
        container.addSubview(presentationSelector)
        container.addSubview(summaryLabel)
        container.addSubview(splitView)
        container.addSubview(unifiedScrollView)
        container.addSubview(copyButton)
        container.addSubview(exportButton)
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            messageSelector.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            messageSelector.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            presentationSelector.leadingAnchor.constraint(
                equalTo: messageSelector.trailingAnchor, constant: 8),
            presentationSelector.centerYAnchor.constraint(equalTo: messageSelector.centerYAnchor),
            summaryLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: presentationSelector.trailingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            summaryLabel.centerYAnchor.constraint(equalTo: messageSelector.centerYAnchor),
            splitView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: messageSelector.bottomAnchor, constant: 12),
            splitView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -16),
            unifiedScrollView.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
            unifiedScrollView.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
            unifiedScrollView.topAnchor.constraint(equalTo: splitView.topAnchor),
            unifiedScrollView.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
            copyButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            exportButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 8),
            exportButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        leftScrollView.contentView.postsBoundsChangedNotifications = true
        rightScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: leftScrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: rightScrollView.contentView
        )

        view = container
        renderSelectedMessage()
    }

    private func configureTitleLabel(_ label: NSTextField, title: String) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = title
    }

    private func configureTextView(_ textView: NSTextView, accessibilityIdentifier: String) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    private func configureScrollView(_ scrollView: NSScrollView, documentView: NSTextView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = documentView
    }

    private func comparisonPane(title: NSTextField, scrollView: NSScrollView) -> NSView {
        let pane = NSView()
        pane.addSubview(title)
        pane.addSubview(scrollView)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
        return pane
    }

    @objc private func messageSelectionChanged() {
        renderSelectedMessage()
    }

    @objc private func presentationSelectionChanged() {
        updatePresentation()
    }

    private func renderSelectedMessage() {
        let message =
            messageSelector.selectedSegment == 1
            ? comparison.response
            : comparison.request
        leftTextView.textStorage?.setAttributedString(
            Self.attributedText(for: message.rows, side: .left)
        )
        rightTextView.textStorage?.setAttributedString(
            Self.attributedText(for: message.rows, side: .right)
        )
        unifiedTextView.textStorage?.setAttributedString(
            Self.attributedUnifiedText(unifiedDiffText())
        )
        let count = message.changedRowCount
        summaryLabel.stringValue = count == 1 ? "1 changed row" : "\(count) changed rows"
        leftScrollView.contentView.scroll(to: .zero)
        rightScrollView.contentView.scroll(to: .zero)
        unifiedScrollView.contentView.scroll(to: .zero)
        updatePresentation()
    }

    private func updatePresentation() {
        let showsUnified = presentationSelector.selectedSegment == 1
        splitView.isHidden = showsUnified
        unifiedScrollView.isHidden = !showsUnified
    }

    private func unifiedDiffText() -> String {
        let isResponse = messageSelector.selectedSegment == 1
        return TrafficUnifiedDiff.text(
            leftTitle: comparison.leftTitle,
            rightTitle: comparison.rightTitle,
            sectionTitle: isResponse ? "Response" : "Request",
            comparison: isResponse ? comparison.response : comparison.request
        )
    }

    private static func attributedText(
        for rows: [TrafficDiffRow],
        side: Side
    ) -> NSAttributedString {
        let lineNumberWidth = max(
            3,
            String(
                rows.compactMap {
                    side == .left ? $0.leftLineNumber : $0.rightLineNumber
                }.max() ?? 0
            ).count
        )
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1

        for (index, row) in rows.enumerated() {
            let lineNumber = side == .left ? row.leftLineNumber : row.rightLineNumber
            let content = side == .left ? row.leftText : row.rightText
            let number = lineNumber.map(String.init) ?? ""
            let padding = String(repeating: " ", count: max(0, lineNumberWidth - number.count))
            let prefix = "\(padding)\(number) │ "
            let line = "\(prefix)\(content ?? "")\(index == rows.count - 1 ? "" : "\n")"
            let attributedLine = NSMutableAttributedString(
                string: line,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraph
                ]
            )
            attributedLine.addAttribute(
                .foregroundColor,
                value: NSColor.tertiaryLabelColor,
                range: NSRange(location: 0, length: prefix.utf16.count)
            )
            if let background = backgroundColor(for: row.kind, side: side) {
                attributedLine.addAttribute(
                    .backgroundColor,
                    value: background,
                    range: NSRange(location: 0, length: line.utf16.count)
                )
            }
            result.append(attributedLine)
        }
        return result
    }

    private static func backgroundColor(for kind: TrafficDiffKind, side: Side) -> NSColor? {
        switch (kind, side) {
        case (.modified, .left), (.removed, .left):
            NSColor.systemRed.withAlphaComponent(0.16)
        case (.modified, .right), (.added, .right):
            NSColor.systemGreen.withAlphaComponent(0.16)
        default:
            nil
        }
    }

    private static func attributedUnifiedText(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
        )
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: .byLines
        ) { line, lineRange, _, _ in
            guard let line else {
                return
            }
            let range = NSRange(lineRange, in: text)
            let color: NSColor?
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                color = .systemTeal
            } else if line.hasPrefix("+") {
                color = .systemGreen
            } else if line.hasPrefix("-") {
                color = .systemRed
            } else {
                color = nil
            }
            if let color {
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        return result
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isSynchronizingScroll, let source = notification.object as? NSClipView else {
            return
        }
        let destination: NSClipView
        if source === leftScrollView.contentView {
            destination = rightScrollView.contentView
        } else if source === rightScrollView.contentView {
            destination = leftScrollView.contentView
        } else {
            return
        }

        isSynchronizingScroll = true
        destination.scroll(to: source.bounds.origin)
        destination.enclosingScrollView?.reflectScrolledClipView(destination)
        isSynchronizingScroll = false
    }

    @objc private func close() {
        dismiss(self)
    }

    @objc private func copyDiff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(unifiedDiffText(), forType: .string)
    }

    @objc private func exportDiff() {
        let panel = NSSavePanel()
        let section = messageSelector.selectedSegment == 1 ? "Response" : "Request"
        panel.nameFieldStringValue = "ProxyLens \(section) Comparison.diff"
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else {
                return
            }
            do {
                try Data(self.unifiedDiffText().utf8).write(to: destination, options: .atomic)
            } catch {
                self.presentError(error)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }
}
