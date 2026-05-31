import AppKit
import ApplicationServices
import Carbon

@MainActor
final class InputCorrectionManager: NSObject {
    private struct TextSnapshot {
        let signature: String
        let fullText: String
        let context: String
        let contextStart: Int
        let cursorLocation: Int
        let element: AXUIElement
        let caretBounds: CGRect?
    }

    private struct ActiveSuggestion {
        let suggestion: CorrectionSuggestion
        let snapshot: TextSnapshot
    }

    private let client = RemoteCorrectionClient()
    private let presenter = InputCorrectionSuggestionPresenter()
    private var pollTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var latestSnapshot: TextSnapshot?
    private var activeSuggestion: ActiveSuggestion?
    private var lastRequestedSignature = ""
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var didRequestEventListeningAccess = false
    private var suppressedKeyUps = Set<CGKeyCode>()

    func start() {
        guard pollTimer == nil else { return }
        installEventTap()
        pollTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(handlePollTimer),
            userInfo: nil,
            repeats: true
        )
        pollFocusedText()
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pollTimer?.invalidate()
        pollTimer = nil
        removeEventTap()
        dismissSuggestion()
    }

    func refresh() {
        if InputCorrectionConfiguration.isEnabled() {
            start()
        } else {
            stop()
        }
    }

    private func pollFocusedText() {
        guard InputCorrectionConfiguration.isEnabled(), AXIsProcessTrusted() else {
            dismissSuggestion()
            return
        }
        installEventTap()

        guard let snapshot = focusedTextSnapshot() else {
            dismissSuggestion()
            latestSnapshot = nil
            return
        }

        if let activeSuggestion,
           activeSuggestion.snapshot.signature != snapshot.signature,
           let insertedRange = syntheticAcceptInsertedRange(from: activeSuggestion.snapshot, to: snapshot) {
            acceptSuggestion(removingInsertedRange: insertedRange)
            return
        }

        if activeSuggestion?.snapshot.signature != snapshot.signature {
            dismissSuggestion()
        }

        guard latestSnapshot?.signature != snapshot.signature else { return }
        latestSnapshot = snapshot
        scheduleCheck(for: snapshot)
    }

    @objc private func handlePollTimer() {
        pollFocusedText()
    }

    private func scheduleCheck(for snapshot: TextSnapshot) {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.check(snapshot: snapshot)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func check(snapshot: TextSnapshot) {
        guard snapshot.signature != lastRequestedSignature else { return }
        guard latestSnapshot?.signature == snapshot.signature else { return }

        let apiKey = KeychainStore.string(for: KeychainStore.inputCorrectionAPIKeyAccount)
        let configuration = RemoteModelConfiguration(
            apiKey: apiKey,
            model: InputCorrectionConfiguration.model(),
            baseURL: InputCorrectionConfiguration.baseURL()
        )
        guard !configuration.apiKey.isEmpty else { return }

        lastRequestedSignature = snapshot.signature
        let context = snapshot.context
        let signature = snapshot.signature

        Task { [client, configuration, context, signature] in
            let suggestion = try? await client.check(context: context, configuration: configuration)
            await MainActor.run {
                self.present(suggestion: suggestion, for: signature)
            }
        }
    }

    @MainActor
    private func present(suggestion: CorrectionSuggestion?, for signature: String) {
        guard
            let suggestion,
            let snapshot = latestSnapshot,
            snapshot.signature == signature
        else {
            return
        }
        guard let normalizedSuggestion = normalizedSuggestion(suggestion, in: snapshot.context) else { return }

        activeSuggestion = ActiveSuggestion(suggestion: normalizedSuggestion, snapshot: snapshot)
        presenter.show(suggestion: normalizedSuggestion, near: snapshot.caretBounds)
    }

    private func dismissSuggestion() {
        activeSuggestion = nil
        presenter.dismiss()
    }

    private func focusedTextSnapshot() -> TextSnapshot? {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = elementValue(for: kAXFocusedUIElementAttribute, element: appElement) else {
            return nil
        }
        guard !isSecureTextElement(element) else { return nil }
        guard
            let fullText = stringValue(for: kAXValueAttribute, element: element),
            !fullText.isEmpty,
            let selectedRange = selectedTextRange(for: element),
            selectedRange.length == 0
        else {
            return nil
        }

        let fullNSString = fullText as NSString
        let cursor = min(max(selectedRange.location, 0), fullNSString.length)
        let contextStart = max(0, cursor - 80)
        let contextRange = NSRange(location: contextStart, length: cursor - contextStart)
        let context = fullNSString.substring(with: contextRange)
        guard containsChinese(context) else { return nil }

        let caretRange = CFRange(location: cursor, length: 0)
        let fallbackRange = CFRange(location: max(cursor - 1, 0), length: cursor > 0 ? 1 : 0)
        let caretBounds = bounds(for: caretRange, element: element) ?? bounds(for: fallbackRange, element: element)
        let signature = "\(app.processIdentifier):\(cursor):\(context.hashValue)"

        return TextSnapshot(
            signature: signature,
            fullText: fullText,
            context: context,
            contextStart: contextStart,
            cursorLocation: cursor,
            element: element,
            caretBounds: caretBounds
        )
    }

    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        let role = stringValue(for: kAXRoleAttribute, element: element) ?? ""
        let subrole = stringValue(for: kAXSubroleAttribute, element: element) ?? ""
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private func containsChinese(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private func normalizedSuggestion(
        _ suggestion: CorrectionSuggestion,
        in context: String
    ) -> CorrectionSuggestion? {
        let nsContext = context as NSString
        let range = NSRange(location: suggestion.location, length: suggestion.length)
        if range.location >= 0,
           range.length > 0,
           NSMaxRange(range) <= nsContext.length,
           nsContext.substring(with: range) == suggestion.original {
            return suggestion
        }

        let originalLength = (suggestion.original as NSString).length
        guard originalLength > 0 else { return nil }

        let searchStart = max(0, suggestion.location - 6)
        let searchEnd = min(nsContext.length, suggestion.location + max(suggestion.length, originalLength) + 6)
        guard searchEnd > searchStart else { return nil }

        let nearbyRange = NSRange(location: searchStart, length: searchEnd - searchStart)
        let correctedRange = nsContext.range(of: suggestion.original, options: [], range: nearbyRange)
        guard correctedRange.location != NSNotFound else {
            return nil
        }

        return CorrectionSuggestion(
            original: suggestion.original,
            replacement: suggestion.replacement,
            location: correctedRange.location,
            length: correctedRange.length,
            reason: suggestion.reason
        )
    }

    private func handle(type: CGEventType, keyCode: CGKeyCode) -> Bool {
        if type == .keyUp, suppressedKeyUps.remove(keyCode) != nil {
            return true
        }

        guard type == .keyDown, activeSuggestion != nil else {
            return false
        }

        switch Int(keyCode) {
        case kVK_Tab:
            suppressedKeyUps.insert(keyCode)
            acceptSuggestion()
            return true
        case kVK_Escape:
            suppressedKeyUps.insert(keyCode)
            dismissSuggestion()
            return true
        default:
            return false
        }
    }

    private func acceptSuggestion(removingInsertedRange insertedRange: NSRange? = nil) {
        guard let activeSuggestion else { return }
        let fullRange = NSRange(
            location: activeSuggestion.snapshot.contextStart + activeSuggestion.suggestion.location,
            length: activeSuggestion.suggestion.length
        )
        let replacement = activeSuggestion.suggestion.replacement
        let element = activeSuggestion.snapshot.element
        let replacementLength = (replacement as NSString).length
        let desiredCursorLocation = max(
            0,
            activeSuggestion.snapshot.cursorLocation + replacementLength - activeSuggestion.suggestion.length
        )
        let effectiveInsertedRange = insertedRange
            ?? syntheticAcceptInsertedRange(
                from: activeSuggestion.snapshot,
                currentText: stringValue(for: kAXValueAttribute, element: element) ?? ""
            )

        if replaceWholeValue(in: element, range: fullRange, replacement: replacement, removingInsertedRange: effectiveInsertedRange)
            || replaceSelectedText(in: element, range: fullRange, replacement: replacement)
            || replaceWholeValue(in: element, range: fullRange, replacement: replacement)
            || pasteReplacement(in: element, range: fullRange, replacement: replacement) {
            _ = setSelectedTextRange(NSRange(location: desiredCursorLocation, length: 0), element: element)
            latestSnapshot = nil
        }
        dismissSuggestion()
    }

    private func syntheticAcceptInsertedRange(from previous: TextSnapshot, to current: TextSnapshot) -> NSRange? {
        syntheticAcceptInsertedRange(from: previous, currentText: current.fullText)
    }

    private func syntheticAcceptInsertedRange(from previous: TextSnapshot, currentText: String) -> NSRange? {
        let previousText = previous.fullText as NSString
        let currentText = currentText as NSString
        let cursor = previous.cursorLocation
        guard
            cursor <= previousText.length,
            cursor <= currentText.length,
            currentText.length > previousText.length
        else {
            return nil
        }

        let insertedLength = currentText.length - previousText.length
        let insertedRange = NSRange(location: cursor, length: insertedLength)
        guard NSMaxRange(insertedRange) <= currentText.length else { return nil }

        let beforeCursor = previousText.substring(to: cursor)
        let afterCursor = previousText.substring(from: cursor)
        let currentBeforeCursor = currentText.substring(to: cursor)
        let currentAfterInserted = currentText.substring(from: NSMaxRange(insertedRange))
        guard currentBeforeCursor == beforeCursor, currentAfterInserted == afterCursor else {
            return nil
        }

        let insertedText = currentText.substring(with: insertedRange)
        let allowedCharacters = CharacterSet(charactersIn: "\t \n\r")
        guard insertedText.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }
        return insertedRange
    }

    private func replaceSelectedText(in element: AXUIElement, range: NSRange, replacement: String) -> Bool {
        guard setSelectedTextRange(range, element: element) else { return false }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        )
        if status == .success {
            _ = setSelectedTextRange(
                NSRange(location: range.location + (replacement as NSString).length, length: 0),
                element: element
            )
        }
        return status == .success
    }

    private func replaceWholeValue(in element: AXUIElement, range: NSRange, replacement: String) -> Bool {
        replaceWholeValue(in: element, range: range, replacement: replacement, removingInsertedRange: nil)
    }

    private func replaceWholeValue(
        in element: AXUIElement,
        range: NSRange,
        replacement: String,
        removingInsertedRange insertedRange: NSRange?
    ) -> Bool {
        guard let currentText = stringValue(for: kAXValueAttribute, element: element) else { return false }
        let nsText = currentText as NSString
        guard NSMaxRange(range) <= nsText.length else { return false }

        let mutable = NSMutableString(string: currentText)
        if let insertedRange, NSMaxRange(insertedRange) <= mutable.length {
            mutable.deleteCharacters(in: insertedRange)
        }
        guard NSMaxRange(range) <= mutable.length else { return false }
        mutable.replaceCharacters(in: range, with: replacement)
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, mutable as CFTypeRef)
        if status == .success {
            _ = setSelectedTextRange(
                NSRange(location: range.location + (replacement as NSString).length, length: 0),
                element: element
            )
        }
        return status == .success
    }

    private func pasteReplacement(in element: AXUIElement, range: NSRange, replacement: String) -> Bool {
        guard setSelectedTextRange(range, element: element) else { return false }

        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)
        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
            }
        }
        return true
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func setSelectedTextRange(_ range: NSRange, element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        ) == .success
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        AXValueGetValue(axValue, .cfRange, &range)
        return range
    }

    private func bounds(for range: CFRange, element: AXUIElement) -> CGRect? {
        var range = range
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        )
        guard result == .success, let value else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }

        var rect = CGRect.zero
        AXValueGetValue(axValue, .cgRect, &rect)
        return rect
    }

    private func elementValue(for key: String, element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return (value as! AXUIElement)
    }

    private func stringValue(for key: String, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func installEventTap() {
        guard eventTap == nil else { return }
        guard CGPreflightListenEventAccess() || requestEventListeningAccessIfNeeded() else {
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = makeEventTap(mask: mask) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
    }

    private func requestEventListeningAccessIfNeeded() -> Bool {
        guard !didRequestEventListeningAccess else {
            return CGPreflightListenEventAccess()
        }
        didRequestEventListeningAccess = true
        return CGRequestListenEventAccess()
    }

    private func makeEventTap(mask: CGEventMask) -> CFMachPort? {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        return CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) ?? CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        )
    }

    private func removeEventTap() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTapSource = nil
        eventTap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<InputCorrectionManager>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                if let eventTap = manager.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let didHandle = MainActor.assumeIsolated {
            manager.handle(type: type, keyCode: keyCode)
        }
        return didHandle ? nil : Unmanaged.passUnretained(event)
    }
}
