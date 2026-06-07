import AppKit
import SwiftUI

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

        let hosting = NSHostingController(rootView: OrbView())
        let win = NSWindow(contentViewController: hosting)
        let contentSize = NSSize(width: 900, height: 750)
        let minimumContentSize = NSSize(width: 812, height: 675)

        win.title = "模块"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.isReleasedWhenClosed = false
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
}
