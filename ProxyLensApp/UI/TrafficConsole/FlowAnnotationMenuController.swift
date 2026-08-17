import AppKit
import ProxyLensCore

@MainActor
final class FlowAnnotationMenuController: NSObject {
    private let viewModel: TrafficConsoleViewModel
    private let windowProvider: () -> NSWindow?

    init(
        viewModel: TrafficConsoleViewModel,
        windowProvider: @escaping () -> NSWindow?
    ) {
        self.viewModel = viewModel
        self.windowProvider = windowProvider
    }

    func appendItems(to menu: NSMenu, for row: TrafficFlowRow) {
        let target = FlowAnnotationMenuTarget(flowID: row.id, annotation: row.annotation)
        let commentItem = NSMenuItem(
            title: row.annotation?.comment == nil ? "Add Comment…" : "Edit Comment…",
            action: #selector(editComment),
            keyEquivalent: ""
        )
        commentItem.target = self
        commentItem.representedObject = target
        menu.addItem(commentItem)

        let highlightItem = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        let highlightMenu = NSMenu(title: "Highlight")
        highlightMenu.addItem(highlightMenuItem(title: "None", color: nil, target: target))
        for color in FlowHighlightColor.allCases {
            highlightMenu.addItem(
                highlightMenuItem(title: color.menuTitle, color: color, target: target)
            )
        }
        highlightItem.submenu = highlightMenu
        menu.addItem(highlightItem)

        let strikeItem = NSMenuItem(
            title: "Strikethrough",
            action: #selector(toggleStrikethrough),
            keyEquivalent: ""
        )
        strikeItem.target = self
        strikeItem.representedObject = target
        strikeItem.state = row.annotation?.isStruckThrough == true ? .on : .off
        menu.addItem(strikeItem)

        if row.annotation != nil {
            let clearItem = NSMenuItem(
                title: "Clear Annotation",
                action: #selector(clearAnnotation),
                keyEquivalent: ""
            )
            clearItem.target = self
            clearItem.representedObject = target
            menu.addItem(clearItem)
        }
    }

    private func highlightMenuItem(
        title: String,
        color: FlowHighlightColor?,
        target: FlowAnnotationMenuTarget
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setHighlight), keyEquivalent: "")
        item.target = self
        item.representedObject = FlowHighlightMenuTarget(
            flowID: target.flowID,
            annotation: target.annotation,
            highlight: color
        )
        item.state = target.annotation?.highlight == color ? .on : .off
        if let color {
            item.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "\(title) highlight"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [color.interfaceColor])
            )
        }
        return item
    }

    @objc private func editComment(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FlowAnnotationMenuTarget else {
            return
        }
        Task { @MainActor in
            await presentCommentEditor(target)
        }
    }

    private func presentCommentEditor(_ target: FlowAnnotationMenuTarget) async {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 430, height: 96))
        textView.string = target.annotation?.comment ?? ""
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.setAccessibilityIdentifier("traffic.annotation.comment.editor")

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = target.annotation?.comment == nil ? "Add Comment" : "Edit Comment"
        alert.informativeText = "Comments are stored locally with this captured flow."
        alert.addButton(withTitle: "Save")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        let response: NSApplication.ModalResponse
        if let window = windowProvider() {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else {
            return
        }

        await updateAnnotation(for: target) { annotation in
            try FlowAnnotation(
                comment: textView.string,
                highlight: annotation?.highlight,
                isStruckThrough: annotation?.isStruckThrough ?? false
            )
        }
    }

    @objc private func setHighlight(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FlowHighlightMenuTarget else {
            return
        }
        Task { @MainActor in
            await updateAnnotation(for: target) { annotation in
                try FlowAnnotation(
                    comment: annotation?.comment,
                    highlight: target.highlight,
                    isStruckThrough: annotation?.isStruckThrough ?? false
                )
            }
        }
    }

    @objc private func toggleStrikethrough(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FlowAnnotationMenuTarget else {
            return
        }
        Task { @MainActor in
            await updateAnnotation(for: target) { annotation in
                try FlowAnnotation(
                    comment: annotation?.comment,
                    highlight: annotation?.highlight,
                    isStruckThrough: !(annotation?.isStruckThrough ?? false)
                )
            }
        }
    }

    @objc private func clearAnnotation(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FlowAnnotationMenuTarget else {
            return
        }
        Task { @MainActor in
            do {
                try await viewModel.updateAnnotation(nil, for: target.flowID)
            } catch {
                await presentError(error)
            }
        }
    }

    private func updateAnnotation(
        for target: FlowAnnotationMenuTarget,
        transform: (FlowAnnotation?) throws -> FlowAnnotation
    ) async {
        do {
            let annotation = try transform(target.annotation)
            try await viewModel.updateAnnotation(
                annotation.isEmpty ? nil : annotation,
                for: target.flowID
            )
        } catch {
            await presentError(error)
        }
    }

    private func presentError(_ error: Error) async {
        let alert = NSAlert(error: error)
        if let window = windowProvider() {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private class FlowAnnotationMenuTarget: NSObject {
    let flowID: FlowID
    let annotation: FlowAnnotation?

    init(flowID: FlowID, annotation: FlowAnnotation?) {
        self.flowID = flowID
        self.annotation = annotation
    }
}

private final class FlowHighlightMenuTarget: FlowAnnotationMenuTarget {
    let highlight: FlowHighlightColor?

    init(flowID: FlowID, annotation: FlowAnnotation?, highlight: FlowHighlightColor?) {
        self.highlight = highlight
        super.init(flowID: flowID, annotation: annotation)
    }
}

extension FlowHighlightColor {
    var menuTitle: String {
        rawValue.capitalized
    }

    var interfaceColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
}

@MainActor
final class FlowAnnotationTableRowView: NSTableRowView {
    private var highlightColor: NSColor?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ annotation: FlowAnnotation?) {
        highlightColor = annotation?.highlight?.interfaceColor
        needsDisplay = true
        setAccessibilityHelp(annotation?.comment)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard !isSelected, let highlightColor else {
            return
        }
        highlightColor.withAlphaComponent(0.16).setFill()
        dirtyRect.fill()
    }
}
