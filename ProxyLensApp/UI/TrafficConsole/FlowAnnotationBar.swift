import AppKit
import ProxyLensCore

@MainActor
final class FlowAnnotationBar: NSStackView, NSTextFieldDelegate {
    var saveHandler: ((FlowAnnotation?) async throws -> Void)?

    private let commentField = NSTextField()
    private let highlightPopup = NSPopUpButton()
    private let strikeButton = NSButton(
        checkboxWithTitle: "Strikethrough",
        target: nil,
        action: nil
    )
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var isDirty = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        annotation: FlowAnnotation?,
        hasSelection: Bool,
        resetEdits: Bool
    ) {
        isHidden = !hasSelection
        if resetEdits {
            isDirty = false
        }
        guard hasSelection else {
            return
        }
        if !isDirty {
            apply(annotation)
        }
        saveButton.isEnabled = isDirty
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === commentField else {
            return
        }
        markDirty()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .centerY
        spacing = 7
        let label = NSTextField(labelWithString: "Annotation")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)

        commentField.placeholderString = "Add a local comment…"
        commentField.delegate = self
        commentField.setAccessibilityIdentifier("inspector.annotation.comment")
        commentField.setAccessibilityLabel("Flow comment")
        commentField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        highlightPopup.addItem(withTitle: "No Highlight")
        highlightPopup.addItems(
            withTitles: FlowHighlightColor.allCases.map(\.menuTitle)
        )
        highlightPopup.target = self
        highlightPopup.action = #selector(markDirty)
        highlightPopup.setAccessibilityIdentifier("inspector.annotation.highlight")
        highlightPopup.setAccessibilityLabel("Flow highlight color")
        highlightPopup.setContentHuggingPriority(.required, for: .horizontal)

        strikeButton.target = self
        strikeButton.action = #selector(markDirty)
        strikeButton.setAccessibilityIdentifier("inspector.annotation.strikethrough")
        strikeButton.setContentHuggingPriority(.required, for: .horizontal)

        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveAnnotation)
        saveButton.setAccessibilityIdentifier("inspector.annotation.save")
        saveButton.setAccessibilityLabel("Save flow annotation")
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        addArrangedSubview(label)
        addArrangedSubview(commentField)
        addArrangedSubview(highlightPopup)
        addArrangedSubview(strikeButton)
        addArrangedSubview(saveButton)
        heightAnchor.constraint(equalToConstant: fittingSize.height).isActive = true
    }

    private func apply(_ annotation: FlowAnnotation?) {
        commentField.stringValue = annotation?.comment ?? ""
        let highlightIndex = annotation?.highlight.flatMap {
            FlowHighlightColor.allCases.firstIndex(of: $0)
        }
        highlightPopup.selectItem(at: highlightIndex.map { $0 + 1 } ?? 0)
        strikeButton.state = annotation?.isStruckThrough == true ? .on : .off
    }

    @objc private func markDirty() {
        isDirty = true
        saveButton.isEnabled = true
    }

    @objc private func saveAnnotation() {
        let highlight: FlowHighlightColor? = {
            let index = highlightPopup.indexOfSelectedItem - 1
            return FlowHighlightColor.allCases.indices.contains(index)
                ? FlowHighlightColor.allCases[index]
                : nil
        }()
        saveButton.isEnabled = false

        Task { @MainActor in
            do {
                let annotation = try FlowAnnotation(
                    comment: commentField.stringValue,
                    highlight: highlight,
                    isStruckThrough: strikeButton.state == .on
                )
                let savedAnnotation = annotation.isEmpty ? nil : annotation
                try await saveHandler?(savedAnnotation)
                isDirty = false
                apply(savedAnnotation)
            } catch {
                saveButton.isEnabled = true
                let alert = NSAlert(error: error)
                if let window {
                    await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}
