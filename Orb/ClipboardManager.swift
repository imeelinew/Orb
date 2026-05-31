import AppKit
import Carbon

@MainActor
final class ClipboardManager {
    private let presenter = ClipboardPanelPresenter()
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    func refresh() {
        if ClipboardConfiguration.isEnabled() {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }

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
            guard status == noErr, hotKeyID.id == 1 else { return status }

            let manager = Unmanaged<ClipboardManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                guard ClipboardConfiguration.isEnabled() else { return }
                manager.presenter.toggle()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: clipboardFourCharCode("MgCp"), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRef = ref
    }

    func stop() {
        presenter.hide(animated: false)

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }
}

private func clipboardFourCharCode(_ string: String) -> OSType {
    var result: UInt32 = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + UInt32(scalar.value)
    }
    return OSType(result)
}
