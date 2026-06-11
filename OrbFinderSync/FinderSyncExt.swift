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
        let allowsEmpty: Bool
    }

    private let services: [Service] = [
        Service(id: "subtitles", title: "生成字幕", filename: "gen_subtitles.sh", allowsEmpty: false),
        Service(id: "remove-subtitles", title: "移除字幕", filename: "remove_subtitles.sh", allowsEmpty: false),
        Service(id: "stop-subtitles", title: "停止生成字幕", filename: "stop_subtitles.sh", allowsEmpty: false),
        Service(id: "new-text", title: "新建文本文件", filename: "new_txt.sh", allowsEmpty: false),
        Service(id: "new-markdown", title: "新建 Markdown 文件", filename: "new_md.sh", allowsEmpty: false),
        Service(id: "new-word", title: "新建 Word 文档", filename: "new_docx.sh", allowsEmpty: false),
        Service(id: "open-ghostty", title: "用 Ghostty 打开", filename: "open_ghostty.sh", allowsEmpty: false),
        Service(id: "open-vscode", title: "用 VS Code 打开", filename: "open_vscode.sh", allowsEmpty: false),
        Service(id: "git-commit-push", title: "提交并推送当前仓库", filename: "git_commit_push.sh", allowsEmpty: false),
        Service(id: "copy-path", title: "复制路径", filename: "copy_path.sh", allowsEmpty: false)
    ]

    private static let logQueue = DispatchQueue(label: "com.eli.Orb.findersync.log")
    private static let logMaxBytes: UInt64 = 1 * 1024 * 1024

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
