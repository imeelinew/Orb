import AppKit
import SwiftUI

@MainActor
final class ClipboardPanelPresenter {
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var isVisible = false

    func toggle() {
        if isVisible {
            hide(animated: true)
        } else {
            show(animated: true)
        }
    }

    func show(animated: Bool) {
        let screen = targetScreen()
        let panel = panel ?? makePanel()
        let targetFrame = panelFrame(for: screen)

        let hosting = NSHostingView(rootView: ClipboardPanelChromeView())
        configureHostingView(hosting)
        panel.contentView = hosting
        panel.setFrame(targetFrame, display: false)

        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()

        if animated {
            let offscreenFrame = targetFrame.offsetBy(dx: 0, dy: -targetFrame.height - 24)
            panel.setFrame(offscreenFrame, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.orderFrontRegardless()
        }

        self.panel = panel
        isVisible = true
    }

    func hide(animated: Bool) {
        guard let panel, isVisible else { return }

        removeOutsideClickMonitor()

        let targetFrame = panel.frame
        let offscreenFrame = targetFrame.offsetBy(dx: 0, dy: -targetFrame.height - 24)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(offscreenFrame, display: true)
            } completionHandler: {
                Task { @MainActor [weak panel] in
                    panel?.orderOut(nil)
                    self.isVisible = false
                }
            }
        } else {
            panel.orderOut(nil)
            isVisible = false
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        return panel
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isVisible, let panel = self.panel else { return event }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                Task { @MainActor in
                    self.hide(animated: true)
                }
                return nil
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func configureHostingView(_ hosting: NSHostingView<ClipboardPanelChromeView>) {
        hosting.wantsLayer = true
        guard let layer = hosting.layer else { return }
        layer.cornerRadius = ClipboardPanelMetrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.clear.cgColor
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// 使用 `visibleFrame`，底部留在 Dock / 菜单栏之上。
    private func panelFrame(for screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let horizontalInset: CGFloat = 10
        let bottomInset: CGFloat = 12
        let panelHeight = visible.height / 3
        let width = visible.width - horizontalInset * 2
        let originX = visible.minX + horizontalInset
        let originY = visible.minY + bottomInset
        return CGRect(x: originX, y: originY, width: width, height: panelHeight)
    }
}
