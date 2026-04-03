import AppKit

struct SlotOverlayItem {
    let slotIndex: Int
    let preview: String
    let updatedAt: Date
}

@MainActor
final class SlotOverlayController: NSWindowController {
    private let items: [SlotOverlayItem]
    private let stackView = NSStackView()
    private let separatorColor = NSColor(calibratedWhite: 0.82, alpha: 1)
    private let rowHeight: CGFloat = 46
    private var rowViews: [SlotOverlayRowView] = []
    private var selectionIndex: Int? {
        didSet {
            refreshSelection()
        }
    }

    init(items: [SlotOverlayItem], anchorPoint: NSPoint) {
        self.items = items

        let width = Self.panelWidth(for: items)
        let padding: CGFloat = 8
        let separatorHeight: CGFloat = items.count > 1 ? CGFloat(items.count - 1) : 0
        let height = CGFloat(items.count) * rowHeight + separatorHeight + padding * 2
        let frame = Self.panelFrame(anchorPoint: anchorPoint, width: width, height: height)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        super.init(window: panel)
        setupUI(width: width, height: height, padding: padding)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func closeOverlay() {
        window?.orderOut(nil)
        close()
    }

    var selectedSlotIndex: Int? {
        guard let selectionIndex else {
            return nil
        }

        return items[selectionIndex].slotIndex
    }

    func selectNext() {
        guard !items.isEmpty else {
            return
        }

        if let selectionIndex {
            self.selectionIndex = (selectionIndex + 1) % items.count
        } else {
            selectionIndex = 0
        }
    }

    func selectPrevious() {
        guard !items.isEmpty else {
            return
        }

        if let selectionIndex {
            self.selectionIndex = (selectionIndex - 1 + items.count) % items.count
        } else {
            selectionIndex = items.count - 1
        }
    }

    private func setupUI(width: CGFloat, height: CGFloat, padding: CGFloat) {
        guard let panel = window else {
            return
        }

        let backgroundView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.93,
            alpha: 0.96
        ).cgColor
        backgroundView.layer?.cornerRadius = 12
        backgroundView.layer?.masksToBounds = true

        stackView.orientation = .vertical
        stackView.spacing = 2
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for (index, item) in items.enumerated() {
            let rowView = SlotOverlayRowView()
            rowView.configure(
                slotNumber: item.slotIndex == 9 ? "0" : "\(item.slotIndex + 1)",
                preview: item.preview,
                subtitle: Self.subtitle(for: item.updatedAt)
            )
            rowViews.append(rowView)
            stackView.addArrangedSubview(rowView)
            rowView.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            rowView.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            rowView.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true

            if index < items.count - 1 {
                let separator = NSView()
                separator.wantsLayer = true
                separator.layer?.backgroundColor = separatorColor.cgColor
                separator.translatesAutoresizingMaskIntoConstraints = false
                stackView.addArrangedSubview(separator)
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }

        backgroundView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor)
        ])

        panel.contentView = backgroundView
        refreshSelection()
    }

    private static func subtitle(for date: Date) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        let relative = relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "\(timeFormatter.string(from: date))  •  \(relative)"
    }

    private static func panelWidth(for items: [SlotOverlayItem]) -> CGFloat {
        let previewFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let subtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let numberFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

        let contentWidth = items.reduce(CGFloat(0)) { currentMax, item in
            let previewWidth = NSString(string: item.preview).size(withAttributes: [.font: previewFont]).width
            let subtitleWidth = NSString(string: subtitle(for: item.updatedAt)).size(withAttributes: [.font: subtitleFont]).width
            let numberWidth = NSString(string: item.slotIndex == 9 ? "0" : "\(item.slotIndex + 1)")
                .size(withAttributes: [.font: numberFont]).width
            return max(currentMax, max(previewWidth, subtitleWidth) + numberWidth + 44)
        }

        return min(max(contentWidth + 28, 240), 640)
    }

    private static func panelFrame(anchorPoint: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX = anchorPoint.x + 8
        var originY = anchorPoint.y - height - 8

        originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        originY = max(originY, visibleFrame.minY + 8)

        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}

@MainActor
final class SlotOverlayRowView: NSView {
    private let slotLabel = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

    var isHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        slotLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        slotLabel.alignment = .right
        slotLabel.textColor = .secondaryLabelColor
        slotLabel.translatesAutoresizingMaskIntoConstraints = false

        previewField.font = .systemFont(ofSize: 13, weight: .regular)
        previewField.textColor = .labelColor
        previewField.lineBreakMode = .byTruncatingTail
        previewField.maximumNumberOfLines = 1
        previewField.cell?.wraps = false
        previewField.cell?.isScrollable = false

        subtitleField.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleField.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [previewField, subtitleField])
        textStack.orientation = .vertical
        textStack.spacing = 0
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(slotLabel)
        contentStack.addArrangedSubview(textStack)

        addSubview(contentStack)

        NSLayoutConstraint.activate([
            slotLabel.widthAnchor.constraint(equalToConstant: 18),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(slotNumber: String, preview: String, subtitle: String) {
        slotLabel.stringValue = slotNumber
        previewField.stringValue = preview
        subtitleField.stringValue = subtitle
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isHighlighted else {
            return
        }

        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: 0.84, alpha: 0.95).setFill()
        path.fill()
    }

    override var isFlipped: Bool {
        false
    }
}

private extension SlotOverlayController {
    func refreshSelection() {
        for (index, rowView) in rowViews.enumerated() {
            rowView.isHighlighted = index == selectionIndex
        }
    }
}
