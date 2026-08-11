import AppKit

@MainActor
final class SourceListViewController: NSViewController, NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    private let viewModel: TrafficConsoleViewModel
    private let outlineView = NSOutlineView()
    private var roots: [SourceOutlineNode] = []
    private var isRendering = false

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.title = "Sources"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("traffic.sources")

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    func render(_ snapshot: TrafficConsoleSnapshot) {
        isRendering = true
        defer { isRendering = false }

        let allTraffic = SourceOutlineNode(
            id: "all-traffic",
            title: "All Traffic",
            count: snapshot.allFlowCount,
            symbolName: "tray.full",
            selection: .allTraffic
        )
        let domains = SourceOutlineNode(
            id: "domains",
            title: "Domains",
            count: snapshot.domains.count,
            symbolName: "globe",
            selection: nil,
            children: snapshot.domains.map {
                SourceOutlineNode(
                    id: "domain:\($0.host)",
                    title: $0.host,
                    count: $0.flowCount,
                    symbolName: "network",
                    selection: .domain($0.host)
                )
            }
        )
        roots = [allTraffic, domains]
        outlineView.reloadData()
        outlineView.expandItem(domains)

        let nodes = roots.flatMap { root in
            [root] + root.children
        }
        if let node = nodes.first(where: { $0.selection == snapshot.selectedSource }) {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        (item as? SourceOutlineNode)?.children.count ?? roots.count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        (item as? SourceOutlineNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SourceOutlineNode else {
            return false
        }
        return !node.children.isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? SourceOutlineNode else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("SourceCell")
        let cell =
            (outlineView.makeView(withIdentifier: identifier, owner: self) as? SourceCellView)
            ?? SourceCellView(identifier: identifier)
        cell.render(title: node.title, count: node.count, symbolName: node.symbolName)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SourceOutlineNode)?.selection != nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRendering,
            outlineView.selectedRow >= 0,
            let node = outlineView.item(atRow: outlineView.selectedRow) as? SourceOutlineNode,
            let selection = node.selection
        else {
            return
        }
        viewModel.selectSource(selection)
    }
}

@MainActor
private final class SourceOutlineNode: NSObject {
    let id: String
    let title: String
    let count: Int
    let symbolName: String
    let selection: TrafficSourceSelection?
    let children: [SourceOutlineNode]

    init(
        id: String,
        title: String,
        count: Int,
        symbolName: String,
        selection: TrafficSourceSelection?,
        children: [SourceOutlineNode] = []
    ) {
        self.id = id
        self.title = title
        self.count = count
        self.symbolName = symbolName
        self.selection = selection
        self.children = children
    }
}

@MainActor
private final class SourceCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .regular)
        symbolView.contentTintColor = .secondaryLabelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingMiddle
        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.textColor = .secondaryLabelColor
        countField.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)

        addSubview(symbolView)
        addSubview(titleField)
        addSubview(countField)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor, constant: 6),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(title: String, count: Int, symbolName: String) {
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        titleField.stringValue = title
        countField.stringValue = count.formatted()
    }
}
