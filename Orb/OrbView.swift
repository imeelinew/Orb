import AppKit
import Combine
import PermissionFlow
import SwiftUI

struct OrbView: View {
    @StateObject private var moduleHost = OrbModuleHost.shared
    @State private var selection: SettingsPage? = .modules
    @State private var contextMenuEnabled = MenuActionConfiguration.isEnabled()
    @State private var enabledActionIDs = MenuActionConfiguration.enabledIDs()
    @State private var windowOperationsEnabled = WindowOperationConfiguration.isEnabled()
    @State private var enabledWindowOperationIDs = WindowOperationConfiguration.enabledIDs()
    @State private var menuBarModuleEnabled = MenuBarConfiguration.isEnabled()
    @State private var showsNetworkSpeed = MenuBarConfiguration.showsNetworkSpeed()
    @State private var inputCorrectionEnabled = InputCorrectionConfiguration.isEnabled()
    @State private var inputCorrectionModelSource = InputCorrectionConfiguration.modelSource()
    @State private var inputCorrectionAPIKey = KeychainStore.string(for: KeychainStore.inputCorrectionAPIKeyAccount)
    @State private var inputCorrectionModel = InputCorrectionConfiguration.model()
    @State private var inputCorrectionBaseURL = InputCorrectionConfiguration.baseURL()
    @State private var modelConnectionMessage: String?
    @State private var isTestingModelConnection = false
    @State private var modulesSearchText = ""
    @State private var contextMenuSearchText = ""
    @State private var windowOperationsSearchText = ""
    @State private var menuBarSearchText = ""
    @State private var inputCorrectionSearchText = ""
    @State private var externalModuleSettings: [String: String] = [:]
    private let sidebarIconTileSize: Double = 22
    private let sidebarIconSymbolSize: Double = 11
    private let sidebarIconCornerRadius: Double = 6

    enum SettingsPage: Hashable, Identifiable {
        case modules
        case module(String)

        var id: String {
            switch self {
            case .modules:
                return "modules"
            case .module(let moduleID):
                return moduleID
            }
        }

        var title: String {
            "模块"
        }

        var symbolName: String {
            "puzzlepiece.extension.fill"
        }

        var iconGradient: LinearGradient {
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.76, blue: 0.24), Color(red: 0.95, green: 0.54, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var selectedPage: SettingsPage {
        selection ?? .modules
    }

    private var selectedModuleID: String? {
        guard case .module(let moduleID) = selectedPage else { return nil }
        return moduleID
    }

    private var selectedTitle: String {
        switch selectedPage {
        case .modules:
            return "模块"
        case .module(let moduleID):
            return moduleHost.module(withID: moduleID)?.name ?? "模块"
        }
    }

    private var searchPrompt: String {
        switch selectedPage {
        case .modules:
            return "搜索模块"
        case .module(let moduleID):
            return "搜索\(moduleHost.module(withID: moduleID)?.name ?? "模块")"
        }
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: {
                switch selectedPage {
                case .modules:
                    return modulesSearchText
                case .module(let moduleID) where moduleID == OrbModuleID.contextMenu:
                    return contextMenuSearchText
                case .module(let moduleID) where moduleID == OrbModuleID.windowOperations:
                    return windowOperationsSearchText
                case .module(let moduleID) where moduleID == OrbModuleID.menuBar:
                    return menuBarSearchText
                case .module(let moduleID) where moduleID == OrbModuleID.inputCorrection:
                    return inputCorrectionSearchText
                case .module:
                    return modulesSearchText
                }
            },
            set: { newValue in
                switch selectedPage {
                case .modules:
                    modulesSearchText = newValue
                case .module(let moduleID) where moduleID == OrbModuleID.contextMenu:
                    contextMenuSearchText = newValue
                case .module(let moduleID) where moduleID == OrbModuleID.windowOperations:
                    windowOperationsSearchText = newValue
                case .module(let moduleID) where moduleID == OrbModuleID.menuBar:
                    menuBarSearchText = newValue
                case .module(let moduleID) where moduleID == OrbModuleID.inputCorrection:
                    inputCorrectionSearchText = newValue
                case .module:
                    modulesSearchText = newValue
                }
            }
        )
    }

