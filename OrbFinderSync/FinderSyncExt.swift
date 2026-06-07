import Cocoa
import Darwin
import FinderSync

@objc(FinderSyncExt)
final class FinderSyncExt: FIFinderSync {
    private struct SubtitleJob: Decodable {
        let path: String
        let scriptPID: Int32?
        let childPID: Int32?
    }

    private struct Service {
        let id: String
        let title: String
        let filename: String
        let symbol: String
        let assetName: String?
        let allowsEmpty: Bool
    }

    private let services: [Service] = [
        Service(id: "subtitles", title: "生成字幕", filename: "gen_subtitles.sh", symbol: "captions.bubble", assetName: nil, allowsEmpty: false),
        Service(id: "remove-subtitles", title: "移除字幕", filename: "remove_subtitles.sh", symbol: "captions.bubble", assetName: nil, allowsEmpty: false),
        Service(id: "stop-subtitles", title: "停止生成字幕", filename: "stop_subtitles.sh", symbol: "stop.circle", assetName: nil, allowsEmpty: false),
        Service(id: "new-text", title: "新建文本文件", filename: "new_txt.sh", symbol: "doc.text", assetName: nil, allowsEmpty: false),
        Service(id: "new-markdown", title: "新建 Markdown 文件", filename: "new_md.sh", symbol: "chevron.left.forwardslash.chevron.right", assetName: "logo-markdown", allowsEmpty: false),
        Service(id: "new-word", title: "新建 Word 文档", filename: "new_docx.sh", symbol: "doc.richtext", assetName: nil, allowsEmpty: false),
        Service(id: "open-ghostty", title: "用 Ghostty 打开", filename: "open_ghostty.sh", symbol: "terminal", assetName: "logo-ghostty", allowsEmpty: false),
        Service(id: "open-vscode", title: "用 VS Code 打开", filename: "open_vscode.sh", symbol: "curlybraces", assetName: "logo-vscode", allowsEmpty: false),
        Service(id: "git-commit-push", title: "提交并推送当前仓库", filename: "git_commit_push.sh", symbol: "arrow.up.doc", assetName: "logo-github", allowsEmpty: false),
        Service(id: "copy-path", title: "复制路径", filename: "copy_path.sh", symbol: "point.topleft.down.curvedto.point.bottomright.up", assetName: nil, allowsEmpty: false)
    ]

    private static let logQueue = DispatchQueue(label: "com.eli.Orb.findersync.log")
    private static let logMaxBytes: UInt64 = 1 * 1024 * 1024
    private static let menuIconSize = NSSize(width: 18, height: 18)
    private var iconCache: [String: NSImage] = [:]

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let submenu = NSMenu(title: "Orb")

        let enabledServiceIDs = enabledServiceIDs
        guard !enabledServiceIDs.isEmpty else {
            return menu
        }
        let selectedTargets = currentTargetURLs()
        let canStopSubtitles = hasActiveSubtitleJob(for: selectedTargets)

        for (index, service) in services.enumerated() where enabledServiceIDs.contains(service.id) {
            if service.id == "stop-subtitles", !canStopSubtitles {
                continue
            }
            let item = NSMenuItem(
                title: service.title,
                action: #selector(runScript(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            if let image = cachedMenuIcon(for: service) {
                item.image = image
            }
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: "Orb", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    private var enabledServiceIDs: Set<String> {
        do {
            let scriptsURL = try FileManager.default.url(
                for: .applicationScriptsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            let configURL = scriptsURL.appendingPathComponent("menu-actions.json")
            let data = try Data(contentsOf: configURL)
            let ids = try JSONDecoder().decode([String].self, from: data)
            return Set(ids)
        } catch {
            return Set(services.map(\.id))
        }
    }

    private func currentTargetURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        if !selected.isEmpty {
            return selected
        }
        return controller.targetedURL().map { [$0] } ?? []
    }

    private func hasActiveSubtitleJob(for targets: [URL]) -> Bool {
        let targetPaths = Set(targets.map(\.path))
        guard !targetPaths.isEmpty else {
            return false
        }
        return activeSubtitleJobs().contains { job in
            targetPaths.contains(job.path)
        }
    }

    private func activeSubtitleJobs() -> [SubtitleJob] {
        guard let stateDirectory = subtitleJobsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: stateDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let job = try? JSONDecoder().decode(SubtitleJob.self, from: data),
                  isProcessRunning(job.scriptPID) || isProcessRunning(job.childPID) else {
                return nil
            }
            return job
        }
    }

