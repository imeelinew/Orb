import Foundation

struct MenuAction: Identifiable, Hashable {
    let id: String
    let title: String
    let filename: String
    let symbolName: String
    let allowsEmpty: Bool

    static let all: [MenuAction] = [
        MenuAction(id: "subtitles", title: "生成字幕", filename: "gen_subtitles.sh", symbolName: "captions.bubble", allowsEmpty: false),
        MenuAction(id: "new-text", title: "新建文本文件", filename: "new_txt.sh", symbolName: "doc.text", allowsEmpty: false),
        MenuAction(id: "new-markdown", title: "新建 Markdown 文件", filename: "new_md.sh", symbolName: "doc.badge.plus", allowsEmpty: false),
        MenuAction(id: "new-word", title: "新建 Word 文档", filename: "new_docx.sh", symbolName: "doc.richtext", allowsEmpty: false),
        MenuAction(id: "open-ghostty", title: "用 Ghostty 打开", filename: "open_ghostty.sh", symbolName: "terminal", allowsEmpty: false),
        MenuAction(id: "open-vscode", title: "用 VS Code 打开", filename: "open_vscode.sh", symbolName: "curlybraces", allowsEmpty: false),
        MenuAction(id: "git-commit-push", title: "提交并推送当前仓库", filename: "git_commit_push.sh", symbolName: "arrow.up.doc", allowsEmpty: false),
        MenuAction(id: "copy-path", title: "复制路径", filename: "copy_path.sh", symbolName: "point.topleft.down.curvedto.point.bottomright.up", allowsEmpty: false)
    ]
}

enum MenuActionConfiguration {
    static let isEnabledKey = "contextMenuEnabled"
    static let enabledIDsKey = "enabledMenuActionIDs"
    static let filename = "menu-actions.json"
    static let extensionBundleIdentifier = "com.eli.Orb.FinderSync"

    static var defaultIsEnabled: Bool {
        true
    }

    static var defaultEnabledIDs: Set<String> {
        Set(MenuAction.all.map(\.id))
    }

    static func isEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: isEnabledKey) != nil else {
            return defaultIsEnabled
        }
        return UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    static func setEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: isEnabledKey)
    }

    static func enabledIDs() -> Set<String> {
        guard UserDefaults.standard.object(forKey: enabledIDsKey) != nil else {
            return defaultEnabledIDs
        }
        let stored = UserDefaults.standard.stringArray(forKey: enabledIDsKey) ?? []
        return Set(stored)
    }

    static func setEnabledIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: enabledIDsKey)
    }

    static func configurationURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Scripts/\(extensionBundleIdentifier)", isDirectory: true)
            .appendingPathComponent(filename)
    }

    static func writeEnabledIDs(_ ids: Set<String>, isEnabled: Bool = isEnabled()) {
        do {
            let url = configurationURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let enabledIDs = isEnabled ? ids : []
            let data = try JSONEncoder().encode(Array(enabledIDs).sorted())
            if let existingData = try? Data(contentsOf: url), existingData == data {
                return
            }
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Orb] Failed to write menu configuration: \(error)")
        }
    }
}

enum WindowOperationConfiguration {
    static let isEnabledKey = "windowOperationsEnabled"
    static let enabledIDsKey = "enabledWindowOperationIDs"

    static var defaultIsEnabled: Bool {
        true
    }

    static var defaultEnabledIDs: Set<String> {
        Set(WindowOperation.all.map(\.id))
    }

    static func isEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: isEnabledKey) != nil else {
            return defaultIsEnabled
        }
        return UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    static func setEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: isEnabledKey)
    }

    static func enabledIDs() -> Set<String> {
        guard UserDefaults.standard.object(forKey: enabledIDsKey) != nil else {
            return isEnabled() ? defaultEnabledIDs : []
        }
        let stored = UserDefaults.standard.stringArray(forKey: enabledIDsKey) ?? []
        return Set(stored)
    }

    static func setEnabledIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: enabledIDsKey)
    }

    static func isEnabled(_ operation: WindowOperation) -> Bool {
        isEnabled() && enabledIDs().contains(operation.id)
    }
}

enum MenuBarConfiguration {
    static let showsNetworkSpeedKey = "menuBarShowsNetworkSpeed"

    static var defaultShowsNetworkSpeed: Bool {
        false
    }

    static func showsNetworkSpeed() -> Bool {
        guard UserDefaults.standard.object(forKey: showsNetworkSpeedKey) != nil else {
            return defaultShowsNetworkSpeed
        }
        return UserDefaults.standard.bool(forKey: showsNetworkSpeedKey)
    }

    static func setShowsNetworkSpeed(_ showsNetworkSpeed: Bool) {
        UserDefaults.standard.set(showsNetworkSpeed, forKey: showsNetworkSpeedKey)
    }
}

enum ClipboardConfiguration {
    static let isEnabledKey = "clipboardEnabled"

    static var defaultIsEnabled: Bool {
        false
    }

    static func isEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: isEnabledKey) != nil else {
            return defaultIsEnabled
        }
        return UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    static func setEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: isEnabledKey)
    }
}

enum InputCorrectionConfiguration {
    static let isEnabledKey = "inputCorrectionEnabled"
    static let modelSourceKey = "inputCorrectionModelSource"
    static let modelKey = "inputCorrectionModel"
    static let baseURLKey = "inputCorrectionBaseURL"

    static let defaultModelSource = "remoteAPI"
    static let defaultModel = "google/gemini-3.1-flash-lite"
    static let defaultBaseURL = "https://openrouter.ai/api/v1/chat/completions"

    static var defaultIsEnabled: Bool {
        false
    }

    static func isEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: isEnabledKey) != nil else {
            return defaultIsEnabled
        }
        return UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    static func setEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: isEnabledKey)
    }

    static func modelSource() -> String {
        UserDefaults.standard.string(forKey: modelSourceKey) ?? defaultModelSource
    }

    static func setModelSource(_ modelSource: String) {
        UserDefaults.standard.set(modelSource, forKey: modelSourceKey)
    }

    static func model() -> String {
        UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
    }

    static func setModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: modelKey)
    }

    static func baseURL() -> String {
        UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
    }

    static func setBaseURL(_ baseURL: String) {
        UserDefaults.standard.set(baseURL, forKey: baseURLKey)
    }
}

struct WindowOperation: Identifiable, Hashable {
    let id: String
    let title: String
    let symbolName: String

    static let leftHalf = WindowOperation(
        id: "left-half",
        title: "窗口左半屏",
        symbolName: "rectangle.lefthalf.filled"
    )
    static let rightHalf = WindowOperation(
        id: "right-half",
        title: "窗口右半屏",
        symbolName: "rectangle.righthalf.filled"
    )
    static let maximized = WindowOperation(
        id: "maximized",
        title: "窗口最大化",
        symbolName: "arrow.up.left.and.arrow.down.right"
    )
    static let centered = WindowOperation(
        id: "centered",
        title: "窗口居中",
        symbolName: "rectangle.center.inset.filled"
    )
    static let minimizeOthers = WindowOperation(
        id: "minimize-others",
        title: "最小化其它窗口",
        symbolName: "minus.rectangle"
    )

    static let all: [WindowOperation] = [
        .leftHalf,
        .rightHalf,
        .maximized,
        .centered,
        .minimizeOthers
    ]
}
