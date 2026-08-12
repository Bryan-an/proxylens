import AppKit
import Combine

@MainActor
final class TrafficConsoleViewController: NSViewController {
    private let viewModel: TrafficConsoleViewModel
    private let sourceController: SourceListViewController
    private let flowController: FlowTableViewController
    private let inspectorController = InspectorViewController()
    private let splitViewController = NSSplitViewController()
    private let captureButton = NSButton()
    private let statusImage = NSImageView()
    private let statusField = NSTextField(labelWithString: "Preparing capture…")
    private lazy var filterBar = TrafficFilterBar(viewModel: viewModel)
    private var snapshotCancellable: AnyCancellable?

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        self.sourceController = SourceListViewController(viewModel: viewModel)
        self.flowController = FlowTableViewController(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("traffic.console")

        let appTitle = NSTextField(labelWithString: "ProxyLens")
        appTitle.translatesAutoresizingMaskIntoConstraints = false
        appTitle.font = .systemFont(ofSize: 15, weight: .semibold)

        statusImage.translatesAutoresizingMaskIntoConstraints = false
        statusImage.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 10, weight: .semibold)

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.title = "Start Capture"
        captureButton.bezelStyle = .rounded
        captureButton.target = self
        captureButton.action = #selector(toggleCapture)
        captureButton.keyEquivalent = "r"
        captureButton.keyEquivalentModifierMask = [.command]
        captureButton.setAccessibilityIdentifier("capture.toggle")

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(appTitle)
        header.addSubview(statusImage)
        header.addSubview(statusField)
        header.addSubview(captureButton)
        NSLayoutConstraint.activate([
            appTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            appTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusImage.leadingAnchor.constraint(equalTo: appTitle.trailingAnchor, constant: 16),
            statusImage.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 12),
            statusImage.heightAnchor.constraint(equalToConstant: 12),
            statusField.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 5),
            statusField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusField.trailingAnchor.constraint(
                lessThanOrEqualTo: captureButton.leadingAnchor, constant: -12),
            captureButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            captureButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        let headerSeparator = NSBox()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.boxType = .separator

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        configureSplitView()
        addChild(splitViewController)
        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(headerSeparator)
        container.addSubview(filterBar)
        container.addSubview(separator)
        container.addSubview(splitView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: 40),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container

        snapshotCancellable = viewModel.$snapshot.sink { [weak self] snapshot in
            self?.render(snapshot)
        }
    }

    private func configureSplitView() {
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        let sources = NSSplitViewItem(sidebarWithViewController: sourceController)
        sources.minimumThickness = 170
        sources.maximumThickness = 320
        sources.preferredThicknessFraction = 0.18
        sources.canCollapse = true

        let flows = NSSplitViewItem(viewController: flowController)
        flows.minimumThickness = 420
        flows.preferredThicknessFraction = 0.5
        flows.holdingPriority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultLow.rawValue + 1
        )

        let inspector = NSSplitViewItem(viewController: inspectorController)
        inspector.minimumThickness = 300
        inspector.preferredThicknessFraction = 0.32
        inspector.canCollapse = true

        splitViewController.addSplitViewItem(sources)
        splitViewController.addSplitViewItem(flows)
        splitViewController.addSplitViewItem(inspector)
    }

    private func render(_ snapshot: TrafficConsoleSnapshot) {
        sourceController.render(snapshot)
        flowController.render(snapshot)
        inspectorController.render(snapshot)

        let presentation = CaptureControlPresentation(snapshot.capture)
        statusImage.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: presentation.status
        )
        filterBar.render(snapshot)
        statusImage.contentTintColor = presentation.color
        statusField.stringValue = presentation.status
        statusField.toolTip = presentation.status
        captureButton.title = presentation.buttonTitle
        captureButton.isEnabled = presentation.buttonEnabled
    }

    @objc private func toggleCapture() {
        viewModel.toggleCapture()
    }
}

private struct CaptureControlPresentation {
    let status: String
    let color: NSColor
    let buttonTitle: String
    let buttonEnabled: Bool

    @MainActor
    init(_ capture: TrafficCapturePresentation) {
        switch capture {
        case .recovering:
            status = "Restoring previous capture state…"
            color = .systemOrange
            buttonTitle = "Start Capture"
            buttonEnabled = false
        case .stopped:
            status = "Capture stopped"
            color = .secondaryLabelColor
            buttonTitle = "Start Capture"
            buttonEnabled = true
        case .starting:
            status = "Starting capture…"
            color = .systemOrange
            buttonTitle = "Starting…"
            buttonEnabled = false
        case .running(let context, let warning):
            status = warning ?? "Capturing on \(context.endpoint.host):\(context.endpoint.port)"
            color = warning == nil ? .systemRed : .systemOrange
            buttonTitle = warning == nil ? "Stop Capture" : "Retry Stop"
            buttonEnabled = true
        case .stopping:
            status = "Stopping capture…"
            color = .systemOrange
            buttonTitle = "Stopping…"
            buttonEnabled = false
        case .failed(let message):
            status = message
            color = .systemRed
            buttonTitle = "Retry Capture"
            buttonEnabled = true
        }
    }
}
