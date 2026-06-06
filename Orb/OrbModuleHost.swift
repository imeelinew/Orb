import Darwin
import Combine
import Foundation

@MainActor
final class OrbModuleHost: ObservableObject {
    static let shared = OrbModuleHost()
    static let moduleStateDidChangeNotification = Notification.Name("OrbModuleHost.moduleStateDidChange")

    @Published private(set) var modules: [OrbModule] = []
    @Published private(set) var enabledModuleIDs: Set<String> = []

    private var modulesByID: [String: OrbModule] = [:]
    private var userModulesSource: DispatchSourceFileSystemObject?
    private var userModulesDescriptor: CInt = -1

    private init() {
        reloadModules()
    }

    deinit {
        userModulesSource?.cancel()
    }

    var userModulesDirectoryURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orb/Modules", isDirectory: true)
    }

    var bundledModulesDirectoryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Modules", isDirectory: true)
    }

    func module(withID id: String) -> OrbModule? {
        modulesByID[id]
    }

    func isEnabled(_ moduleID: String) -> Bool {
        enabledModuleIDs.contains(moduleID)
    }

    func reloadModules() {
        let previousModules = modulesByID
        var nextModules: [OrbModule] = []
        var nextModulesByID: [String: OrbModule] = [:]
        for module in (loadBundledModules() + loadUserModules()).sorted(by: OrbModuleLoader.sortModules) {
            if nextModulesByID[module.id] != nil {
                NSLog("[Orb] Ignoring duplicate module id: \(module.id)")
                continue
            }
            nextModulesByID[module.id] = module
            nextModules.append(module)
        }
        modulesByID = nextModulesByID
        modules = nextModules
        refreshEnabledStates()
        stopRemovedExecutableModules(previousModules: previousModules, currentModules: modulesByID)
    }

    func refreshEnabledStates() {
        enabledModuleIDs = Set(modules.filter { enabledState(for: $0) }.map(\.id))
    }

    func setEnabled(_ isEnabled: Bool, for moduleID: String) {
        guard let module = module(withID: moduleID) else { return }

        switch module.descriptor.runtime.kind {
        case .native:
            setNativeModule(moduleID, isEnabled: isEnabled)
        case .executable:
            setExecutableModule(module, isEnabled: isEnabled)
        }

        refreshEnabledStates()
        NotificationCenter.default.post(
            name: Self.moduleStateDidChangeNotification,
            object: self,
            userInfo: ["moduleID": moduleID, "isEnabled": isEnabled]
        )
    }

    func startWatchingUserModules() {
        let directoryURL = userModulesDirectoryURL
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[Orb] Failed to create user modules directory: \(error)")
            return
        }

        if let userModulesSource {
            userModulesSource.cancel()
            self.userModulesSource = nil
            userModulesDescriptor = -1
        }

        userModulesDescriptor = open(directoryURL.path, O_EVTONLY)
        guard userModulesDescriptor >= 0 else {
            NSLog("[Orb] Failed to watch user modules directory: \(directoryURL.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: userModulesDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.reloadModules()
                self?.startEnabledExecutableModules()
            }
        }
        source.setCancelHandler { [descriptor = userModulesDescriptor] in
            if descriptor >= 0 {
                close(descriptor)
            }
        }
        userModulesSource = source
        source.resume()
    }

    func startEnabledExecutableModules() {
        for module in modules
        where module.descriptor.runtime.kind == .executable && isEnabled(module.id) {
            _ = runExecutable(module, arguments: ["start"])
        }
    }

    func stopEnabledExecutableModules() {
        for module in modules
        where module.descriptor.runtime.kind == .executable && isEnabled(module.id) {
            _ = runExecutable(module, arguments: ["stop"])
        }
    }

    @discardableResult
    func installModule(from sourceURL: URL) throws -> OrbModule {
        let accessingSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessingSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let candidate = OrbModuleLoader.loadModule(at: sourceURL, source: .user) else {
            throw OrbModuleInstallError.invalidPackage(sourceURL)
        }

        let existingModule = module(withID: candidate.id)
        let shouldReenable = existingModule?.source == .user && isEnabled(candidate.id)
        if shouldReenable {
            setEnabled(false, for: candidate.id)
        }

        let installed = try OrbModuleInstaller.installPackage(
            from: sourceURL,
            into: userModulesDirectoryURL,
            existingModules: modules
        )
        reloadModules()

        if shouldReenable {
            setEnabled(true, for: installed.id)
        } else {
            startEnabledExecutableModules()
        }

        return module(withID: installed.id) ?? installed
    }

    @discardableResult
    func uninstall(moduleID: String) -> Bool {
        guard let module = module(withID: moduleID), module.source == .user else {
            return false
        }

        if isEnabled(moduleID) {
            setEnabled(false, for: moduleID)
        }

        do {
            try FileManager.default.removeItem(at: module.packageURL)
            reloadModules()
            return true
        } catch {
            NSLog("[Orb] Failed to uninstall module \(moduleID): \(error)")
            return false
        }
    }

    @discardableResult
    func runAction(moduleID: String, command: String) -> Bool {
        guard let module = module(withID: moduleID),
              module.descriptor.runtime.kind == .executable else {
            return false
        }
        return runExecutable(module, arguments: ["action", command])
    }

    func status(moduleID: String) -> String? {
        guard let module = module(withID: moduleID),
              module.descriptor.runtime.kind == .executable else {
            return nil
        }
        let result = runExecutableResult(module, arguments: ["status"])
        return result.succeeded ? result.output : nil
    }

    func settingValue(moduleID: String, key: String) -> String? {
        guard let module = module(withID: moduleID),
              module.descriptor.runtime.kind == .executable else {
            return nil
        }
        let result = runExecutableResult(module, arguments: ["settings", "get", key])
        return result.succeeded ? result.output : nil
    }

    func setSettingValue(moduleID: String, key: String, value: String) -> Bool {
        guard let module = module(withID: moduleID),
              module.descriptor.runtime.kind == .executable else {
            return false
        }
        return runExecutable(module, arguments: ["settings", "set", key, value])
    }

    private func loadBundledModules() -> [OrbModule] {
        guard let bundledModulesDirectoryURL else {
            return []
        }
        return OrbModuleLoader.loadModules(at: bundledModulesDirectoryURL, source: .bundled)
    }

    private func loadUserModules() -> [OrbModule] {
        try? FileManager.default.createDirectory(
            at: userModulesDirectoryURL,
            withIntermediateDirectories: true
        )
        return OrbModuleLoader.loadModules(at: userModulesDirectoryURL, source: .user)
    }

    private func enabledState(for module: OrbModule) -> Bool {
        switch module.descriptor.runtime.kind {
        case .native:
            return nativeModuleEnabledState(module.id, defaultEnabled: module.descriptor.defaultEnabled)
        case .executable:
            let key = enabledDefaultsKey(for: module.id)
            guard UserDefaults.standard.object(forKey: key) != nil else {
                return module.descriptor.defaultEnabled
            }
            return UserDefaults.standard.bool(forKey: key)
        }
    }

    private func setNativeModule(_ moduleID: String, isEnabled: Bool) {
        switch moduleID {
        case OrbModuleID.contextMenu:
            MenuActionConfiguration.setEnabled(isEnabled)
            MenuActionConfiguration.writeEnabledIDs(MenuActionConfiguration.enabledIDs(), isEnabled: isEnabled)
        case OrbModuleID.windowOperations:
            WindowOperationConfiguration.setEnabled(isEnabled)
        case OrbModuleID.menuBar:
            MenuBarConfiguration.setEnabled(isEnabled)
        case OrbModuleID.inputCorrection:
            InputCorrectionConfiguration.setEnabled(isEnabled)
        default:
            UserDefaults.standard.set(isEnabled, forKey: enabledDefaultsKey(for: moduleID))
        }
    }

    private func nativeModuleEnabledState(_ moduleID: String, defaultEnabled: Bool) -> Bool {
        switch moduleID {
        case OrbModuleID.contextMenu:
            return MenuActionConfiguration.isEnabled()
        case OrbModuleID.windowOperations:
            return WindowOperationConfiguration.isEnabled()
        case OrbModuleID.menuBar:
            return MenuBarConfiguration.isEnabled()
        case OrbModuleID.inputCorrection:
            return InputCorrectionConfiguration.isEnabled()
        default:
            let key = enabledDefaultsKey(for: moduleID)
            guard UserDefaults.standard.object(forKey: key) != nil else {
                return defaultEnabled
            }
            return UserDefaults.standard.bool(forKey: key)
        }
    }

    private func setExecutableModule(_ module: OrbModule, isEnabled: Bool) {
        if isEnabled {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey(for: module.id))
            _ = runExecutable(module, arguments: ["start"])
        } else {
            _ = runExecutable(module, arguments: ["stop"])
            UserDefaults.standard.set(false, forKey: enabledDefaultsKey(for: module.id))
        }
    }

    private func stopRemovedExecutableModules(previousModules: [String: OrbModule], currentModules: [String: OrbModule]) {
        for (moduleID, module) in previousModules
        where currentModules[moduleID] == nil
            && module.descriptor.runtime.kind == .executable
            && enabledState(for: module) {
            _ = runExecutable(module, arguments: ["stop"])
        }
    }

    private func runExecutable(_ module: OrbModule, arguments: [String]) -> Bool {
        runExecutableResult(module, arguments: arguments).succeeded
    }

    private func runExecutableResult(_ module: OrbModule, arguments: [String]) -> (succeeded: Bool, output: String) {
        guard let executable = module.descriptor.runtime.executable else {
            return (false, "")
        }

        let executableURL = module.packageURL.appendingPathComponent(executable, isDirectory: false)
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = module.packageURL
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "ORB_MODULE_ID": module.id,
                "ORB_MODULE_PATH": module.packageURL.path
            ],
            uniquingKeysWith: { _, newValue in newValue }
        )
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus != 0, !errorOutput.isEmpty {
                NSLog("[Orb] Module \(module.id) failed: \(errorOutput)")
            }
            return (process.terminationStatus == 0, output)
        } catch {
            NSLog("[Orb] Failed to run module \(module.id): \(error)")
            return (false, "")
        }
    }

    private func enabledDefaultsKey(for moduleID: String) -> String {
        "orbModuleEnabled.\(moduleID)"
    }
}

