import AppKit
import SwiftUI

private let finderSyncBundleIdentifier = "com.eli.Orb.FinderSync"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let leftArrowKeyEquivalent = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrowKeyEquivalent = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    private static let upArrowKeyEquivalent = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrowKeyEquivalent = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private enum MenuBarPopoverMode {
        case notification
        case subtitleProgress
        case subtitleCompletion
    }

    private struct SubtitleMenuBarProgress {
        var fraction: Double
        var title: String
        var subtitle: String
        var remainingText: String
        var completionTitle: String?
        var completionSubtitle: String?
        var completionKind: MenuBarNotificationView.Kind = .success

        var isComplete: Bool {
            completionTitle != nil
        }
    }

    private let notificationSeconds: TimeInterval = 5
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var mainWindowController = OrbWindowController()
    private let windowOperationManager = WindowOperationManager()
    private let networkSpeedMonitor = NetworkSpeedMonitor()
    private let inputCorrectionManager = InputCorrectionManager()
    private var notificationPopover: NSPopover?
    private var notificationPopoverMode: MenuBarPopoverMode?
    private var notificationDismissWorkItem: DispatchWorkItem?
    private var eventReadWorkItem: DispatchWorkItem?
    private var lastPopoverEventContent = ""
    private var isClosingNotificationPopoverProgrammatically = false
    private var suppressSubtitleProgressPopover = false
    private var eventSource: DispatchSourceFileSystemObject?
    private var eventDirectoryDescriptor: CInt = -1
    private var didDisableFinderExtensionForTermination = false
    private var defaultsObserver: NSObjectProtocol?
    private var moduleStateObserver: NSObjectProtocol?
    private var isShowingNetworkSpeed = false
    private var currentNetworkSpeedSample = NetworkSpeedSample(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
    private var networkSpeedContentView: NSStackView?
    private var networkSpeedLabel: NSTextField?
    private var networkSpeedImageView: NSImageView?
    private var subtitleMenuBarProgress: SubtitleMenuBarProgress?
    private var shouldClearSubtitleProgressWhenPopoverCloses = false
    private var pendingSubtitlePopoverWorkItem: DispatchWorkItem?
    private let statusButtonIconSize: CGFloat = 18
    private let statusIconImageSize: CGFloat = 15
    private let statusButtonLabelSpacing: CGFloat = 7
    private let statusButtonHorizontalPadding: CGFloat = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        configureStatusItem()
        installApplicationScripts()
        OrbModuleHost.shared.reloadModules()
        OrbModuleHost.shared.startWatchingUserModules()
        syncFinderExtensionAvailability()
        syncWindowOperationManager()
        inputCorrectionManager.refresh()
        OrbModuleHost.shared.startEnabledExecutableModules()
        observeDefaultsChanges()
        observeModuleStateChanges()
        startPopoverEventWatcher()
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let moduleStateObserver {
            NotificationCenter.default.removeObserver(moduleStateObserver)
        }
        OrbModuleHost.shared.stopEnabledExecutableModules()
        networkSpeedMonitor.stop()
        inputCorrectionManager.stop()
        windowOperationManager.stop()
        disableFinderExtensionForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
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
        statusItem.menu = nil
    }

    private func refreshStatusItemConfiguration() {
        let shouldShowNetworkSpeed = MenuBarConfiguration.isEnabled() && MenuBarConfiguration.showsNetworkSpeed()
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
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: StatusItemClickHandling.actionEventMask)

        let title = isShowingNetworkSpeed ? networkSpeedTitle(for: currentNetworkSpeedSample) : nil
        if title == nil {
            removeNetworkSpeedButtonContent()
            button.image = statusIcon()
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            statusItem.length = NSStatusItem.variableLength
            return
        }

        statusItem.length = statusButtonWidth(for: title)
        installStatusButtonContent(in: button, networkSpeedTitle: title)
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
    }

    private func statusIcon() -> NSImage? {
        if let state = subtitleMenuBarProgress {
            if state.isComplete {
                return subtitleCompletionStatusIcon(for: state)
            }
            return subtitleProgressStatusIcon(fraction: state.fraction)
        }

        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Orb")
        image?.isTemplate = true
        return image
    }

    private func subtitleCompletionStatusIcon(for state: SubtitleMenuBarProgress) -> NSImage? {
        let symbolName = state.completionKind == .error ? "xmark.circle.fill" : "checkmark.circle.fill"
        let description = state.completionKind == .error ? "字幕失败" : "字幕完成"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    private func subtitleProgressStatusIcon(fraction: Double) -> NSImage {
        let size = NSSize(width: statusIconImageSize, height: statusIconImageSize)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2
        let lineWidth: CGFloat = 2.2

        let trackPath = NSBezierPath()
        trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        trackPath.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.26).setStroke()
        trackPath.stroke()

        let progressPath = NSBezierPath()
        progressPath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * min(max(fraction, 0.01), 1),
            clockwise: true
        )
        progressPath.lineWidth = lineWidth
        progressPath.lineCapStyle = .round
        NSColor.black.setStroke()
        progressPath.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
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

    private func installStatusButtonContent(in button: NSStatusBarButton, networkSpeedTitle title: NSAttributedString?) {
        button.image = nil
        button.attributedTitle = NSAttributedString(string: "")

        let contentView: NSStackView
        let label: NSTextField
        let imageView: NSImageView
        if let existingContentView = networkSpeedContentView,
           let existingLabel = networkSpeedLabel,
           let existingImageView = networkSpeedImageView {
            contentView = existingContentView
            label = existingLabel
            imageView = existingImageView
        } else {
            label = NSTextField(labelWithString: "")
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

            contentView = NSStackView(views: [label, imageView])
            contentView.orientation = .horizontal
            contentView.alignment = .centerY
            contentView.spacing = statusButtonLabelSpacing
            contentView.detachesHiddenViews = true
            contentView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                contentView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: statusButtonIconSize),
                imageView.heightAnchor.constraint(equalToConstant: statusButtonIconSize)
            ])

            networkSpeedContentView = contentView
            networkSpeedLabel = label
            networkSpeedImageView = imageView
        }

        contentView.setCustomSpacing(statusButtonLabelSpacing, after: label)
        if let title {
            label.attributedStringValue = title
            label.isHidden = false
        } else {
            label.attributedStringValue = NSAttributedString(string: "")
            label.isHidden = true
        }
        label.invalidateIntrinsicContentSize()
        imageView.image = statusIcon()
        contentView.isHidden = false
    }

    private func removeNetworkSpeedButtonContent() {
        networkSpeedContentView?.removeFromSuperview()
        networkSpeedContentView = nil
        networkSpeedLabel = nil
        networkSpeedImageView = nil
    }

    private func statusButtonWidth(for title: NSAttributedString?) -> CGFloat {
        let labelWidth = title.map { ceil($0.size().width) + statusButtonLabelSpacing } ?? 0
        return labelWidth + statusButtonIconSize + statusButtonHorizontalPadding * 2
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
                self?.statusItem.menu = nil
                OrbModuleHost.shared.refreshEnabledStates()
                self?.syncFinderExtensionAvailability()
                self?.syncWindowOperationManager()
                self?.refreshStatusItemConfiguration()
                self?.inputCorrectionManager.refresh()
            }
        }
    }

    private func observeModuleStateChanges() {
        moduleStateObserver = NotificationCenter.default.addObserver(
            forName: OrbModuleHost.moduleStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.statusItem.menu = nil
                self?.syncFinderExtensionAvailability()
                self?.syncWindowOperationManager()
                self?.refreshStatusItemConfiguration()
                self?.inputCorrectionManager.refresh()
            }
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        guard let event = NSApp.currentEvent else {
            return
        }

        switch StatusItemClickHandling.action(for: event.type) {
        case .secondary:
            popUpStatusItemMenu(in: button)
        case .primary:
            handleStatusItemPrimaryClick()
        case .ignore:
            return
        }
    }

    private func handleStatusItemPrimaryClick() {
        guard let state = subtitleMenuBarProgress else {
            if let button = statusItem.button {
                popUpStatusItemMenu(in: button)
            }
            return
        }
        if state.isComplete {
            clearSubtitleCompletionFromStatusItemClick()
            return
        }
        showSubtitleMenuBarPopover(userInitiated: true)
    }

    private func clearSubtitleCompletionFromStatusItemClick() {
        if notificationPopoverMode == .subtitleCompletion {
            shouldClearSubtitleProgressWhenPopoverCloses = false
            closeNotificationPopoverProgrammatically()
        }
        clearSubtitleMenuBarProgress()
    }

    private func popUpStatusItemMenu(in button: NSStatusBarButton) {
        makeMenu().popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
            in: button
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Orb")

        addWindowOperationItem(
            to: menu,
            operation: .leftHalf,
            action: #selector(moveFocusedWindowLeftHalf),
            keyEquivalent: Self.leftArrowKeyEquivalent
        )
        addWindowOperationItem(
            to: menu,
            operation: .rightHalf,
            action: #selector(moveFocusedWindowRightHalf),
            keyEquivalent: Self.rightArrowKeyEquivalent
        )
        addWindowOperationItem(
            to: menu,
            operation: .maximized,
            action: #selector(maximizeFocusedWindow),
            keyEquivalent: Self.upArrowKeyEquivalent
        )
        addWindowOperationItem(
            to: menu,
            operation: .centered,
            action: #selector(centerFocusedWindow),
            keyEquivalent: Self.downArrowKeyEquivalent
        )
        addWindowOperationItem(
            to: menu,
            operation: .minimizeOthers,
            action: #selector(minimizeOtherApplicationWindows),
            keyEquivalent: Self.downArrowKeyEquivalent,
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
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags = .command
    ) {
        guard WindowOperationConfiguration.isEnabled(operation) else { return }
        let item = NSMenuItem(title: operation.title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifierMask
        item.target = self
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

    private func syncFinderExtensionAvailability() {
        setFinderExtensionEnabled(MenuActionConfiguration.isEnabled())
    }

    private func syncWindowOperationManager() {
        if WindowOperationConfiguration.isEnabled() {
            windowOperationManager.start()
        } else {
            windowOperationManager.stop()
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

        if lines[0] == "progress" {
            guard lines.count >= 6 else { return }
            let rawProgress = Double(lines[4]) ?? 0
            let actionID = lines[1]
            let subtitle = lines[3]
            let isNewSubtitleTask = actionID == "subtitles"
                && (subtitleMenuBarProgress == nil || subtitleMenuBarProgress?.isComplete == true || rawProgress <= 1)
            let progress = MenuBarNotificationView.ProgressState(
                fraction: menuBarProgressFraction(from: rawProgress, actionID: actionID),
                remainingText: lines[5]
            )
            if actionID == "subtitles" {
                if isNewSubtitleTask {
                    suppressSubtitleProgressPopover = false
                    shouldClearSubtitleProgressWhenPopoverCloses = false
                }
                subtitleMenuBarProgress = SubtitleMenuBarProgress(
                    fraction: progress.fraction,
                    title: lines[2],
                    subtitle: subtitle,
                    remainingText: progress.remainingText
                )
                refreshStatusItemButton()
                if isNewSubtitleTask {
                    showSubtitleMenuBarPopoverAfterStatusLayout(userInitiated: false)
                } else if notificationPopoverMode == .subtitleProgress,
                          notificationPopover?.isShown == true {
                    showSubtitleMenuBarPopover(userInitiated: false)
                }
            } else {
                showMenuBarPopover(
                    title: lines[2],
                    subtitle: subtitle,
                    actionID: actionID,
                    kind: .success,
                    progress: progress,
                    mode: .subtitleProgress
                )
            }
            return
        }

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
        if actionID == "subtitles" {
            suppressSubtitleProgressPopover = false
            let completionTitle = title
            subtitleMenuBarProgress = SubtitleMenuBarProgress(
                fraction: 1,
                title: completionTitle,
                subtitle: subtitle,
                remainingText: "完成",
                completionTitle: completionTitle,
                completionSubtitle: subtitle,
                completionKind: kind
            )
            refreshStatusItemButton()
            showSubtitleCompletionPopover(clearAfterClose: true)
            return
        }
        if actionID == "stop-subtitles", kind == .success {
            clearSubtitleMenuBarProgress()
        }
        showMenuBarPopover(title: title, subtitle: subtitle, actionID: actionID, kind: kind)
    }

    private func menuBarProgressFraction(from rawProgress: Double, actionID: String) -> Double {
        let fraction = actionID == "subtitles"
            ? rawProgress / 100
            : (rawProgress > 1 ? rawProgress / 100 : rawProgress)
        return min(max(fraction, 0), 1)
    }

    private func showSubtitleMenuBarPopoverAfterStatusLayout(userInitiated: Bool) {
        pendingSubtitlePopoverWorkItem?.cancel()
        var work: DispatchWorkItem?
        work = DispatchWorkItem { [weak self] in
            guard let self,
                  let currentWork = work,
                  !currentWork.isCancelled,
                  pendingSubtitlePopoverWorkItem === currentWork else {
                return
            }
            pendingSubtitlePopoverWorkItem = nil
            showSubtitleMenuBarPopover(userInitiated: userInitiated)
        }
        guard let work else { return }
        pendingSubtitlePopoverWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func showSubtitleMenuBarPopover(userInitiated: Bool) {
        guard let state = subtitleMenuBarProgress else { return }
        if state.isComplete {
            showSubtitleCompletionPopover(clearAfterClose: userInitiated)
            return
        }
        guard !suppressSubtitleProgressPopover || userInitiated else { return }
        let progress = MenuBarNotificationView.ProgressState(
            fraction: state.fraction,
            remainingText: state.remainingText
        )
        showMenuBarPopover(
            title: state.title,
            subtitle: state.subtitle,
            actionID: "subtitles",
            kind: .success,
            progress: progress,
            mode: .subtitleProgress,
            autoDismiss: !userInitiated
        )
    }

    private func showSubtitleCompletionPopover(clearAfterClose: Bool) {
        guard let state = subtitleMenuBarProgress,
              let title = state.completionTitle,
              let subtitle = state.completionSubtitle else { return }
        if clearAfterClose,
           notificationPopoverMode == .subtitleCompletion,
           notificationPopover?.isShown == true {
            shouldClearSubtitleProgressWhenPopoverCloses = true
            return
        }
        shouldClearSubtitleProgressWhenPopoverCloses = false
        showMenuBarPopover(
            title: title,
            subtitle: subtitle,
            actionID: "subtitles",
            kind: state.completionKind,
            mode: .subtitleCompletion,
            autoDismiss: true
        )
        shouldClearSubtitleProgressWhenPopoverCloses = clearAfterClose
    }

    private func showMenuBarPopover(
        title: String,
        subtitle: String,
        actionID: String,
        kind: MenuBarNotificationView.Kind,
        progress: MenuBarNotificationView.ProgressState? = nil,
        mode: MenuBarPopoverMode = .notification,
        autoDismiss: Bool? = nil
    ) {
        guard let button = statusItem.button else { return }

        if progress != nil,
           let popover = notificationPopover,
           popover.isShown,
           notificationPopoverMode == mode,
           let hosting = popover.contentViewController as? NSHostingController<MenuBarNotificationView> {
            if autoDismiss == false {
                notificationDismissWorkItem?.cancel()
                notificationDismissWorkItem = nil
            }
            hosting.rootView = MenuBarNotificationView(
                title: title,
                subtitle: subtitle,
                actionID: actionID,
                kind: kind,
                progress: progress
            )
            resizeMenuBarPopover(popover, hosting: hosting)
            return
        }

        notificationDismissWorkItem?.cancel()
        closeNotificationPopoverProgrammatically()

        let hosting = NSHostingController(
            rootView: MenuBarNotificationView(
                title: title,
                subtitle: subtitle,
                actionID: actionID,
                kind: kind,
                progress: progress
            )
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hosting
        resizeMenuBarPopover(popover, hosting: hosting)
        notificationPopover = popover
        notificationPopoverMode = mode

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        let shouldAutoDismiss = autoDismiss ?? (progress == nil)
        guard shouldAutoDismiss else { return }

        let work = DispatchWorkItem { [weak self, weak popover] in
            guard let popover else { return }
            self?.closeNotificationPopoverProgrammatically(popover)
        }
        notificationDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + notificationSeconds, execute: work)
    }

    private func closeNotificationPopoverProgrammatically(_ popover: NSPopover? = nil) {
        guard let popover = popover ?? notificationPopover else { return }
        let isCurrentPopover = notificationPopover === popover
        isClosingNotificationPopoverProgrammatically = true
        popover.close()
        isClosingNotificationPopoverProgrammatically = false
        if isCurrentPopover {
            if shouldClearSubtitleProgressWhenPopoverCloses,
               notificationPopoverMode == .subtitleCompletion {
                clearSubtitleMenuBarProgress()
            }
            notificationPopover = nil
            notificationPopoverMode = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              notificationPopover === popover else {
            return
        }
        if notificationPopoverMode == .subtitleProgress,
           !isClosingNotificationPopoverProgrammatically {
            suppressSubtitleProgressPopover = true
        }
        if shouldClearSubtitleProgressWhenPopoverCloses,
           notificationPopoverMode == .subtitleCompletion {
            clearSubtitleMenuBarProgress()
        }
        notificationPopover = nil
        notificationPopoverMode = nil
    }

    private func clearSubtitleMenuBarProgress() {
        pendingSubtitlePopoverWorkItem?.cancel()
        pendingSubtitlePopoverWorkItem = nil
        subtitleMenuBarProgress = nil
        shouldClearSubtitleProgressWhenPopoverCloses = false
        refreshStatusItemButton()
    }

    private func resizeMenuBarPopover(
        _ popover: NSPopover,
        hosting: NSHostingController<MenuBarNotificationView>
    ) {
        let width: CGFloat = 280
        let fitted = hosting.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
        popover.contentSize = NSSize(width: width, height: ceil(fitted.height))
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
        windowOperationManager.suppressWindowOperations()
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
