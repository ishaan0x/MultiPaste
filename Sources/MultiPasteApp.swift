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

private struct SlotEntry {
    let snapshot: ClipboardSnapshot
    let preview: String
    let updatedAt: Date
}

private struct ScreenshotPreferences {
    let directoryURL: URL
    let filePrefix: String
    let fileExtension: String
}

private final class ScreenshotFolderMonitor {
    private let preferences: ScreenshotPreferences
    private let queue = DispatchQueue(label: "com.ishaan.multipaste.screenshot-monitor")
    private var directoryFileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: DispatchWorkItem?
    private var knownFiles = Set<String>()

    var onNewScreenshot: (@Sendable (URL) -> Void)?

    init?(preferences: ScreenshotPreferences) {
        guard FileManager.default.fileExists(atPath: preferences.directoryURL.path) else {
            return nil
        }

        self.preferences = preferences
        knownFiles = Self.matchingFiles(for: preferences)
    }

    deinit {
        pendingScan?.cancel()
        source?.cancel()

        if directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
        }
    }

    func start() {
        guard source == nil else {
            return
        }

        directoryFileDescriptor = open(preferences.directoryURL.path, O_EVTONLY)
        guard directoryFileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFileDescriptor,
            eventMask: [.write, .rename, .extend],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleScan()
        }

        self.source = source
        source.resume()
    }

    private func scheduleScan() {
        pendingScan?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.scanDirectory()
        }

        pendingScan = workItem
        queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func scanDirectory() {
        let currentFiles = Self.matchingFiles(for: preferences)
        let newFiles = currentFiles.subtracting(knownFiles).sorted()
        knownFiles = currentFiles

        guard !newFiles.isEmpty else {
            return
        }

        for filePath in newFiles {
            let fileURL = URL(fileURLWithPath: filePath)
            onNewScreenshot?(fileURL)
        }
    }

    private static func matchingFiles(for preferences: ScreenshotPreferences) -> Set<String> {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: preferences.directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let normalizedExtension = preferences.fileExtension.lowercased()

        return Set(fileURLs.compactMap { fileURL in
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else {
                return nil
            }

            let fileName = fileURL.lastPathComponent
            guard fileName.hasPrefix(preferences.filePrefix) else {
                return nil
            }

            guard fileURL.pathExtension.lowercased() == normalizedExtension else {
                return nil
            }

            return fileURL.path
        })
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

private struct HotKeyDefinition {
    let identifier: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
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
    private let overlayNextIdentifier: UInt32 = 3_100
    private let overlayPreviousIdentifier: UInt32 = 3_101
    private let clearAllIdentifier: UInt32 = 3_102
    private let signature: OSType = 0x4D505354

    private var slots: [SlotEntry?] = Array(repeating: nil, count: 10)
    private var registrations: [HotKeyRegistration] = []
    private var statusItem: NSStatusItem?
    private var eventHandlerRef: EventHandlerRef?
    private var enabled = true
    private var resetStatusItemTask: DispatchWorkItem?
    private var activePicker: TransformPickerController?
    private var activeSlotOverlay: SlotOverlayController?
    private var flagsMonitor: Any?
    private var registeredHotKeyIdentifiers = Set<UInt32>()
    private var screenshotMonitor: ScreenshotFolderMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        installHotKeyHandler()
        installModifierMonitor()
        registerHotKeys()
        startScreenshotMonitoring()
        promptForAccessibilityIfNeeded()
        updateStatusTitle("MP")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }

        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
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
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: slotKeyEquivalent(for: index))
            item.tag = 10 + index
            item.keyEquivalentModifierMask = [.control]
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear All Slots", action: #selector(clearAllSlots), keyEquivalent: "\u{8}")
        clearItem.keyEquivalentModifierMask = [.control, .shift]
        clearItem.target = self
        menu.addItem(clearItem)

        for index in 0..<slotCount {
            let item = NSMenuItem(
                title: "Clear Slot \(displaySlotNumber(for: index))",
                action: #selector(clearSlotFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = 200 + index
            item.isHidden = true
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let transformHeader = NSMenuItem(title: "Text Transforms", action: #selector(openTransformPickerFromMenu), keyEquivalent: " ")
        transformHeader.keyEquivalentModifierMask = [.control]
        transformHeader.target = self
        menu.addItem(transformHeader)

        for (offset, transform) in TextTransform.allCases.enumerated() {
            let item = NSMenuItem(title: "  \(transform.menuTitle): \(transform.pickerShortcut.uppercased())", action: nil, keyEquivalent: "")
            item.tag = 110 + offset
            menu.addItem(item)
        }

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

    private func installModifierMonitor() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleModifierFlags(event.modifierFlags)
            }
        }
    }

    private func registerHotKeys() {
        for index in 0..<slotCount {
            registerHotKey(
                definition: HotKeyDefinition(
                    identifier: copyBaseIdentifier + UInt32(index),
                    keyCode: keyCode(for: index),
                    modifiers: UInt32(controlKey)
                )
            )

            registerHotKey(
                definition: HotKeyDefinition(
                    identifier: pasteBaseIdentifier + UInt32(index),
                    keyCode: keyCode(for: index),
                    modifiers: UInt32(controlKey | shiftKey)
                )
            )
        }

        registerHotKey(
            definition: HotKeyDefinition(
                identifier: transformMenuIdentifier,
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey)
            )
        )

        registerHotKey(
            definition: HotKeyDefinition(
                identifier: overlayNextIdentifier,
                keyCode: UInt32(kVK_DownArrow),
                modifiers: UInt32(controlKey | shiftKey)
            )
        )

        registerHotKey(
            definition: HotKeyDefinition(
                identifier: overlayPreviousIdentifier,
                keyCode: UInt32(kVK_UpArrow),
                modifiers: UInt32(controlKey | shiftKey)
            )
        )

        registerHotKey(
            definition: HotKeyDefinition(
                identifier: clearAllIdentifier,
                keyCode: UInt32(kVK_Delete),
                modifiers: UInt32(controlKey | shiftKey)
            )
        )
    }

    private func registerHotKey(definition: HotKeyDefinition, attempt: Int = 0) {
        guard !registeredHotKeyIdentifiers.contains(definition.identifier) else {
            return
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: definition.identifier)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            definition.keyCode,
            definition.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.registerHotKey(definition: definition, attempt: attempt + 1)
                }
            } else {
                NSLog("Failed to register hotkey \(definition.identifier) after retries: \(status)")
            }
            return
        }

        registeredHotKeyIdentifiers.insert(definition.identifier)
        registrations.append(HotKeyRegistration(identifier: definition.identifier, ref: hotKeyRef))
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

    private func startScreenshotMonitoring() {
        guard let preferences = screenshotPreferences() else {
            return
        }

        let monitor = ScreenshotFolderMonitor(preferences: preferences)
        monitor?.onNewScreenshot = { [weak self] fileURL in
            Task { @MainActor [weak self] in
                self?.captureScreenshot(at: fileURL)
            }
        }
        monitor?.start()
        screenshotMonitor = monitor
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
        case overlayNextIdentifier:
            selectNextOverlaySlot()
        case overlayPreviousIdentifier:
            selectPreviousOverlaySlot()
        case clearAllIdentifier:
            clearAllSlots()
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

            self.slots[slotIndex] = SlotEntry(
                snapshot: snapshot,
                preview: self.previewText(for: snapshot),
                updatedAt: Date()
            )
            self.refreshSlotTitles()
            self.refreshSlotOverlayIfNeeded()
            self.flashStatusTitle("C\(self.displaySlotNumber(for: slotIndex))")
        }
    }

    private func captureScreenshot(at fileURL: URL, attempt: Int = 0) {
        guard enabled else {
            return
        }

        guard let slotIndex = nextAvailableSlotIndex() else {
            flashStatusTitle("No open slot")
            return
        }

        let pasteboardType = pasteboardType(forScreenshotURL: fileURL)
        guard let data = try? Data(contentsOf: fileURL) else {
            guard attempt < 4 else {
                flashStatusTitle("Shot failed")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.captureScreenshot(at: fileURL, attempt: attempt + 1)
            }
            return
        }

        guard let snapshot = ClipboardSnapshot.imageFile(data: data, type: pasteboardType) else {
            flashStatusTitle("Shot failed")
            return
        }

        slots[slotIndex] = SlotEntry(
            snapshot: snapshot,
            preview: "[Screenshot]",
            updatedAt: Date()
        )
        refreshSlotTitles()
        refreshSlotOverlayIfNeeded()
        flashStatusTitle("S\(displaySlotNumber(for: slotIndex))")
    }

    private func paste(from slotIndex: Int) {
        guard ensureAccessibilityPermissions() else {
            flashStatusTitle("Grant Access")
            return
        }

        guard let slot = slots[slotIndex] else {
            flashStatusTitle("Empty \(displaySlotNumber(for: slotIndex))")
            return
        }

        slot.snapshot.restore()
        hideSlotOverlay()
        postCommandKeystroke(keyCode: CGKeyCode(kVK_ANSI_V))
        flashStatusTitle("P\(displaySlotNumber(for: slotIndex))")
    }

    private func presentTransformPicker() {
        guard ensureAccessibilityPermissions() else {
            flashStatusTitle("Grant Access")
            return
        }

        if let activePicker {
            activePicker.cancelPicker()
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
                var restoredSelection = selectionContext.map {
                    self.restoreSelection($0, newText: transformedText)
                } ?? false

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    if let selectionContext {
                        restoredSelection = self.currentSelectionMatches(selectionContext, newText: transformedText)
                    }

                    if !restoredSelection {
                        self.selectInsertedTextFallback(length: transformedText.utf16.count)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        self.restoreClipboard(previousClipboard)
                    }
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

    private func currentSelectionMatches(_ context: TextSelectionContext, newText: String) -> Bool {
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

        return restoredRange.location == context.range.location && restoredRange.length == newText.utf16.count
    }

    private func restoreClipboard(_ snapshot: ClipboardSnapshot?) {
        guard let snapshot else {
            NSPasteboard.general.clearContents()
            return
        }

        snapshot.restore()
    }

    private func previewText(for snapshot: ClipboardSnapshot) -> String {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let rtfType = NSPasteboard.PasteboardType.rtf.rawValue
        let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
        let tiffType = NSPasteboard.PasteboardType.tiff.rawValue
        let pngType = NSPasteboard.PasteboardType.png.rawValue
        let pdfType = NSPasteboard.PasteboardType.pdf.rawValue

        for item in snapshot.items {
            if let data = item.dataByType[stringType], let text = String(data: data, encoding: .utf8) {
                return compactPreview(text)
            }

            if let data = item.dataByType[rtfType],
               let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
               ) {
                return compactPreview(attributed.string)
            }

            if item.dataByType[fileURLType] != nil {
                return "[Files]"
            }

            if item.dataByType[tiffType] != nil || item.dataByType[pngType] != nil || item.dataByType[pdfType] != nil {
                return "[Image]"
            }
        }

        return "[Clipboard Item]"
    }

    private func compactPreview(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else {
            return "[Empty Text]"
        }

        return String(collapsed.prefix(180))
    }

    private func installSlotOverlayIfNeeded() {
        guard activeSlotOverlay == nil else {
            return
        }

        let items = slots.enumerated().compactMap { index, slot -> SlotOverlayItem? in
            guard let slot else {
                return nil
            }

            return SlotOverlayItem(slotIndex: index, preview: slot.preview, updatedAt: slot.updatedAt)
        }

        guard !items.isEmpty else {
            return
        }

        let overlay = SlotOverlayController(items: items, anchorPoint: NSEvent.mouseLocation)
        activeSlotOverlay = overlay
        overlay.show()
    }

    private func refreshSlotOverlayIfNeeded() {
        guard activeSlotOverlay != nil else {
            return
        }

        hideSlotOverlay()
        installSlotOverlayIfNeeded()
    }

    private func hideSlotOverlay() {
        activeSlotOverlay?.closeOverlay()
        activeSlotOverlay = nil
    }

    private func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        let normalizedFlags = flags.intersection(.deviceIndependentFlagsMask)
        let shouldShowOverlay =
            normalizedFlags.contains(.control) &&
            normalizedFlags.contains(.shift) &&
            !normalizedFlags.contains(.command) &&
            !normalizedFlags.contains(.option)

        if shouldShowOverlay {
            installSlotOverlayIfNeeded()
        } else {
            pasteSelectedOverlaySlotIfNeeded()
        }
    }

    private func selectNextOverlaySlot() {
        guard enabled else {
            return
        }

        installSlotOverlayIfNeeded()
        activeSlotOverlay?.selectNext()
    }

    private func selectPreviousOverlaySlot() {
        guard enabled else {
            return
        }

        installSlotOverlayIfNeeded()
        activeSlotOverlay?.selectPrevious()
    }

    private func pasteSelectedOverlaySlotIfNeeded() {
        guard let activeSlotOverlay else {
            return
        }

        guard let selectedSlotIndex = activeSlotOverlay.selectedSlotIndex else {
            hideSlotOverlay()
            return
        }

        paste(from: selectedSlotIndex)
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

            if let slot = slots[index] {
                item.title = "Slot \(displaySlotNumber(for: index)): \(slot.preview)"
                item.action = #selector(pasteSlotFromMenu(_:))
                item.target = self
                item.isEnabled = true
                item.keyEquivalentModifierMask = [.control, .shift]
            } else {
                item.title = "Slot \(displaySlotNumber(for: index)): Empty"
                item.action = nil
                item.target = nil
                item.isEnabled = false
                item.keyEquivalentModifierMask = [.control]
            }
        }

        for index in 0..<slotCount {
            guard let item = menu.item(withTag: 200 + index) else {
                continue
            }

            item.title = "Clear Slot \(displaySlotNumber(for: index))"
            item.isHidden = slots[index] == nil
        }
    }

    private func nextAvailableSlotIndex() -> Int? {
        slots.firstIndex(where: { $0 == nil })
    }

    private func slotKeyEquivalent(for index: Int) -> String {
        "\(displaySlotNumber(for: index))"
    }

    private func clearSlot(_ index: Int) {
        guard slots.indices.contains(index), slots[index] != nil else {
            return
        }

        slots[index] = nil
        refreshSlotTitles()
        refreshSlotOverlayIfNeeded()
        flashStatusTitle("X\(displaySlotNumber(for: index))")
    }

    private func screenshotPreferences() -> ScreenshotPreferences? {
        let defaults = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture") ?? [:]
        let directoryPath = (defaults["location"] as? String).map { ($0 as NSString).expandingTildeInPath }
            ?? NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
        let filePrefix = (defaults["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Screenshot"
        let fileExtension = (defaults["type"] as? String)?.lowercased() ?? "png"

        guard let directoryPath else {
            return nil
        }

        return ScreenshotPreferences(
            directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true),
            filePrefix: filePrefix,
            fileExtension: fileExtension
        )
    }

    private func pasteboardType(forScreenshotURL fileURL: URL) -> NSPasteboard.PasteboardType {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return NSPasteboard.PasteboardType(rawValue: "public.jpeg")
        case "tif", "tiff":
            return .tiff
        case "pdf":
            return .pdf
        default:
            return .png
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
        hideSlotOverlay()
        flashStatusTitle("Cleared")
    }

    @objc private func clearSlotFromMenu(_ sender: NSMenuItem) {
        let slotIndex = sender.tag - 200
        clearSlot(slotIndex)
    }

    @objc private func pasteSlotFromMenu(_ sender: NSMenuItem) {
        let slotIndex = sender.tag - 10
        paste(from: slotIndex)
    }

    @objc private func openTransformPickerFromMenu() {
        presentTransformPicker()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    static let shared = MultiPasteController()
}

private extension ClipboardSnapshot {
    static func imageFile(data: Data, type: NSPasteboard.PasteboardType) -> ClipboardSnapshot? {
        let item = ClipboardSnapshotItem(dataByType: [type.rawValue: data])
        return ClipboardSnapshot(items: [item])
    }
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