enum OrbModuleInstallError: Error, Equatable {
    case invalidPackage(URL)
    case bundledModuleID(String)
}

enum OrbModuleInstaller {
    static func installPackage(
        from sourceURL: URL,
        into installDirectoryURL: URL,
        existingModules: [OrbModule]
    ) throws -> OrbModule {
        guard sourceURL.pathExtension == OrbModuleLoader.packageExtension,
              let candidate = OrbModuleLoader.loadModule(at: sourceURL, source: .user) else {
            throw OrbModuleInstallError.invalidPackage(sourceURL)
        }

        if existingModules.contains(where: { $0.id == candidate.id && $0.source == .bundled }) {
            throw OrbModuleInstallError.bundledModuleID(candidate.id)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installDirectoryURL, withIntermediateDirectories: true)

        if let existingUserModule = existingModules.first(where: { $0.id == candidate.id && $0.source == .user }) {
            if sameFile(sourceURL, existingUserModule.packageURL) {
                return existingUserModule
            }
            try? fileManager.removeItem(at: existingUserModule.packageURL)
        }

        let destinationURL = uniqueDestinationURL(
            for: sourceURL,
            in: installDirectoryURL,
            fileManager: fileManager
        )
        if sameFile(sourceURL, destinationURL) {
            return candidate
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        guard let installed = OrbModuleLoader.loadModule(at: destinationURL, source: .user) else {
            throw OrbModuleInstallError.invalidPackage(destinationURL)
        }
        return installed
    }

    private static func uniqueDestinationURL(
        for sourceURL: URL,
        in installDirectoryURL: URL,
        fileManager: FileManager
    ) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let packageExtension = OrbModuleLoader.packageExtension
        var destinationURL = installDirectoryURL
            .appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = installDirectoryURL
                .appendingPathComponent("\(baseName)-\(index).\(packageExtension)", isDirectory: true)
            index += 1
        }
        return destinationURL
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
