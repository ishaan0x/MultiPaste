import AppKit
import Foundation
@preconcurrency import ApplicationServices
@preconcurrency import Carbon

private struct ClipboardSnapshotItem {
    let dataByType: [String: Data]
}

private final class ClipboardSnapshot {
    let items: [ClipboardSnapshotItem]

    init(items: [ClipboardSnapshotItem]) {
        self.items = items
    }

    static func capture() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return nil
        }

        let snapshots = items.compactMap { item -> ClipboardSnapshotItem? in
            var dataByType: [String: Data] = [:]

            for type in item.types {
                guard let data = item.data(forType: type) else {
                    continue
                }

                dataByType[type.rawValue] = data
            }

            return dataByType.isEmpty ? nil : ClipboardSnapshotItem(dataByType: dataByType)
        }

        guard !snapshots.isEmpty else {
            return nil
        }

        return ClipboardSnapshot(items: snapshots)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let pasteboardItems = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()

            for (rawType, data) in snapshot.dataByType {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: rawType))
            }

            return item
        }

        pasteboard.writeObjects(pasteboardItems)
    }
}

private final class HotKeyRegistration {
    let identifier: UInt32
    let ref: EventHotKeyRef

    init(identifier: UInt32, ref: EventHotKeyRef) {
        self.identifier = identifier
        self.ref = ref
    }

    deinit {
        UnregisterEventHotKey(ref)
    }
}

private struct TextSelectionContext {
    let element: AXUIElement
    let range: CFRange
    let application: NSRunningApplication?
}

@MainActor
private final class MultiPasteController: NSObject, NSApplicationDelegate {
    private let slotCount = 10
    private let copyBaseIdentifier: UInt32 = 1_000
    private let pasteBaseIdentifier: UInt32 = 2_000
    private let transformMenuIdentifier: UInt32 = 3_000
    private let signature: OSType = 0x4D505354

    private var slots: [ClipboardSnapshot?] = Array(repeating: nil, count: 10)
    private var registrations: [HotKeyRegistration] = []
    private var statusItem: NSStatusItem?
    private var eventHandlerRef: EventHandlerRef?
    private var enabled = true
    private var resetStatusItemTask: DispatchWorkItem?
    private var activePicker: TransformPickerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        installHotKeyHandler()
        registerHotKeys()
        promptForAccessibilityIfNeeded()
        updateStatusTitle("MP")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MP"

        let menu = NSMenu()
        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(NSMenuItem.separator())

