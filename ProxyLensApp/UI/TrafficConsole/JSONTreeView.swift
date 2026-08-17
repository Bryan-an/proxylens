import AppKit

@MainActor
final class JSONTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Column {
        static let key = NSUserInterfaceItemIdentifier("JSONTree.Key")
        static let value = NSUserInterfaceItemIdentifier("JSONTree.Value")
    }

    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let messageField = NSTextField(labelWithString: "")
    private var root: TrafficJSONTreeNode?

    init(accessibilityIdentifier: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        configureOutlineView(accessibilityIdentifier: accessibilityIdentifier)
        configureMessageField()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        addSubview(scrollView)
        addSubview(messageField)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            messageField.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ presentation: TrafficJSONTreePresentation) {
        switch presentation {
        case .content(let root):
            self.root = root
            messageField.stringValue = ""
            messageField.isHidden = true
            scrollView.isHidden = false
            outlineView.reloadData()
            outlineView.expandItem(root)
            for child in root.children where child.isExpandable {
                outlineView.expandItem(child)
            }
            outlineView.scrollRowToVisible(0)
        case .none(let message), .loading(let message), .failed(let message):
            root = nil
            outlineView.reloadData()
            messageField.stringValue = message
            messageField.isHidden = false
            scrollView.isHidden = true
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let item else {
            return root == nil ? 0 : 1
        }
        return (item as? TrafficJSONTreeNode)?.children.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        if let item = item as? TrafficJSONTreeNode {
            return item.children[index]
        }
        guard let root else {
            preconditionFailure("The outline view requested a missing JSON root node.")
        }
        return root
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TrafficJSONTreeNode)?.isExpandable == true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? TrafficJSONTreeNode,
            let tableColumn
        else {
            return nil
        }

        let identifier = tableColumn.identifier
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        guard let textField = cell.textField else {
            return cell
        }

        if identifier == Column.key {
            textField.stringValue = node.key
            textField.textColor =
                if node.kind == .notice {
                    .secondaryLabelColor
                } else if node.identity == 0 {
                    .labelColor
                } else {
                    InspectorSyntaxPalette.key
                }
        } else {
            textField.stringValue = node.value
            textField.textColor = color(for: node.kind)
        }
        textField.toolTip = textField.stringValue
        return cell
    }

    private func configureOutlineView(accessibilityIdentifier: String) {
        let keyColumn = NSTableColumn(identifier: Column.key)
        keyColumn.title = "Key"
        keyColumn.minWidth = 120
        keyColumn.width = 240
        keyColumn.resizingMask = .autoresizingMask

        let valueColumn = NSTableColumn(identifier: Column.value)
        valueColumn.title = "Value"
        valueColumn.minWidth = 160
        valueColumn.width = 420
        valueColumn.resizingMask = .autoresizingMask

        outlineView.addTableColumn(keyColumn)
        outlineView.addTableColumn(valueColumn)
        outlineView.outlineTableColumn = keyColumn
        outlineView.headerView = NSTableHeaderView()
        outlineView.rowHeight = 21
        outlineView.rowSizeStyle = .small
        outlineView.indentationPerLevel = 14
        outlineView.intercellSpacing = NSSize(width: 8, height: 1)
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier(accessibilityIdentifier)
        outlineView.setAccessibilityLabel("JSON tree")
    }

    private func configureMessageField() {
        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageField.textColor = .secondaryLabelColor
        messageField.lineBreakMode = .byWordWrapping
        messageField.maximumNumberOfLines = 0
        messageField.isSelectable = true
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.isSelectable = true
        cell.textField = textField
        cell.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func color(for kind: TrafficJSONTreeValueKind) -> NSColor {
        switch kind {
        case .container:
            return .secondaryLabelColor
        case .string:
            return InspectorSyntaxPalette.string
        case .number:
            return InspectorSyntaxPalette.number
        case .literal:
            return InspectorSyntaxPalette.literal
        case .notice:
            return .secondaryLabelColor
        }
    }
}
