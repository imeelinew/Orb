import AppKit
import SwiftUI

private let finderSyncBundleIdentifier = "com.eli.Orb.FinderSync"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationSeconds: TimeInterval = 5
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var mainWindowController = OrbWindowController()
    private let windowOperationManager = WindowOperationManager()
    private let networkSpeedMonitor = NetworkSpeedMonitor()
    private let inputCorrectionManager = InputCorrectionManager()
    private let clipboardManager = ClipboardManager()
    private var notificationPopover: NSPopover?
    private var notificationDismissWorkItem: DispatchWorkItem?
    private var eventReadWorkItem: DispatchWorkItem?
    private var lastPopoverEventContent = ""
    private var eventSource: DispatchSourceFileSystemObject?
    private var eventDirectoryDescriptor: CInt = -1
    private var didDisableFinderExtensionForTermination = false
    private var defaultsObserver: NSObjectProtocol?
    private var isShowingNetworkSpeed = false
    private var currentNetworkSpeedSample = NetworkSpeedSample(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
    private var networkSpeedContentView: NSView?
    private var networkSpeedLabel: NSTextField?
    private var networkSpeedImageView: NSImageView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        configureStatusItem()
        installApplicationScripts()
        setFinderExtensionEnabled(true)
        windowOperationManager.start()
        clipboardManager.refresh()
        inputCorrectionManager.refresh()
        observeDefaultsChanges()
        startPopoverEventWatcher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        networkSpeedMonitor.stop()
        inputCorrectionManager.stop()
        clipboardManager.stop()
        windowOperationManager.stop()
        disableFinderExtensionForTermination()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Orb")
        appMenu.addItem(
            withTitle: "关于 Orb",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 Orb",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(
            withTitle: "撤销",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(
            withTitle: "重做",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "剪切",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "复制",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "粘贴",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "全选",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        networkSpeedMonitor.onUpdate = { [weak self] sample in
            self?.currentNetworkSpeedSample = sample
            self?.refreshStatusItemButton()
        }
        refreshStatusItemConfiguration()
        statusItem.menu = makeMenu()
    }

    private func refreshStatusItemConfiguration() {
        let shouldShowNetworkSpeed = MenuBarConfiguration.showsNetworkSpeed()
        guard shouldShowNetworkSpeed != isShowingNetworkSpeed else {
            refreshStatusItemButton()
            return
        }

        isShowingNetworkSpeed = shouldShowNetworkSpeed
        if shouldShowNetworkSpeed {
            networkSpeedMonitor.start()
        } else {
            networkSpeedMonitor.stop()
            currentNetworkSpeedSample = .init(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
        }
        refreshStatusItemButton()
    }

    private func refreshStatusItemButton() {
        guard let button = statusItem.button else { return }
        button.toolTip = "Orb"

        if isShowingNetworkSpeed {
            let title = networkSpeedTitle(for: currentNetworkSpeedSample)
            installNetworkSpeedButtonContent(in: button, title: title)
            statusItem.length = networkSpeedButtonWidth(for: title)
        } else {
            removeNetworkSpeedButtonContent()
            button.image = statusIcon()
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            statusItem.length = NSStatusItem.variableLength
        }
    }

    private func statusIcon() -> NSImage? {
        NSImage(
            systemSymbolName: "pointer.arrow.ipad.rays",
            accessibilityDescription: "Orb"
        ) ?? NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Orb")
    }

    private func networkSpeedTitle(for sample: NetworkSpeedSample) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.minimumLineHeight = 8
        paragraphStyle.maximumLineHeight = 8
        paragraphStyle.lineBreakMode = .byClipping

        return NSAttributedString(
            string: "\(formatNetworkSpeed(sample.uploadBytesPerSecond))\n\(formatNetworkSpeed(sample.downloadBytesPerSecond))",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private func installNetworkSpeedButtonContent(in button: NSStatusBarButton, title: NSAttributedString) {
        button.image = nil
        button.attributedTitle = NSAttributedString(string: "")

        let contentView: NSView
        let label: NSTextField
        let imageView: NSImageView
        if let existingContentView = networkSpeedContentView,
           let existingLabel = networkSpeedLabel,
           let existingImageView = networkSpeedImageView {
            contentView = existingContentView
            label = existingLabel
            imageView = existingImageView
        } else {
            label = NSTextField(labelWithAttributedString: title)
            label.alignment = .center
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byClipping
            label.translatesAutoresizingMaskIntoConstraints = false

            imageView = NSImageView(image: statusIcon() ?? NSImage())
            imageView.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = .labelColor
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
            imageView.translatesAutoresizingMaskIntoConstraints = false

            contentView = NSView()
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
            contentView.addSubview(imageView)
            button.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                contentView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 1),
                imageView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 7),
                imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18)
            ])

            networkSpeedContentView = contentView
            networkSpeedLabel = label
            networkSpeedImageView = imageView
        }

        label.attributedStringValue = title
        label.invalidateIntrinsicContentSize()
        imageView.image = statusIcon()
        imageView.image?.isTemplate = true
        contentView.isHidden = false
    }

    private func removeNetworkSpeedButtonContent() {
        networkSpeedContentView?.removeFromSuperview()
        networkSpeedContentView = nil
        networkSpeedLabel = nil
        networkSpeedImageView = nil
    }

    private func networkSpeedButtonWidth(for title: NSAttributedString) -> CGFloat {
        ceil(title.size().width) + 18 + 7 + 8
    }

    private func formatNetworkSpeed(_ bytesPerSecond: UInt64) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSecond)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if value.rounded(.down) == value || value >= 100 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return "\(String(format: "%.1f", value)) \(units[unitIndex])"
    }

    private func observeDefaultsChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.statusItem.menu = self?.makeMenu()
                self?.refreshStatusItemConfiguration()
                self?.inputCorrectionManager.refresh()
                self?.clipboardManager.refresh()
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Orb")

        addWindowOperationItem(
            to: menu,
            operation: .leftHalf,
            action: #selector(moveFocusedWindowLeftHalf),
            keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        )
        addWindowOperationItem(
            to: menu,
            operation: .rightHalf,
            action: #selector(moveFocusedWindowRightHalf),
            keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        )
        addWindowOperationItem(
            to: menu,
            operation: .maximized,
            action: #selector(maximizeFocusedWindow),
            keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        )
        addWindowOperationItem(
            to: menu,
            operation: .centered,
            action: #selector(centerFocusedWindow),
            keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        )
        addWindowOperationItem(
            to: menu,
            operation: .minimizeOthers,
            action: #selector(minimizeOtherApplicationWindows),
            keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
            modifierMask: [.command, .option]
        )
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: "打开 Orb",
            action: #selector(showMainWindow),
            keyEquivalent: "o"
        )
        menu.addItem(
            withTitle: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        return menu
    }

    private func addWindowOperationItem(
        to menu: NSMenu,
        operation: WindowOperation,
        action: Selector,
        keyEquivalent: String = "",
        modifierMask: NSEvent.ModifierFlags = [.command]
    ) {
        guard WindowOperationConfiguration.isEnabled(operation) else { return }
        let item = NSMenuItem(title: operation.title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifierMask
        item.image = NSImage(systemSymbolName: operation.symbolName, accessibilityDescription: operation.title)
        item.image?.isTemplate = true
        menu.addItem(item)
    }

    private func installApplicationScripts() {
        guard let resourceURL = Bundle.main.resourceURL else {
            NSLog("[Orb] Missing bundle resources")
            return
        }

        let scriptsSource = resourceURL.appendingPathComponent("Scripts", isDirectory: true)
        let templatesSource = resourceURL.appendingPathComponent("Templates", isDirectory: true)
        let scriptsDestination = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Scripts/\(finderSyncBundleIdentifier)", isDirectory: true)

        do {
            try syncManagedDirectoryContents(from: scriptsSource, to: scriptsDestination, executable: true)
            try syncManagedDirectoryContents(from: templatesSource, to: scriptsDestination, executable: false)
            removeLegacyMoveState()
            MenuActionConfiguration.writeEnabledIDs(MenuActionConfiguration.enabledIDs())
            NSLog("[Orb] Installed scripts to \(scriptsDestination.path)")
        } catch {
            NSLog("[Orb] Failed to install scripts: \(error)")
        }
    }

    private var finderSyncExtensionURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("OrbFinderSync.appex", isDirectory: true)
    }

    private func setFinderExtensionEnabled(_ isEnabled: Bool) {
        if isEnabled, let extensionURL = finderSyncExtensionURL {
            _ = runTool("/usr/bin/pluginkit", arguments: ["-a", extensionURL.path])
        }
        _ = runTool("/usr/bin/pluginkit", arguments: ["-e", isEnabled ? "use" : "ignore", "-i", finderSyncBundleIdentifier])
        if !isEnabled {
            _ = runTool("/usr/bin/pkill", arguments: ["-f", "OrbFinderSync.appex"])
        }
    }

    private func disableFinderExtensionForTermination() {
        guard !didDisableFinderExtensionForTermination else { return }
        didDisableFinderExtensionForTermination = true
        setFinderExtensionEnabled(false)
    }

    private func runTool(_ launchPath: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[Orb] Failed to run \(launchPath): \(error)")
            return false
        }
    }

    private func removeLegacyMoveState() {
        let stateDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orb", isDirectory: true)
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private var scriptsDirectoryURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Scripts/\(finderSyncBundleIdentifier)", isDirectory: true)
    }

    private var popoverEventURL: URL {
        scriptsDirectoryURL.appendingPathComponent("popover-event.txt")
    }

    private func startPopoverEventWatcher() {
        do {
            try FileManager.default.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[Orb] Failed to create scripts directory for popover watcher: \(error)")
            return
        }

        eventDirectoryDescriptor = open(scriptsDirectoryURL.path, O_EVTONLY)
        guard eventDirectoryDescriptor >= 0 else {
            NSLog("[Orb] Failed to watch popover event directory")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: eventDirectoryDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.schedulePopoverEventRead()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.eventDirectoryDescriptor >= 0 else { return }
            close(self.eventDirectoryDescriptor)
            self.eventDirectoryDescriptor = -1
        }
        eventSource = source
        source.resume()
    }

    private func schedulePopoverEventRead() {
        eventReadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.readPopoverEvent()
        }
        eventReadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func readPopoverEvent() {
        guard let content = try? String(contentsOf: popoverEventURL, encoding: .utf8) else {
            return
        }
        guard content != lastPopoverEventContent else {
            return
        }
        lastPopoverEventContent = content

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else { return }

        let kind: MenuBarNotificationView.Kind = lines[0] == "error" ? .error : .success
        let actionID: String
        let title: String
        let subtitle: String
        if lines.count >= 4 {
            actionID = lines[1]
            title = lines[2]
            subtitle = lines[3]
        } else {
            actionID = "generic"
            title = lines[1]
            subtitle = lines[2]
        }
        showMenuBarPopover(title: title, subtitle: subtitle, actionID: actionID, kind: kind)
    }

    private func showMenuBarPopover(
        title: String,
        subtitle: String,
        actionID: String,
        kind: MenuBarNotificationView.Kind
    ) {
        guard let button = statusItem.button else { return }

        notificationDismissWorkItem?.cancel()
        notificationPopover?.close()

        let hosting = NSHostingController(
            rootView: MenuBarNotificationView(title: title, subtitle: subtitle, actionID: actionID, kind: kind)
        )
        hosting.view.frame = NSRect(x: 0, y: 0, width: 280, height: 200)
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 280, height: fitted.height)
        notificationPopover = popover

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.makeKey()
        }

        let work = DispatchWorkItem { [weak self] in
            self?.notificationPopover?.close()
        }
        notificationDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + notificationSeconds, execute: work)
    }

    private func syncManagedDirectoryContents(from source: URL, to destination: URL, executable: Bool) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let itemURLs = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let sourceNames = Set(itemURLs.map(\.lastPathComponent))

        if executable {
            let destinationURLs = try fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for destinationURL in destinationURLs
                where destinationURL.pathExtension == "sh" && !sourceNames.contains(destinationURL.lastPathComponent) {
                try fileManager.removeItem(at: destinationURL)
            }
        }

        for itemURL in itemURLs {
            let targetURL = destination.appendingPathComponent(itemURL.lastPathComponent)
            if fileManager.fileExists(atPath: targetURL.path),
               !fileManager.contentsEqual(atPath: itemURL.path, andPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
                try fileManager.copyItem(at: itemURL, to: targetURL)
            } else if !fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.copyItem(at: itemURL, to: targetURL)
            }
            if executable {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o755))],
                    ofItemAtPath: targetURL.path
                )
            }
        }
    }

    @objc private func showMainWindow() {
        mainWindowController.show()
    }

    @objc private func moveFocusedWindowLeftHalf() {
        windowOperationManager.moveFocusedWindowLeftHalf()
    }

    @objc private func moveFocusedWindowRightHalf() {
        windowOperationManager.moveFocusedWindowRightHalf()
    }

    @objc private func maximizeFocusedWindow() {
        windowOperationManager.maximizeFocusedWindow()
    }

    @objc private func centerFocusedWindow() {
        windowOperationManager.centerFocusedWindow()
    }

    @objc private func minimizeOtherApplicationWindows() {
        windowOperationManager.minimizeOtherApplicationWindows()
    }

    @objc private func quit() {
        disableFinderExtensionForTermination()
        NSApp.terminate(nil)
    }
}