        for index in 0..<slotCount {
            let title = "Slot \(displaySlotNumber(for: index)): Empty"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = 10 + index
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let transformHeader = NSMenuItem(title: "Text Transforms", action: nil, keyEquivalent: "")
        transformHeader.isEnabled = false
        menu.addItem(transformHeader)

        let transformItem = NSMenuItem(title: "Picker: Ctrl+Space", action: nil, keyEquivalent: "")
        transformItem.tag = 100
        menu.addItem(transformItem)

        for (offset, transform) in TextTransform.allCases.enumerated() {
            let item = NSMenuItem(title: "  \(transform.menuTitle): \(transform.pickerShortcut.uppercased())", action: nil, keyEquivalent: "")
            item.tag = 110 + offset
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear All Slots", action: #selector(clearAllSlots), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.items.first?.state = .on
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else {
                return status
            }

            DispatchQueue.main.async {
                MultiPasteController.shared.handleHotKey(identifier: hotKeyID.id)
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    private func registerHotKeys() {
        for index in 0..<slotCount {
            registerHotKey(
                identifier: copyBaseIdentifier + UInt32(index),
                keyCode: keyCode(for: index),
                modifiers: UInt32(controlKey)
            )

            registerHotKey(
                identifier: pasteBaseIdentifier + UInt32(index),
                keyCode: keyCode(for: index),
                modifiers: UInt32(controlKey | shiftKey)
            )
        }

        registerHotKey(
            identifier: transformMenuIdentifier,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey)
        )
    }

    private func registerHotKey(identifier: UInt32, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            NSLog("Failed to register hotkey \(identifier): \(status)")
            return
        }

        registrations.append(HotKeyRegistration(identifier: identifier, ref: hotKeyRef))
    }

    private func keyCode(for index: Int) -> UInt32 {
        switch index {
        case 0: return UInt32(kVK_ANSI_1)
        case 1: return UInt32(kVK_ANSI_2)
        case 2: return UInt32(kVK_ANSI_3)
        case 3: return UInt32(kVK_ANSI_4)
        case 4: return UInt32(kVK_ANSI_5)
        case 5: return UInt32(kVK_ANSI_6)
        case 6: return UInt32(kVK_ANSI_7)
        case 7: return UInt32(kVK_ANSI_8)
        case 8: return UInt32(kVK_ANSI_9)
        case 9: return UInt32(kVK_ANSI_0)
        default: return UInt32(kVK_ANSI_0)
        }
    }

    private func displaySlotNumber(for index: Int) -> Int {
        index == 9 ? 0 : index + 1
    }

    private func promptForAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func handleHotKey(identifier: UInt32) {
        guard enabled else {
            flashStatusTitle("Paused")
            return
        }

        switch identifier {
        case copyBaseIdentifier..<(copyBaseIdentifier + UInt32(slotCount)):
            let slotIndex = Int(identifier - copyBaseIdentifier)
            captureSelection(into: slotIndex)
        case pasteBaseIdentifier..<(pasteBaseIdentifier + UInt32(slotCount)):
            let slotIndex = Int(identifier - pasteBaseIdentifier)
            paste(from: slotIndex)
        case transformMenuIdentifier:
            presentTransformPicker()
        default:
            break
        }
    }

    private func captureSelection(into slotIndex: Int) {
        guard ensureAccessibilityPermissions() else {
            flashStatusTitle("Grant Access")
            return
        }

        postCommandKeystroke(keyCode: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }

            guard let snapshot = ClipboardSnapshot.capture() else {
                self.flashStatusTitle("Copy failed")
                return
            }

            self.slots[slotIndex] = snapshot
            self.refreshSlotTitles()
            self.flashStatusTitle("C\(self.displaySlotNumber(for: slotIndex))")
        }
    }

    private func paste(from slotIndex: Int) {
        guard ensureAccessibilityPermissions() else {
            flashStatusTitle("Grant Access")
            return
        }

        guard let snapshot = slots[slotIndex] else {
            flashStatusTitle("Empty \(displaySlotNumber(for: slotIndex))")
            return
        }

        snapshot.restore()
        postCommandKeystroke(keyCode: CGKeyCode(kVK_ANSI_V))
        flashStatusTitle("P\(displaySlotNumber(for: slotIndex))")
    }

    private func presentTransformPicker() {
        guard ensureAccessibilityPermissions() else {
            flashStatusTitle("Grant Access")
            return
        }

        guard activePicker == nil else {
            return
        }

        let selectionContext = captureSelectionContext()
        let previousClipboard = ClipboardSnapshot.capture()
        postCommandKeystroke(keyCode: CGKeyCode(kVK_ANSI_C))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }

            guard let selectedText = NSPasteboard.general.string(forType: .string), !selectedText.isEmpty else {
                self.restoreClipboard(previousClipboard)
                self.flashStatusTitle("No text")
                return
            }