    private func subtitleJobsDirectory() -> URL? {
        do {
            return try FileManager.default
                .url(
                    for: .applicationScriptsDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
                .appendingPathComponent("subtitle-jobs", isDirectory: true)
        } catch {
            return nil
        }
    }

    private func isProcessRunning(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else {
            return false
        }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func cachedMenuIcon(for service: Service) -> NSImage? {
        let cacheKey = "round:\(service.id):\(service.assetName ?? service.symbol)"
        if let cached = iconCache[cacheKey] {
            return cached
        }
        guard let image = menuIcon(for: service) else {
            return nil
        }
        iconCache[cacheKey] = image
        return image
    }

    private func menuIcon(for service: Service) -> NSImage? {
        let colors = menuIconColors(for: service.id)
        let size = Self.menuIconSize
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            let circleRect = rect.insetBy(dx: 1, dy: 1)
            let circlePath = NSBezierPath(ovalIn: circleRect)
            if let gradient = NSGradient(colors: colors) {
                gradient.draw(in: circlePath, angle: -45)
            } else {
                colors.first?.setFill()
                circlePath.fill()
            }

            if let assetName = service.assetName,
               let source = NSImage(named: NSImage.Name(assetName)) {
                self.drawTemplateImage(source, in: self.glyphRect(for: service, in: rect), on: rect, color: .white)
            } else if let symbol = NSImage(systemSymbolName: service.symbol, accessibilityDescription: nil) {
                let configuredSymbol = symbol.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: self.symbolPointSize(for: service.id), weight: .semibold)
                ) ?? symbol
                self.drawTemplateImage(configuredSymbol, in: self.glyphRect(for: service, in: rect), on: rect, color: .white)
            }
            return true
        }
    }

    private func drawTemplateImage(_ image: NSImage, in rect: NSRect, on canvasRect: NSRect, color: NSColor) {
        let glyph = NSImage(size: canvasRect.size, flipped: false) { glyphCanvasRect in
            let sourceRect = NSRect(origin: .zero, size: image.size)
            image.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
            color.set()
            glyphCanvasRect.fill(using: .sourceAtop)
            return true
        }
        glyph.draw(in: canvasRect, from: NSRect(origin: .zero, size: glyph.size), operation: .sourceOver, fraction: 1)
    }

    private func glyphRect(for service: Service, in rect: NSRect) -> NSRect {
        let padding = iconPadding(for: service.id, hasAsset: service.assetName != nil)
        return rect.insetBy(dx: padding, dy: padding)
    }

    private func iconPadding(for serviceID: String, hasAsset: Bool) -> CGFloat {
        switch serviceID {
        case "new-markdown", "git-commit-push":
            return 4.2
        case "copy-path":
            return 4.5
        default:
            return hasAsset ? 4.6 : 4.3
        }
    }

    private func symbolPointSize(for serviceID: String) -> CGFloat {
        switch serviceID {
        case "copy-path":
            return 9
        default:
            return 9.8
        }
    }

    private func menuIconColors(for serviceID: String) -> [NSColor] {
        switch serviceID {
        case "new-text":
            return [
                NSColor(red: 0.48, green: 0.58, blue: 0.70, alpha: 1),
                NSColor(red: 0.25, green: 0.34, blue: 0.48, alpha: 1)
            ]
        case "new-markdown":
            return [
                NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1),
                NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
            ]
        case "new-word":
            return [
                NSColor(red: 0.22, green: 0.46, blue: 0.96, alpha: 1),
                NSColor(red: 0.07, green: 0.22, blue: 0.68, alpha: 1)
            ]
        case "open-ghostty":
            return [
                NSColor(red: 0.28, green: 0.26, blue: 0.34, alpha: 1),
                NSColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)
            ]
        case "open-vscode":
            return [
                NSColor(red: 0.15, green: 0.55, blue: 0.92, alpha: 1),
                NSColor(red: 0.00, green: 0.32, blue: 0.67, alpha: 1)
            ]
        case "git-commit-push":
            return [
                NSColor(red: 0.98, green: 0.42, blue: 0.22, alpha: 1),
                NSColor(red: 0.76, green: 0.18, blue: 0.12, alpha: 1)
            ]
        case "copy-path":
            return [
                NSColor(red: 0.98, green: 0.50, blue: 0.36, alpha: 1),
                NSColor(red: 0.83, green: 0.22, blue: 0.18, alpha: 1)
            ]
        default:
            return [
                NSColor(red: 0.18, green: 0.78, blue: 0.35, alpha: 1),
                NSColor(red: 0.12, green: 0.64, blue: 0.28, alpha: 1)
            ]
        }
    }

    private static func debugLog(_ message: String) {
        NSLog("[Orb] \(message)")
        let logPath = ("~/Library/Logs/orb-findersync.log" as NSString)
            .expandingTildeInPath
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        logQueue.async { [maxBytes = logMaxBytes] in
            let fileManager = FileManager.default
            if let attrs = try? fileManager.attributesOfItem(atPath: logPath),
               let size = attrs[.size] as? UInt64,
               size > maxBytes {
                let rotated = logPath + ".1"
                try? fileManager.removeItem(atPath: rotated)
                try? fileManager.moveItem(atPath: logPath, toPath: rotated)
            }

            if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                defer { try? fileHandle.close() }
                _ = try? fileHandle.seekToEnd()
                try? fileHandle.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    @objc private func runScript(_ sender: NSMenuItem) {
        Self.debugLog("runScript fired: \(sender.title) tag=\(sender.tag)")
        guard sender.tag >= 0 && sender.tag < services.count else {
            Self.debugLog("tag out of range")
            return
        }

        let service = services[sender.tag]
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []

        var targets: [String] = []
        if !selected.isEmpty {
            targets = selected.map(\.path)
        } else if !service.allowsEmpty, let target = controller.targetedURL() {
            targets = [target.path]
        }
        Self.debugLog("targets: \(targets)")

        guard !targets.isEmpty || service.allowsEmpty else {
            Self.debugLog("no target")
            return
        }

        do {
            let scriptsURL = try FileManager.default.url(
                for: .applicationScriptsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let scriptURL = scriptsURL.appendingPathComponent(service.filename)
            Self.debugLog("scriptURL: \(scriptURL.path)")
            let task = try NSUserUnixTask(url: scriptURL)
            task.execute(withArguments: targets) { error in
                if let error {
                    Self.debugLog("script error: \(error)")
                } else {
                    Self.debugLog("script ok")
                }
            }
        } catch {
            Self.debugLog("run failed: \(error)")
        }
    }
}
