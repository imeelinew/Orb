import Foundation

struct MenuAction: Identifiable, Hashable {
    let id: String
    let title: String
    let filename: String
    let symbolName: String
    let allowsEmpty: Bool

    static let all: [MenuAction] = [
        MenuAction(id: "subtitles", title: "生成字幕", filename: "gen_subtitles.sh", symbolName: "captions.bubble", allowsEmpty: false),
        MenuAction(id: "remove-subtitles", title: "移除字幕", filename: "remove_subtitles.sh", symbolName: "captions.bubble", allowsEmpty: false),
        MenuAction(id: "stop-subtitles", title: "停止生成字幕", filename: "stop_subtitles.sh", symbolName: "stop.circle", allowsEmpty: false),
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
    private static let didMigrateRemoveSubtitlesDefaultKey = "didMigrateRemoveSubtitlesDefaultMenuAction"
    private static let didMigrateStopSubtitlesDefaultKey = "didMigrateStopSubtitlesDefaultMenuAction"
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
        var ids = Set(UserDefaults.standard.stringArray(forKey: enabledIDsKey) ?? [])
        if !UserDefaults.standard.bool(forKey: didMigrateRemoveSubtitlesDefaultKey) {
            ids.insert("remove-subtitles")
            UserDefaults.standard.set(Array(ids).sorted(), forKey: enabledIDsKey)
            UserDefaults.standard.set(true, forKey: didMigrateRemoveSubtitlesDefaultKey)
        }
        if !UserDefaults.standard.bool(forKey: didMigrateStopSubtitlesDefaultKey) {
            ids.insert("stop-subtitles")
            UserDefaults.standard.set(Array(ids).sorted(), forKey: enabledIDsKey)
            UserDefaults.standard.set(true, forKey: didMigrateStopSubtitlesDefaultKey)
        }
        return ids
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
    static let isEnabledKey = "menuBarModuleEnabled"
    static let showsNetworkSpeedKey = "menuBarShowsNetworkSpeed"

    static var defaultIsEnabled: Bool {
        true
    }

    static var defaultShowsNetworkSpeed: Bool {
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

enum SubtitleConfiguration {
    struct WhisperLanguageOption: Identifiable, Equatable {
        let code: String
        let displayName: String

        var id: String { code }
    }

    struct WhisperModelOption: Identifiable, Equatable {
        let filename: String
        let displayName: String

        var id: String { filename }
    }

    static let whisperLangKey = "subtitleWhisperLang"
    static let whisperModelKey = "subtitleWhisperModel"
    static let llmSegmentationEnabledKey = "subtitleLLMSegmentationEnabled"
    static let llmTranslationEnabledKey = "subtitleLLMTranslationEnabled"
    static let llmModelKey = "subtitleLLMModel"
    static let llmBaseURLKey = "subtitleLLMBaseURL"

    static let configFilename = "subtitle-config.json"

    static let defaultWhisperLang = "en"
    static let defaultWhisperModel = "ggml-large-v3-turbo.bin"
    static let defaultLLMSegmentationEnabled = true
    static let defaultLLMTranslationEnabled = true
    static let defaultLLMModel = "mimo-v2.5"
    static let defaultLLMBaseURL = "https://opencode.ai/zen/go/v1/chat/completions"

    static let supportedWhisperLanguages = [
        WhisperLanguageOption(code: "zh", displayName: "中文"),
        WhisperLanguageOption(code: "en", displayName: "英语"),
        WhisperLanguageOption(code: "ko", displayName: "韩语"),
        WhisperLanguageOption(code: "ja", displayName: "日语")
    ]

    static let supportedWhisperModels = [
        WhisperModelOption(filename: "ggml-large-v3-turbo.bin", displayName: "large-v3-turbo"),
        WhisperModelOption(filename: "ggml-large-v3.bin", displayName: "large-v3"),
        WhisperModelOption(filename: "ggml-medium.bin", displayName: "medium"),
        WhisperModelOption(filename: "ggml-small.bin", displayName: "small")
    ]

    static func whisperModelsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("whisper-models", isDirectory: true)
    }

    static func availableWhisperModels(
        in modelsDirectory: URL = whisperModelsDirectory()
    ) -> [WhisperModelOption] {
        supportedWhisperModels.filter { model in
            FileManager.default.fileExists(
                atPath: modelsDirectory.appendingPathComponent(model.filename).path
            )
        }
    }

    static func resolvedWhisperModel(
        storedValue: String?,
        modelsDirectory: URL = whisperModelsDirectory()
    ) -> String {
        let available = availableWhisperModels(in: modelsDirectory)
        if let storedValue,
           available.contains(where: { $0.filename == storedValue }) {
            return storedValue
        }
        if available.contains(where: { $0.filename == defaultWhisperModel }) {
            return defaultWhisperModel
        }
        return available.first?.filename ?? defaultWhisperModel
    }

    static func whisperLang() -> String {
        resolvedWhisperLanguage(
            storedValue: UserDefaults.standard.string(forKey: whisperLangKey)
        )
    }

    static func setWhisperLang(_ value: String) {
        UserDefaults.standard.set(
            resolvedWhisperLanguage(storedValue: value),
            forKey: whisperLangKey
        )
    }

    static func resolvedWhisperLanguage(storedValue: String?) -> String {
        guard let storedValue,
              supportedWhisperLanguages.contains(where: { $0.code == storedValue }) else {
            return defaultWhisperLang
        }
        return storedValue
    }

    static func whisperModel() -> String {
        resolvedWhisperModel(
            storedValue: UserDefaults.standard.string(forKey: whisperModelKey)
        )
    }

    static func setWhisperModel(_ value: String) {
        UserDefaults.standard.set(value, forKey: whisperModelKey)
    }

    static func llmSegmentationEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: llmSegmentationEnabledKey) != nil else {
            return defaultLLMSegmentationEnabled
        }
        return UserDefaults.standard.bool(forKey: llmSegmentationEnabledKey)
    }

    static func setLLMSegmentationEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: llmSegmentationEnabledKey)
    }

    static func llmTranslationEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: llmTranslationEnabledKey) != nil else {
            return defaultLLMTranslationEnabled
        }
        return UserDefaults.standard.bool(forKey: llmTranslationEnabledKey)
    }

    static func setLLMTranslationEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: llmTranslationEnabledKey)
    }

    static func llmModel() -> String {
        UserDefaults.standard.string(forKey: llmModelKey) ?? defaultLLMModel
    }

    static func setLLMModel(_ value: String) {
        UserDefaults.standard.set(value, forKey: llmModelKey)
    }

    static func llmBaseURL() -> String {
        UserDefaults.standard.string(forKey: llmBaseURLKey) ?? defaultLLMBaseURL
    }

    static func setLLMBaseURL(_ value: String) {
        UserDefaults.standard.set(value, forKey: llmBaseURLKey)
    }

    static func configURL() -> URL {
        MenuActionConfiguration.configurationURL()
            .deletingLastPathComponent()
            .appendingPathComponent(configFilename)
    }

    static func writeConfig() {
        let dict: [String: Any] = [
            "whisperLang": whisperLang(),
            "whisperModel": whisperModel(),
            "llmSegmentationEnabled": llmSegmentationEnabled(),
            "llmTranslationEnabled": llmTranslationEnabled(),
            "llmModel": llmModel(),
            "llmBaseURL": llmBaseURL()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]) else {
            return
        }
        let url = configURL()
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? data.write(to: url, options: .atomic)
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