    private struct CompactBorderedMenuPicker<Option: Hashable>: View {
        let options: [Option]
        @Binding var selection: Option
        let title: (Option) -> String

        var body: some View {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .labelsHidden()
            .frame(minWidth: 108, minHeight: 24)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: SettingsPage.modules) {
                    SidebarPageLabel(page: .modules)
                }

                Section("模块") {
                    ForEach(enabledModules) { module in
                        NavigationLink(value: SettingsPage.module(module.id)) {
                            SidebarModuleLabel(module: module)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        } detail: {
            NavigationStack {
                detailContent
                .formStyle(.grouped)
                .settingsContentMargins()
                .scrollContentBackground(.hidden)
                .navigationTitle(selectedTitle)
                .toolbar {
                    if selectedPage == .modules {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                installModuleFromPanel()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .controlSize(.regular)
                            .accessibilityLabel("安装模块")
                            .help("安装模块")
                        }
                    }
                }
            }
        }
        .environment(\.sidebarIconTileSize, sidebarIconTileSize)
        .environment(\.sidebarIconSymbolSize, sidebarIconSymbolSize)
        .environment(\.sidebarIconCornerRadius, sidebarIconCornerRadius)
        .searchable(text: searchTextBinding, placement: .toolbar, prompt: Text(searchPrompt))
        .alert(
            "模型配置",
            isPresented: Binding(
                get: { modelConnectionMessage != nil },
                set: { if !$0 { modelConnectionMessage = nil } }
            ),
            presenting: modelConnectionMessage
        ) { _ in
            Button("好") { modelConnectionMessage = nil }
        } message: { message in
            Text(message)
        }
        .background {
            WindowTransparencyConfigurator(enabled: true)
                .frame(width: 0, height: 0)

            WindowBackgroundBlur(materialAlpha: 1)
                .ignoresSafeArea()
        }
        .onAppear {
            moduleHost.reloadModules()
            syncEnabledStateFromModuleHost()
            persistEnabledActions()
            persistEnabledWindowOperations()
            persistMenuBarModuleEnabled()
            persistMenuBarConfiguration()
        }
        .onChange(of: contextMenuEnabled) { _, _ in
            moduleHost.setEnabled(contextMenuEnabled, for: OrbModuleID.contextMenu)
            persistEnabledActions()
            moveSelectionToModulesIfDisabled(OrbModuleID.contextMenu, isEnabled: contextMenuEnabled)
        }
        .onChange(of: enabledActionIDs) { _, _ in
            persistEnabledActions()
        }
        .onChange(of: windowOperationsEnabled) { _, _ in
            moduleHost.setEnabled(windowOperationsEnabled, for: OrbModuleID.windowOperations)
            persistEnabledWindowOperations()
            moveSelectionToModulesIfDisabled(OrbModuleID.windowOperations, isEnabled: windowOperationsEnabled)
        }
        .onChange(of: enabledWindowOperationIDs) { _, _ in
            persistEnabledWindowOperations()
        }
        .onChange(of: menuBarModuleEnabled) { _, _ in
            moduleHost.setEnabled(menuBarModuleEnabled, for: OrbModuleID.menuBar)
            persistMenuBarModuleEnabled()
            moveSelectionToModulesIfDisabled(OrbModuleID.menuBar, isEnabled: menuBarModuleEnabled)
        }
        .onChange(of: showsNetworkSpeed) { _, _ in
            persistMenuBarConfiguration()
        }
        .onChange(of: inputCorrectionEnabled) { _, _ in
            moduleHost.setEnabled(inputCorrectionEnabled, for: OrbModuleID.inputCorrection)
            persistInputCorrectionEnabled()
            moveSelectionToModulesIfDisabled(OrbModuleID.inputCorrection, isEnabled: inputCorrectionEnabled)
        }
        .onReceive(moduleHost.$enabledModuleIDs) { _ in
            syncEnabledStateFromModuleHost()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedPage {
        case .modules:
            Form {
                if !filteredBundledModuleItems.isEmpty {
                    Section("内置模块") {
                        ForEach(filteredBundledModuleItems) { module in
                            moduleListRow(module)
                        }
                    }
                }

                if !filteredUserModuleItems.isEmpty {
                    Section("自定义模块") {
                        ForEach(filteredUserModuleItems) { module in
                            moduleListRow(module)
                                .contextMenu {
                                    Button("卸载模块", role: .destructive) {
                                        uninstallModule(module)
                                    }
                                }
                        }
                    }
                }
            }
        case .module(let moduleID) where moduleID == OrbModuleID.contextMenu:
            Form {
                Section("右键显示选项") {
                    ForEach(filteredActions) { action in
                        Toggle(isOn: binding(for: action)) {
                            HStack(spacing: 10) {
                                MenuActionIcon(actionID: action.id, size: 24)
                                Text(action.title)
                            }
                        }
                    }
                }
            }
        case .module(let moduleID) where moduleID == OrbModuleID.windowOperations:
            Form {
                Section("窗口操作") {
                    ForEach(filteredWindowOperations) { operation in
                        Toggle(isOn: binding(for: operation)) {
                            HStack(spacing: 10) {
                                WindowOperationIcon(operation: operation, size: 24)
                                Text(operation.title)
                            }
                        }
                    }
                }

                if !enabledWindowOperationIDs.isEmpty {
                    Section("权限") {
                        AccessibilityPermissionRow()
                    }
                }
            }
        case .module(let moduleID) where moduleID == OrbModuleID.menuBar:
            Form {
                Section("菜单栏选项") {
                    Toggle("显示实时网速", isOn: $showsNetworkSpeed)
                }
            }
        case .module(let moduleID) where moduleID == OrbModuleID.inputCorrection:
            Form {
                Section("模型配置") {
                    LabeledContent {
                        inputCorrectionModelSourcePicker
                    } label: {
                        Text("模型来源")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(
                            text: $inputCorrectionAPIKey,
                            prompt: Text("sk-...")
                        ) {
                            Label("API Key", systemImage: "key")
                        }
                        Text("用于访问云端 OpenAI 兼容服务的 API Key。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            text: $inputCorrectionModel,
                            prompt: Text("gpt-4.1-mini")
                        ) {
                            Label("Model", systemImage: "cpu")
                        }
                        Text("远程服务的模型名称，如 gpt-4.1-mini。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            text: $inputCorrectionBaseURL,
                            prompt: Text("https://api.openai.com/v1/chat/completions")
                        ) {
                            Label("Base URL", systemImage: "link")
                        }
                        Text("远程 API 的 chat completions 地址。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("保存配置") {
                            saveInputCorrectionModelConfiguration()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(isTestingModelConnection ? "测试中…" : "测试模型连接") {
                            testModelConnection()
                        }
                        .disabled(isTestingModelConnection)

                        Spacer(minLength: 0)
                    }
                }

                Section("权限") {
                    AccessibilityPermissionRow()
                }
            }
        case .module(let moduleID):
            externalModuleDetail(moduleID: moduleID)
        }
    }

    private var filteredActions: [MenuAction] {
        let query = contextMenuSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MenuAction.all }
        return MenuAction.all.filter { action in
            action.title.localizedStandardContains(query)
        }
    }

    private var enabledModules: [OrbModule] {
        moduleHost.modules.filter { moduleHost.isEnabled($0.id) }
    }

    private var filteredModuleItems: [OrbModule] {
        let query = modulesSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return moduleHost.modules }
        return moduleHost.modules.filter { module in
            module.name.localizedStandardContains(query)
                || module.desc.localizedStandardContains(query)
                || module.id.localizedStandardContains(query)
        }
    }

