import AppKit
@preconcurrency import Carbon

private struct PickerOption {
    let transform: TextTransform
    let triggerKey: String
}

@MainActor
final class TransformPickerController: NSWindowController {
    private let options = TextTransform.allCases.map {
        PickerOption(transform: $0, triggerKey: $0.pickerShortcut.uppercased())
    }

    private let stackView = NSStackView()
    private var rowViews: [TransformPickerRowView] = []
    private var selectionIndex = 0 {
        didSet {
            refreshSelection()
        }
    }

    var onChoose: ((TextTransform) -> Void)?
    var onCancel: (() -> Void)?

    init(anchorPoint: NSPoint) {
        let width: CGFloat = 260
        let rowHeight: CGFloat = 30
        let padding: CGFloat = 8
        let height = CGFloat(TextTransform.allCases.count) * rowHeight + padding * 2
        let frame = Self.panelFrame(anchorPoint: anchorPoint, width: width, height: height)

        let panel = TransformPickerPanel(
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

        super.init(window: panel)
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event)
        }
        setupUI(width: width, height: height, padding: padding)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let panel = window as? TransformPickerPanel else {
            return
        }

        selectionIndex = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    func closePicker() {
        window?.orderOut(nil)
        close()
    }

    private func setupUI(width: CGFloat, height: CGFloat, padding: CGFloat) {
        guard let panel = window else {
            return
        }

        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffectView.material = .menu
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 10
        visualEffectView.layer?.masksToBounds = true

        stackView.orientation = .vertical
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for option in options {
            let rowView = TransformPickerRowView()
            rowView.configure(title: option.transform.menuTitle, shortcut: option.triggerKey)
            rowView.onClick = { [weak self] in
                self?.chooseTransform(option.transform)
            }
            rowViews.append(rowView)
            stackView.addArrangedSubview(rowView)
            rowView.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }

        visualEffectView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        panel.contentView = visualEffectView
        refreshSelection()
    }

    private func handleKeyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            selectionIndex = min(selectionIndex + 1, options.count - 1)
        case kVK_UpArrow:
            selectionIndex = max(selectionIndex - 1, 0)
        case kVK_Return, kVK_Space:
            chooseTransform(options[selectionIndex].transform)
        case kVK_Escape:
            cancel()
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else {
                return
            }

            if let match = options.first(where: { $0.transform.pickerShortcut == character }) {
                chooseTransform(match.transform)
            }
        }
    }

    private func refreshSelection() {
        for (index, rowView) in rowViews.enumerated() {
            rowView.isHighlighted = index == selectionIndex
        }
    }

    private func chooseTransform(_ transform: TextTransform) {
        closePicker()
        onChoose?(transform)
    }

    private func cancel() {
        closePicker()
        onCancel?()
    }

    private static func panelFrame(anchorPoint: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX = anchorPoint.x
        var originY = anchorPoint.y - height

        originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        originY = max(originY, visibleFrame.minY + 8)

        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}

@MainActor
final class TransformPickerPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onKeyDown?(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        )!)
    }
}

@MainActor
final class TransformPickerRowView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")

    var onClick: (() -> Void)?

    var isHighlighted = false {
        didSet {
            needsDisplay = true
            titleField.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            shortcutField.textColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .menuFont(ofSize: 14)
        shortcutField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)

        let stack = NSStackView(views: [titleField, NSView(), shortcutField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])

        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String, shortcut: String) {
        titleField.stringValue = title
        shortcutField.stringValue = shortcut
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (isHighlighted ? NSColor.selectedContentBackgroundColor : .clear).setFill()
        path.fill()
    }

    @objc private func handleClick() {
        onClick?()
    }
}
