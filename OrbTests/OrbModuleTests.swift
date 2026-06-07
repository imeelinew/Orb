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
        let moduleURL = try makeTemporaryExecutableModule()
        defer {
            try? FileManager.default.removeItem(at: moduleURL.deletingLastPathComponent())
        }
        let module = try #require(OrbModuleLoader.loadModule(at: moduleURL, source: .user))

        #expect(module.descriptor.runtime.kind == .executable)
        #expect(module.descriptor.runtime.executable == "bin/main")
        #expect(module.descriptor.settings.first?.desc == "The app opened by this module.")
        #expect(FileManager.default.isExecutableFile(
            atPath: moduleURL.appendingPathComponent("bin/main").path
        ))
    }

    @Test func exampleExecutableModuleSupportsStatusAndSettingsProtocol() throws {
        let moduleURL = try makeTemporaryExecutableModule()
        let executableURL = moduleURL.appendingPathComponent("bin/main")
        let defaultsDomain = "com.eli.orb.test.open-vscode-module"
        defer {
            try? FileManager.default.removeItem(at: moduleURL.deletingLastPathComponent())
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

    @Test func installerCopiesModulePackageIntoInstallDirectory() throws {
        let sourceURL = try makeTemporaryExecutableModule()
        let installDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: installDirectoryURL)
        }

        let installed = try OrbModuleInstaller.installPackage(
            from: sourceURL,
            into: installDirectoryURL,
            existingModules: []
        )

        #expect(installed.source == .user)
        #expect(installed.packageURL.deletingLastPathComponent() == installDirectoryURL)
        #expect(FileManager.default.fileExists(
            atPath: installed.packageURL.appendingPathComponent("module.json").path
        ))
        #expect(FileManager.default.isExecutableFile(
            atPath: installed.packageURL.appendingPathComponent("bin/main").path
        ))
    }

    @Test func installerRejectsModulesThatDuplicateBundledIDs() throws {
        let sourceURL = try makeTemporaryExecutableModule()
        let installDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundledModule = try #require(OrbModuleLoader.loadModule(at: sourceURL, source: .bundled))
        defer {
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: installDirectoryURL)
        }

        do {
            _ = try OrbModuleInstaller.installPackage(
                from: sourceURL,
                into: installDirectoryURL,
                existingModules: [bundledModule]
            )
            Issue.record("Expected bundled duplicate module id to be rejected")
        } catch let error as OrbModuleInstallError {
            #expect(error == .bundledModuleID(bundledModule.id))
        }
    }

    @Test func openPanelSelectionAllowsOrbModulePackages() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let moduleURL = rootURL.appendingPathComponent("CommandLine.orbmodule", isDirectory: true)
        let plainDirectoryURL = rootURL.appendingPathComponent("PlainDirectory", isDirectory: true)
        let plainFileURL = rootURL.appendingPathComponent("notes.txt")
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: moduleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plainDirectoryURL, withIntermediateDirectories: true)
        try "notes".write(to: plainFileURL, atomically: true, encoding: .utf8)

        #expect(OrbModuleOpenPanelSelection.shouldEnable(moduleURL))
        #expect(OrbModuleOpenPanelSelection.shouldEnable(plainDirectoryURL))
        #expect(!OrbModuleOpenPanelSelection.shouldEnable(plainFileURL))
        do {
            try OrbModuleOpenPanelSelection.validate(moduleURL)
        } catch {
            Issue.record("Expected .orbmodule selection to validate")
        }

        do {
            try OrbModuleOpenPanelSelection.validate(plainDirectoryURL)
            Issue.record("Expected plain directory selection to be rejected")
        } catch OrbModuleOpenPanelError.invalidSelection {
        } catch {
            Issue.record("Expected invalid selection error")
        }
    }

    @Test func installerRejectsModulesThatDuplicateUserIDs() throws {
        let sourceURL = try makeTemporaryExecutableModule()
        let installDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userModule = try #require(OrbModuleLoader.loadModule(at: sourceURL, source: .user))
        defer {
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: installDirectoryURL)
        }

        do {
            _ = try OrbModuleInstaller.installPackage(
                from: sourceURL,
                into: installDirectoryURL,
                existingModules: [userModule]
            )
            Issue.record("Expected user duplicate module id to be rejected")
        } catch let error as OrbModuleInstallError {
            #expect(error == .userModuleAlreadyInstalled(userModule.name))
        }
    }

    @Test func moduleDevelopmentOutputDefaultsToOrbModulesFolder() throws {
        let outputURL = OrbModuleDevelopmentOutput.directoryURL()

        #expect(outputURL.lastPathComponent == "Orb Modules")
        #expect(outputURL.deletingLastPathComponent().lastPathComponent == "Documents")
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

    private func makeTemporaryExecutableModule(
        id: String = "com.eli.orb.test.executable-module"
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let moduleURL = rootURL.appendingPathComponent("TestExecutable.orbmodule", isDirectory: true)
        let binURL = moduleURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifestVersion": 1,
          "id": "\(id)",
          "name": "Test Executable",
          "desc": "Test executable module.",
          "version": "1.0.0",
          "displayOrder": 1000,
          "icon": {
            "symbol": "terminal.fill",
            "gradient": ["#4AA3FF", "#1D5CFF"]
          },
          "runtime": {
            "kind": "executable",
            "adapter": null,
            "executable": "bin/main"
          },
          "defaultEnabled": false,
          "permissions": ["automation"],
          "capabilities": [
            {
              "id": "open",
              "name": "Open",
              "desc": "Open the configured app.",
              "command": "open"
            }
          ],
          "settings": [
            {
              "key": "appName",
              "title": "App Name",
              "desc": "The app opened by this module.",
              "type": "string",
              "defaultValue": "Visual Studio Code"
            }
          ]
        }
        """
        try manifest.write(
            to: moduleURL.appendingPathComponent("module.json"),
            atomically: true,
            encoding: .utf8
        )

        let script = """
        #!/bin/sh
        set -eu

        case "${1:-status}" in
          status)
            echo "ready"
            ;;
          settings)
            case "${2:-}" in
              get)
                key="${3:-}"
                [ -n "$key" ] || exit 2
                defaults read "${ORB_MODULE_ID:-\(id)}" "$key" 2>/dev/null || true
                ;;
              set)
                key="${3:-}"
                value="${4:-}"
                [ -n "$key" ] || exit 2
                defaults write "${ORB_MODULE_ID:-\(id)}" "$key" "$value"
                ;;
              *)
                exit 2
                ;;
            esac
            ;;
          start|stop)
            exit 0
            ;;
          *)
            exit 2
            ;;
        esac
        """
        let executableURL = binURL.appendingPathComponent("main")
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return moduleURL
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