    private var filteredBundledModuleItems: [OrbModule] {
        filteredModuleItems.filter { $0.source == .bundled }
    }

    private var filteredUserModuleItems: [OrbModule] {
        filteredModuleItems.filter { $0.source == .user }
    }

    private var filteredWindowOperations: [WindowOperation] {
        let query = windowOperationsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return WindowOperation.all }
        return WindowOperation.all.filter { operation in
            operation.title.localizedStandardContains(query)
        }
    }

    private func moduleListRow(_ module: OrbModule) -> some View {
        Toggle(isOn: moduleBinding(for: module.id)) {
            HStack(spacing: 12) {
                ModuleIconTile(icon: module.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(module.name)
                    Text(module.desc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 48)
        }
        .padding(.horizontal, 10)
    }

    private func binding(for action: MenuAction) -> Binding<Bool> {
        Binding(
            get: { enabledActionIDs.contains(action.id) },
            set: { isEnabled in
                if isEnabled {
                    enabledActionIDs.insert(action.id)
                } else {
                    enabledActionIDs.remove(action.id)
                }
            }
        )
    }

    private func moduleBinding(for moduleID: String) -> Binding<Bool> {
        Binding(
            get: { moduleHost.isEnabled(moduleID) },
            set: { isEnabled in
                setModule(moduleID, isEnabled: isEnabled)
            }
        )
    }

    private func setModule(_ moduleID: String, isEnabled: Bool) {
        switch moduleID {
        case OrbModuleID.contextMenu:
            contextMenuEnabled = isEnabled
        case OrbModuleID.windowOperations:
            windowOperationsEnabled = isEnabled
        case OrbModuleID.menuBar:
            menuBarModuleEnabled = isEnabled
        case OrbModuleID.inputCorrection:
            inputCorrectionEnabled = isEnabled
        default:
            moduleHost.setEnabled(isEnabled, for: moduleID)
            moveSelectionToModulesIfDisabled(moduleID, isEnabled: isEnabled)
        }
    }

    private func installModuleFromPanel() {
        let panel = NSOpenPanel()
        let delegate = OrbModuleOpenPanelDelegate()
        panel.delegate = delegate
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK,
              let moduleURL = panel.url else {
            return
        }

        do {
            _ = try moduleHost.installModule(from: moduleURL)
        } catch {
            NSSound.beep()
            NSLog("[Orb] Failed to install module: \(error)")
        }
    }

    private func uninstallModule(_ module: OrbModule) {
        if moduleHost.uninstall(moduleID: module.id) {
            moveSelectionToModulesIfDisabled(module.id, isEnabled: false)
        } else {
            NSSound.beep()
        }
    }

    private func binding(for operation: WindowOperation) -> Binding<Bool> {
        Binding(
            get: { enabledWindowOperationIDs.contains(operation.id) },
            set: { isEnabled in
                if isEnabled {
                    enabledWindowOperationIDs.insert(operation.id)
                } else {
                    enabledWindowOperationIDs.remove(operation.id)
                }
            }
        )
    }

    private func persistEnabledActions() {
        MenuActionConfiguration.setEnabled(contextMenuEnabled)
        MenuActionConfiguration.setEnabledIDs(enabledActionIDs)
        MenuActionConfiguration.writeEnabledIDs(enabledActionIDs, isEnabled: contextMenuEnabled)
    }

    private func persistEnabledWindowOperations() {
        WindowOperationConfiguration.setEnabled(windowOperationsEnabled)
        WindowOperationConfiguration.setEnabledIDs(enabledWindowOperationIDs)
    }

    private func persistMenuBarModuleEnabled() {
        MenuBarConfiguration.setEnabled(menuBarModuleEnabled)
    }

    private func persistMenuBarConfiguration() {
        MenuBarConfiguration.setShowsNetworkSpeed(showsNetworkSpeed)
    }

    private func persistInputCorrectionEnabled() {
        InputCorrectionConfiguration.setEnabled(inputCorrectionEnabled)
    }

    private func moveSelectionToModulesIfDisabled(_ moduleID: String, isEnabled: Bool) {
        guard !isEnabled, selectedModuleID == moduleID else { return }
        selection = .modules
    }

    private func syncEnabledStateFromModuleHost() {
        contextMenuEnabled = moduleHost.isEnabled(OrbModuleID.contextMenu)
        windowOperationsEnabled = moduleHost.isEnabled(OrbModuleID.windowOperations)
        menuBarModuleEnabled = moduleHost.isEnabled(OrbModuleID.menuBar)
        inputCorrectionEnabled = moduleHost.isEnabled(OrbModuleID.inputCorrection)
    }

    @ViewBuilder
    private func externalModuleDetail(moduleID: String) -> some View {
        if let module = moduleHost.module(withID: moduleID) {
            Form {
                if !module.descriptor.capabilities.isEmpty {
                    Section("操作") {
                        ForEach(module.descriptor.capabilities) { capability in
                            Button {
                                if let command = capability.command {
                                    _ = moduleHost.runAction(moduleID: module.id, command: command)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(capability.name)
                                    if let desc = capability.desc {
                                        Text(desc)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(!moduleHost.isEnabled(module.id) || capability.command == nil)
                        }
                    }
                }

                if !module.descriptor.settings.isEmpty {
                    Section(externalModuleSettingsSectionTitle(module.descriptor.settings)) {
                        ForEach(module.descriptor.settings) { setting in
                            externalModuleSettingRow(moduleID: module.id, setting: setting)
                        }

                        if module.descriptor.settings.contains(where: { !isToggleSetting($0) }) {
                            Button("保存设置") {
                                for setting in module.descriptor.settings {
                                    saveExternalModuleSetting(moduleID: module.id, setting: setting)
                                }
                            }
                        }
                    }
                }
            }
            .task(id: module.id) {
                loadExternalModuleSettings(module)
            }
        } else {
            ContentUnavailableView("模块不存在", systemImage: "puzzlepiece.extension")
        }
    }

    @ViewBuilder
    private func externalModuleSettingRow(moduleID: String, setting: OrbModuleSetting) -> some View {
        if isToggleSetting(setting) {
            Toggle(setting.title, isOn: externalModuleToggleSettingBinding(moduleID: moduleID, setting: setting))
        } else {
            TextField(setting.title, text: externalModuleSettingBinding(moduleID: moduleID, setting: setting))
                .onSubmit {
                    saveExternalModuleSetting(moduleID: moduleID, setting: setting)
                }
        }
    }

    private func externalModuleSettingBinding(moduleID: String, setting: OrbModuleSetting) -> Binding<String> {
        let key = externalModuleSettingStateKey(moduleID: moduleID, settingKey: setting.key)
        return Binding(
            get: {
                externalModuleSettings[key] ?? setting.defaultValue ?? ""
            },
            set: { newValue in
                externalModuleSettings[key] = newValue
            }
        )
    }

    private func externalModuleToggleSettingBinding(moduleID: String, setting: OrbModuleSetting) -> Binding<Bool> {
        let key = externalModuleSettingStateKey(moduleID: moduleID, settingKey: setting.key)
        return Binding(
            get: {
                boolValue(externalModuleSettings[key] ?? setting.defaultValue ?? "true")
            },
            set: { newValue in
                externalModuleSettings[key] = newValue ? "true" : "false"
                saveExternalModuleSetting(moduleID: moduleID, setting: setting)
            }
        )
    }

    private func loadExternalModuleSettings(_ module: OrbModule) {
        guard module.descriptor.runtime.kind == .executable else { return }
        for setting in module.descriptor.settings {
            let key = externalModuleSettingStateKey(moduleID: module.id, settingKey: setting.key)
            externalModuleSettings[key] = moduleHost.settingValue(moduleID: module.id, key: setting.key)
                ?? setting.defaultValue
                ?? ""
        }
    }

    private func saveExternalModuleSetting(moduleID: String, setting: OrbModuleSetting) {
        let key = externalModuleSettingStateKey(moduleID: moduleID, settingKey: setting.key)
        _ = moduleHost.setSettingValue(
            moduleID: moduleID,
            key: setting.key,
            value: externalModuleSettings[key] ?? setting.defaultValue ?? ""
        )
    }

    private func externalModuleSettingStateKey(moduleID: String, settingKey: String) -> String {
        "\(moduleID).\(settingKey)"
    }

    private func externalModuleSettingsSectionTitle(_ settings: [OrbModuleSetting]) -> String {
        settings.allSatisfy(isCommandSetting) ? "命令" : "设置"
    }

    private func isCommandSetting(_ setting: OrbModuleSetting) -> Bool {
        setting.type.localizedCaseInsensitiveCompare("command") == .orderedSame
    }

    private func isToggleSetting(_ setting: OrbModuleSetting) -> Bool {
        ["bool", "boolean", "toggle", "command"].contains(setting.type.lowercased())
    }

    private func boolValue(_ value: String) -> Bool {
        !["false", "0", "no", "off"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private var inputCorrectionModelSourcePicker: some View {
        CompactBorderedMenuPicker(
            options: ["remoteAPI"],
            selection: $inputCorrectionModelSource,
            title: { _ in "远程 API" }
        )
    }

    private func saveInputCorrectionModelConfiguration() {
        do {
            InputCorrectionConfiguration.setModelSource(inputCorrectionModelSource)
            InputCorrectionConfiguration.setModel(inputCorrectionModel.trimmingCharacters(in: .whitespacesAndNewlines))
            InputCorrectionConfiguration.setBaseURL(inputCorrectionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            try KeychainStore.setString(
                inputCorrectionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                for: KeychainStore.inputCorrectionAPIKeyAccount
            )
            modelConnectionMessage = "模型配置已保存"
        } catch {
            modelConnectionMessage = error.localizedDescription
        }
    }

    private func testModelConnection() {
        isTestingModelConnection = true
        modelConnectionMessage = nil

        let configuration = RemoteModelConfiguration(
            apiKey: inputCorrectionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: inputCorrectionModel.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: inputCorrectionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        Task {
            do {
                try await RemoteCorrectionClient().testConnection(configuration: configuration)
                await MainActor.run {
                    modelConnectionMessage = "连接正常"
                    isTestingModelConnection = false
                }
            } catch {
                await MainActor.run {
                    modelConnectionMessage = error.localizedDescription
                    isTestingModelConnection = false
                }
            }
        }
    }
}

private final class OrbModuleOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        OrbModuleOpenPanelSelection.shouldEnable(url)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try OrbModuleOpenPanelSelection.validate(url)
    }
}

enum OrbModuleOpenPanelSelection {
    static func shouldEnable(_ url: URL) -> Bool {
        if url.pathExtension == OrbModuleLoader.packageExtension {
            return true
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    static func validate(_ url: URL) throws {
        guard url.pathExtension == OrbModuleLoader.packageExtension else {
            throw OrbModuleOpenPanelError.invalidSelection
        }
    }
}

enum OrbModuleOpenPanelError: LocalizedError {
    case invalidSelection

    var errorDescription: String? {
        "请选择 .orbmodule 模块。"
    }
}

private struct AccessibilityPermissionRow: View {
    @StateObject private var controller = PermissionFlow.makeController(
        configuration: .init(localeIdentifier: "zh-Hans")
    )
    @State private var authorizationState = PermissionStatusRegistry.provider(for: .accessibility).authorizationState()

    private let statusTimer = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    private var statusTitle: String {
        authorizationState == .granted ? "已申请" : "未申请"
    }

    var body: some View {
        HStack {
            Button("申请无障碍权限") {
                controller.authorize(
                    pane: .accessibility,
                    suggestedAppURLs: [Bundle.main.bundleURL],
                    sourceFrameInScreen: clickSourceFrameInScreen()
                )
                refreshAuthorizationState()
            }

            Spacer()

            Text(statusTitle)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refreshAuthorizationState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAuthorizationState()
        }
        .onReceive(statusTimer) { _ in
            refreshAuthorizationState()
        }
    }

    private func refreshAuthorizationState() {
        let latestState = PermissionStatusRegistry.provider(for: .accessibility).authorizationState()
        authorizationState = latestState

        if latestState == .granted {
            controller.closePanel(returnToPreviousApp: true)
        }
    }

    private func clickSourceFrameInScreen() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        return CGRect(x: mouseLocation.x - 16, y: mouseLocation.y - 16, width: 32, height: 32)
    }
}

private struct MenuActionIcon: View {
    let actionID: String
    let size: CGFloat

    private var iconAssetName: String? {
        switch actionID {
        case "new-markdown":
            return "logo-markdown"
        case "open-ghostty":
            return "logo-ghostty"
        case "open-vscode":
            return "logo-vscode"
        case "git-commit-push":
            return "logo-github"
        default:
            return nil
        }
    }

    private var symbolName: String {
        switch actionID {
        case "subtitles", "remove-subtitles":
            return "captions.bubble"
        case "stop-subtitles":
            return "stop.circle"
        case "new-text":
            return "doc.text"
        case "new-markdown":
            return "chevron.left.forwardslash.chevron.right"
        case "new-word":
            return "doc.richtext"
        case "open-ghostty":
            return "terminal"
        case "open-vscode":
            return "curlybraces"
        case "git-commit-push":
            return "arrow.up.doc"
        case "copy-path":
            return "point.topleft.down.curvedto.point.bottomright.up"
        default:
            return "circle"
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var gradientColors: [Color] {
        switch actionID {
        case "new-text":
            return [
                Color(red: 0.48, green: 0.58, blue: 0.70),
                Color(red: 0.25, green: 0.34, blue: 0.48)
            ]
        case "new-markdown":
            return [
                Color(red: 0.20, green: 0.22, blue: 0.26),
                Color(red: 0.05, green: 0.06, blue: 0.08)
            ]
        case "new-word":
            return [
                Color(red: 0.22, green: 0.46, blue: 0.96),
                Color(red: 0.07, green: 0.22, blue: 0.68)
            ]
        case "open-ghostty":
            return [
                Color(red: 0.28, green: 0.26, blue: 0.34),
                Color(red: 0.10, green: 0.10, blue: 0.14)
            ]
        case "open-vscode":
            return [
                Color(red: 0.15, green: 0.55, blue: 0.92),
                Color(red: 0.00, green: 0.32, blue: 0.67)
            ]
        case "git-commit-push":
            return [
                Color(red: 0.98, green: 0.42, blue: 0.22),
                Color(red: 0.76, green: 0.18, blue: 0.12)
            ]
        case "copy-path":
            return [
                Color(red: 0.98, green: 0.50, blue: 0.36),
                Color(red: 0.83, green: 0.22, blue: 0.18)
            ]
        default:
            return [
                Color(red: 0.18, green: 0.78, blue: 0.35),
                Color(red: 0.12, green: 0.64, blue: 0.28)
            ]
        }
    }

    private var assetPadding: CGFloat {
        switch actionID {
        case "new-markdown", "git-commit-push":
            return 5
        default:
            return 6
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(gradient)

            if let iconAssetName {
                Image(iconAssetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(assetPadding)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct WindowOperationIcon: View {
    let operation: WindowOperation
    let size: CGFloat

    private var gradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var gradientColors: [Color] {
        switch operation.id {
        case WindowOperation.leftHalf.id:
            return [
                Color(red: 0.24, green: 0.58, blue: 0.96),
                Color(red: 0.10, green: 0.34, blue: 0.76)
            ]
        case WindowOperation.rightHalf.id:
            return [
                Color(red: 0.40, green: 0.52, blue: 0.96),
                Color(red: 0.18, green: 0.28, blue: 0.72)
            ]
        case WindowOperation.maximized.id:
            return [
                Color(red: 0.26, green: 0.70, blue: 0.52),
                Color(red: 0.12, green: 0.52, blue: 0.36)
            ]
        case WindowOperation.centered.id:
            return [
                Color(red: 0.56, green: 0.46, blue: 0.90),
                Color(red: 0.36, green: 0.26, blue: 0.68)
            ]
        case WindowOperation.minimizeOthers.id:
            return [
                Color(red: 0.86, green: 0.48, blue: 0.26),
                Color(red: 0.66, green: 0.24, blue: 0.16)
            ]
        default:
            return [
                Color(red: 0.48, green: 0.58, blue: 0.70),
                Color(red: 0.25, green: 0.34, blue: 0.48)
            ]
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(gradient)

            Image(systemName: operation.symbolName)
                .font(.system(size: size * 0.48, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct SidebarPageLabel: View {
    let page: OrbView.SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            SidebarCategoryIcon(page: page)
            Text("模块")
        }
    }
}

private struct SidebarModuleLabel: View {
    let module: OrbModule

    var body: some View {
        HStack(spacing: 12) {
            ModuleIconTile(icon: module.icon)
            Text(module.name)
        }
    }
}

private struct SidebarCategoryIcon: View {
    let page: OrbView.SettingsPage
    @Environment(\.sidebarIconTileSize) private var tileSize
    @Environment(\.sidebarIconSymbolSize) private var symbolSize
    @Environment(\.sidebarIconCornerRadius) private var cornerRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(page.iconGradient)

            Image(systemName: page.symbolName)
                .font(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: tileSize, height: tileSize)
    }
}

private struct ModuleIconTile: View {
    let icon: OrbModuleIcon
    @Environment(\.sidebarIconTileSize) private var tileSize
    @Environment(\.sidebarIconSymbolSize) private var symbolSize
    @Environment(\.sidebarIconCornerRadius) private var cornerRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(iconGradient)

            Image(systemName: icon.symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: tileSize, height: tileSize)
    }

    private var iconGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var gradientColors: [Color] {
        let colors = icon.gradient.compactMap(Color.init(hex:))
        guard colors.count >= 2 else {
            return [
                Color(red: 0.48, green: 0.58, blue: 0.70),
                Color(red: 0.25, green: 0.34, blue: 0.48)
            ]
        }
        return colors
    }
}

private extension Color {
    init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6,
              let value = UInt64(normalized, radix: 16) else {
            return nil
        }

        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private struct SidebarIconTileSizeKey: EnvironmentKey {
    static let defaultValue: Double = 32
}

private struct SidebarIconSymbolSizeKey: EnvironmentKey {
    static let defaultValue: Double = 15
}

private struct SidebarIconCornerRadiusKey: EnvironmentKey {
    static let defaultValue: Double = 8
}

private extension EnvironmentValues {
    var sidebarIconTileSize: Double {
        get { self[SidebarIconTileSizeKey.self] }
        set { self[SidebarIconTileSizeKey.self] = newValue }
    }

    var sidebarIconSymbolSize: Double {
        get { self[SidebarIconSymbolSizeKey.self] }
        set { self[SidebarIconSymbolSizeKey.self] = newValue }
    }

    var sidebarIconCornerRadius: Double {
        get { self[SidebarIconCornerRadiusKey.self] }
        set { self[SidebarIconCornerRadiusKey.self] = newValue }
    }
}

private extension View {
    func settingsContentMargins() -> some View {
        self
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }
}
