import Cocoa
import FinderSync

@objc(FinderSyncExt)
final class FinderSyncExt: FIFinderSync {
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
    private var iconCache: [String: NSImage] = [:]

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let submenu = NSMenu(title: "Orb")

        let appearance = NSAppearance.currentDrawing()
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tint: NSColor = isDark ? .white : .black

        let enabledServiceIDs = enabledServiceIDs
        guard !enabledServiceIDs.isEmpty else {
            return menu
        }

        for (index, service) in services.enumerated() where enabledServiceIDs.contains(service.id) {
            let item = NSMenuItem(
                title: service.title,
                action: #selector(runScript(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            if let image = cachedMenuIcon(for: service, color: tint, isDark: isDark) {
                item.image = image
            }
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: "Orb", action: nil, keyEquivalent: "")
        if let image = cachedSymbol("circle.fill", color: tint, isDark: isDark, glyphSize: 10) {
            parent.image = image
        }
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

    private func cachedMenuIcon(for service: Service, color: NSColor, isDark: Bool) -> NSImage? {
        let cacheKey = "\(isDark ? "dark" : "light"):\(service.assetName ?? service.symbol)"
        if let cached = iconCache[cacheKey] {
            return cached
        }
        guard let image = menuIcon(for: service, color: color) else {
            return nil
        }
        iconCache[cacheKey] = image
        return image
    }

    private func cachedSymbol(_ name: String, color: NSColor, isDark: Bool, glyphSize: CGFloat = 16) -> NSImage? {
        let cacheKey = "\(isDark ? "dark" : "light"):\(name):\(glyphSize)"
        if let cached = iconCache[cacheKey] {
            return cached
        }
        guard let image = tintedSymbol(name, color: color, glyphSize: glyphSize) else {
            return nil
        }
        iconCache[cacheKey] = image
        return image
    }

    private func menuIcon(for service: Service, color: NSColor) -> NSImage? {
        if let assetName = service.assetName,
           let image = tintedAsset(assetName, color: color) {
            return image
        }
        return tintedSymbol(service.symbol, color: color)
    }

    private func tintedAsset(_ name: String, color: NSColor) -> NSImage? {
        guard let source = NSImage(named: NSImage.Name(name)) else {
            return nil
        }
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func tintedSymbol(_ name: String, color: NSColor, glyphSize: CGFloat = 16) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let imageSize = NSSize(width: 16, height: 16)
        return NSImage(size: imageSize, flipped: false) { rect in
            let inset = max((rect.width - glyphSize) / 2, 0)
            let glyphRect = rect.insetBy(dx: inset, dy: inset)
            symbol.draw(in: glyphRect)
            color.set()
            glyphRect.fill(using: .sourceAtop)
            return true
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
