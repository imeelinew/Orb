import Foundation
import Testing
@testable import Orb

struct OrbModuleTests {
    @Test func loadsBundledModuleManifestsFromPackageDirectory() throws {
        let modulesURL = try repositoryRoot()
            .appendingPathComponent("Resources/Modules", isDirectory: true)
        let modules = OrbModuleLoader.loadModules(at: modulesURL, source: .bundled)
        let ids = Set(modules.map(\.id))

        #expect(ids.contains(OrbModuleID.contextMenu))
        #expect(ids.contains(OrbModuleID.windowOperations))
        #expect(ids.contains(OrbModuleID.menuBar))
        #expect(ids.contains(OrbModuleID.inputCorrection))
    }

    @Test func exampleExecutableModuleDeclaresRunnableEntry() throws {
        let moduleURL = try repositoryRoot()
            .appendingPathComponent("Examples/OpenVSCode.orbmodule", isDirectory: true)
        let module = try #require(OrbModuleLoader.loadModule(at: moduleURL, source: .user))

        #expect(module.descriptor.runtime.kind == .executable)
        #expect(module.descriptor.runtime.executable == "bin/main")
        #expect(FileManager.default.isExecutableFile(
            atPath: moduleURL.appendingPathComponent("bin/main").path
        ))
    }

    @Test func exampleExecutableModuleSupportsStatusAndSettingsProtocol() throws {
        let moduleURL = try repositoryRoot()
            .appendingPathComponent("Examples/OpenVSCode.orbmodule", isDirectory: true)
        let executableURL = moduleURL.appendingPathComponent("bin/main")
        let defaultsDomain = "com.eli.orb.test.open-vscode-module"
        defer {
            _ = try? run("/usr/bin/defaults", arguments: ["delete", defaultsDomain])
        }

        let status = try run(
            executableURL.path,
            arguments: ["status"],
            environment: ["ORB_MODULE_ID": defaultsDomain, "ORB_MODULE_PATH": moduleURL.path],
            currentDirectoryURL: moduleURL
        )
        #expect(status == "ready")

        _ = try run(
            executableURL.path,
            arguments: ["settings", "set", "appName", "TextEdit"],
            environment: ["ORB_MODULE_ID": defaultsDomain, "ORB_MODULE_PATH": moduleURL.path],
            currentDirectoryURL: moduleURL
        )
        let appName = try run(
            executableURL.path,
            arguments: ["settings", "get", "appName"],
            environment: ["ORB_MODULE_ID": defaultsDomain, "ORB_MODULE_PATH": moduleURL.path],
            currentDirectoryURL: moduleURL
        )
        #expect(appName == "TextEdit")
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Orb.xcodeproj").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @discardableResult
    private func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, newValue in
            newValue
        }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !errorText.isEmpty {
            print(errorText)
        }
        #expect(process.terminationStatus == 0)
        return outputText
    }
}
