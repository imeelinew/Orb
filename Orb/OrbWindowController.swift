import AppKit

@MainActor
final class OrbWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let prototype = OrbPrototypeViewController()
        let win = NSWindow(contentViewController: prototype)
        let contentSize = NSSize(width: 980, height: 720)
        let minimumContentSize = NSSize(width: 700, height: 560)

        win.title = "Orb"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.setContentSize(contentSize)
        win.minSize = win.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        win.center()
        win.delegate = self
        window = win

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        (window?.contentViewController as? OrbPrototypeViewController)?.windowWillStartLiveResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        (window?.contentViewController as? OrbPrototypeViewController)?.windowDidEndLiveResize()
    }

    func windowDidResize(_ notification: Notification) {
        (window?.contentViewController as? OrbPrototypeViewController)?.windowDidResize()
    }
}
