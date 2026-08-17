import AppKit

@MainActor
final class TrafficTimingView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let contentStack = NSStackView()
    private let totalField = NSTextField(labelWithString: "—")
    private let firstByteField = NSTextField(labelWithString: "—")
    private let stateField = NSTextField(labelWithString: "")
    private let clientProtocolField = NSTextField(labelWithString: "Unknown")
    private let upstreamProtocolField = NSTextField(labelWithString: "Unknown")
    private let connectionReuseField = NSTextField(labelWithString: "Unknown")
    private let emptyField = NSTextField(labelWithString: "No timing milestones captured.")
    private var phaseRows: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ timing: TrafficTimingInspection?) {
        for row in phaseRows {
            contentStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        phaseRows.removeAll()

        guard let timing else {
            totalField.stringValue = "—"
            firstByteField.stringValue = "—"
            stateField.stringValue = "No flow selected"
            clientProtocolField.stringValue = "Unknown"
            upstreamProtocolField.stringValue = "Unknown"
            connectionReuseField.stringValue = "Unknown"
            emptyField.isHidden = false
            return
        }

        totalField.stringValue = Self.format(timing.totalDuration)
        firstByteField.stringValue = timing.timeToFirstByte.map(Self.format) ?? "—"
        stateField.stringValue = timing.isComplete ? "Complete" : "In Progress"
        stateField.textColor = timing.isComplete ? .systemGreen : .systemOrange
        clientProtocolField.stringValue = timing.clientProtocol
        upstreamProtocolField.stringValue = timing.upstreamProtocol
        connectionReuseField.stringValue = timing.connectionReuse
        emptyField.isHidden = !timing.phases.isEmpty

        let scale = max(timing.elapsedDuration, 0.001)
        for (index, phase) in timing.phases.enumerated() {
            let row = makePhaseRow(phase, scale: scale, colorIndex: index)
            phaseRows.append(row)
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func configure() {
        setAccessibilityIdentifier("inspector.timing")

        let heading = NSTextField(labelWithString: "Timing")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        configureMetric(totalField, identifier: "inspector.timing.total")
        configureMetric(firstByteField, identifier: "inspector.timing.firstByte")
        stateField.font = .systemFont(ofSize: 11, weight: .medium)
        stateField.alignment = .right
        stateField.setContentHuggingPriority(.required, for: .horizontal)
        stateField.setAccessibilityIdentifier("inspector.timing.state")

        let totalLabel = NSTextField(labelWithString: "Total")
        totalLabel.textColor = .secondaryLabelColor
        let firstByteLabel = NSTextField(labelWithString: "First Byte")
        firstByteLabel.textColor = .secondaryLabelColor
        let summary = NSStackView(views: [
            totalLabel, totalField, firstByteLabel, firstByteField, NSView(), stateField
        ])
        summary.orientation = .horizontal
        summary.spacing = 8
        summary.alignment = .centerY

        configureConnectionMetric(
            clientProtocolField,
            identifier: "inspector.timing.clientProtocol"
        )
        configureConnectionMetric(
            upstreamProtocolField,
            identifier: "inspector.timing.upstreamProtocol"
        )
        configureConnectionMetric(
            connectionReuseField,
            identifier: "inspector.timing.connectionReuse"
        )
        let connectionSummary = NSStackView(views: [
            NSTextField(labelWithString: "Client"), clientProtocolField,
            NSTextField(labelWithString: "Upstream"), upstreamProtocolField,
            NSTextField(labelWithString: "Socket"), connectionReuseField,
            NSView()
        ])
        connectionSummary.orientation = .horizontal
        connectionSummary.spacing = 8
        connectionSummary.alignment = .centerY
        for case let label as NSTextField in connectionSummary.arrangedSubviews
        where label !== clientProtocolField && label !== upstreamProtocolField
            && label !== connectionReuseField
        {
            label.textColor = .secondaryLabelColor
        }

        emptyField.font = .systemFont(ofSize: 12)
        emptyField.textColor = .secondaryLabelColor
        emptyField.alignment = .center
        emptyField.setAccessibilityIdentifier("inspector.timing.empty")

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 9
        contentStack.addArrangedSubview(heading)
        contentStack.addArrangedSubview(summary)
        contentStack.addArrangedSubview(connectionSummary)
        contentStack.addArrangedSubview(emptyField)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: documentView.bottomAnchor, constant: -14),
            summary.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            connectionSummary.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            emptyField.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
    }

    private func configureMetric(_ field: NSTextField, identifier: String) {
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setAccessibilityIdentifier(identifier)
    }

    private func configureConnectionMetric(_ field: NSTextField, identifier: String) {
        field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setAccessibilityIdentifier(identifier)
    }

    private func makePhaseRow(
        _ phase: TrafficTimingPhaseInspection,
        scale: TimeInterval,
        colorIndex: Int
    ) -> NSView {
        let nameField = NSTextField(labelWithString: phase.title)
        nameField.font = .systemFont(ofSize: 11, weight: .medium)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.toolTip = phase.title
        nameField.widthAnchor.constraint(equalToConstant: 118).isActive = true

        let bar = TrafficTimingBarView(
            startFraction: phase.startOffset / scale,
            durationFraction: phase.duration / scale,
            color: Self.phaseColors[colorIndex % Self.phaseColors.count]
        )
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 14).isActive = true
        bar.setAccessibilityIdentifier("inspector.timing.\(phase.kind.rawValue).bar")

        let durationField = NSTextField(labelWithString: Self.format(phase.duration))
        durationField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationField.alignment = .right
        durationField.widthAnchor.constraint(equalToConstant: 74).isActive = true
        durationField.setAccessibilityIdentifier(
            "inspector.timing.\(phase.kind.rawValue).duration"
        )

        let row = NSStackView(views: [nameField, bar, durationField])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return row
    }

    private static func format(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return String(format: "%.2f ms", duration * 1_000)
        }
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1_000)
        }
        return String(format: "%.2f s", duration)
    }

    private static let phaseColors: [NSColor] = [
        .systemTeal, .systemBlue, .systemIndigo, .systemPurple,
        .systemOrange, .systemGreen, .systemGray
    ]
}

@MainActor
private final class TrafficTimingBarView: NSView {
    private let startFraction: CGFloat
    private let durationFraction: CGFloat
    private let color: NSColor

    init(startFraction: Double, durationFraction: Double, color: NSColor) {
        self.startFraction = CGFloat(min(max(startFraction, 0), 1))
        self.durationFraction = CGFloat(min(max(durationFraction, 0), 1))
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = bounds.insetBy(dx: 0, dy: 3)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()

        let availableWidth = track.width
        let x = track.minX + availableWidth * startFraction
        let maximumWidth = max(0, track.maxX - x)
        let width = min(maximumWidth, max(2, availableWidth * durationFraction))
        guard width > 0 else {
            return
        }
        color.withAlphaComponent(0.82).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: track.minY, width: width, height: track.height),
            xRadius: 4,
            yRadius: 4
        ).fill()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