            self.showTransformPicker(
                selectedText: selectedText,
                selectionContext: selectionContext,
                previousClipboard: previousClipboard
            )
        }
    }

    private func showTransformPicker(
        selectedText: String,
        selectionContext: TextSelectionContext?,
        previousClipboard: ClipboardSnapshot?
    ) {
        let picker = TransformPickerController(anchorPoint: NSEvent.mouseLocation)
        activePicker = picker

        picker.onChoose = { [weak self] transform in
            guard let self else { return }
            self.activePicker = nil
            self.applyTransform(
                transform,
                to: selectedText,
                selectionContext: selectionContext,
                previousClipboard: previousClipboard
            )
        }

        picker.onCancel = { [weak self] in
            guard let self else { return }
            self.activePicker = nil
            self.restoreClipboard(previousClipboard)
            selectionContext?.application?.activate(options: [.activateIgnoringOtherApps])
        }

        picker.show()
    }

    private func applyTransform(
        _ transform: TextTransform,
        to selectedText: String,
        selectionContext: TextSelectionContext?,
        previousClipboard: ClipboardSnapshot?
    ) {
        let transformedText = transform.apply(to: selectedText)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transformedText, forType: .string)

        selectionContext?.application?.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }

            self.postCommandKeystroke(keyCode: CGKeyCode(kVK_ANSI_V))
            self.flashStatusTitle(transform.statusMessage)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let restoredSelection = selectionContext.map {
                    self.restoreSelection($0, newText: transformedText)
                } ?? false

                if !restoredSelection {
                    self.selectInsertedTextFallback(length: transformedText.count)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.restoreClipboard(previousClipboard)
                }
            }
        }
    }

    private func ensureAccessibilityPermissions() -> Bool {
        AXIsProcessTrusted()
    }

    private func captureSelectionContext() -> TextSelectionContext? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedStatus == .success, let focusedElement = focusedValue else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        var selectedRangeValue: CFTypeRef?
        let selectedRangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )

        guard selectedRangeStatus == .success, let selectedRangeValue else {
            return nil
        }

        let axValue = selectedRangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return TextSelectionContext(
            element: element,
            range: range,
            application: NSWorkspace.shared.frontmostApplication
        )
    }

    private func restoreSelection(_ context: TextSelectionContext, newText: String) -> Bool {
        var range = CFRange(location: context.range.location, length: newText.utf16.count)
        guard let value = AXValueCreate(.cfRange, &range) else {
            return false
        }

        let status = AXUIElementSetAttributeValue(
            context.element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )

        guard status == .success else {
            return false
        }

        var selectedRangeValue: CFTypeRef?
        let readStatus = AXUIElementCopyAttributeValue(
            context.element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )

        guard readStatus == .success, let selectedRangeValue else {
            return false
        }

        let axValue = selectedRangeValue as! AXValue
        var restoredRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &restoredRange) else {
            return false
        }

        return restoredRange.location == range.location && restoredRange.length == range.length
    }

    private func restoreClipboard(_ snapshot: ClipboardSnapshot?) {
        guard let snapshot else {
            NSPasteboard.general.clearContents()
            return
        }

        snapshot.restore()
    }

    private func selectInsertedTextFallback(length: Int) {
        guard length > 0 else {
            return
        }

        for _ in 0..<length {
            postKeystroke(keyCode: CGKeyCode(kVK_LeftArrow), flags: .maskShift)
        }
    }

    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }

    private func postCommandKeystroke(keyCode: CGKeyCode) {
        postKeystroke(keyCode: keyCode, flags: .maskCommand)
    }

    private func updateStatusTitle(_ title: String) {
        statusItem?.button?.title = title
    }

    private func flashStatusTitle(_ title: String) {
        resetStatusItemTask?.cancel()
        updateStatusTitle(title)

        let workItem = DispatchWorkItem { [weak self] in
            self?.updateStatusTitle("MP")
        }

        resetStatusItemTask = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func refreshSlotTitles() {
        guard let menu = statusItem?.menu else {
            return
        }

        for index in 0..<slotCount {
            guard let item = menu.item(withTag: 10 + index) else {
                continue
            }

            let state = slots[index] == nil ? "Empty" : "Stored"
            item.title = "Slot \(displaySlotNumber(for: index)): \(state)"
        }
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        statusItem?.menu?.items.first?.state = enabled ? .on : .off
        flashStatusTitle(enabled ? "On" : "Off")
    }

    @objc private func clearAllSlots() {
        slots = Array(repeating: nil, count: slotCount)
        refreshSlotTitles()
        flashStatusTitle("Cleared")
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    static let shared = MultiPasteController()
}

@main
@MainActor
private struct MultiPasteApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MultiPasteController.shared
        app.delegate = delegate
        app.run()
    }
}
