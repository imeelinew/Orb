import Foundation

enum OrbModuleID {
    static let contextMenu = "com.eli.orb.context-menu"
    static let windowOperations = "com.eli.orb.window-operations"
    static let menuBar = "com.eli.orb.menu-bar"
    static let inputCorrection = "com.eli.orb.input-correction"
}

struct OrbModuleDescriptor: Codable, Identifiable, Hashable {
    let manifestVersion: Int
    let id: String
    let name: String
    let desc: String
    let version: String
    let displayOrder: Int?
    let icon: OrbModuleIcon
    let runtime: OrbModuleRuntime
    let defaultEnabled: Bool
    let permissions: [String]
    let capabilities: [OrbModuleCapability]
    let settings: [OrbModuleSetting]
}

struct OrbModuleIcon: Codable, Hashable {
    let symbol: String
    let gradient: [String]
}

struct OrbModuleRuntime: Codable, Hashable {
    let kind: Kind
    let adapter: String?
    let executable: String?

    enum Kind: String, Codable, Hashable {
        case native
        case executable
    }
}

struct OrbModuleCapability: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let desc: String?
    let command: String?
}

struct OrbModuleSetting: Codable, Identifiable, Hashable {
    let key: String
    let title: String
    let type: String
    let defaultValue: String?

    var id: String { key }
}

struct OrbModule: Identifiable, Hashable {
    let descriptor: OrbModuleDescriptor
    let packageURL: URL
    let source: Source

    var id: String { descriptor.id }
    var name: String { descriptor.name }
    var desc: String { descriptor.desc }
    var icon: OrbModuleIcon { descriptor.icon }

    enum Source: Hashable {
        case bundled
        case user
    }
}

enum OrbModuleLoader {
    static let packageExtension = "orbmodule"
    static let manifestFilename = "module.json"

    static func loadModules(at directoryURL: URL, source: OrbModule.Source) -> [OrbModule] {
        let fileManager = FileManager.default
        guard let packageURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return packageURLs
            .filter { $0.pathExtension == packageExtension }
            .compactMap { loadModule(at: $0, source: source) }
            .sorted(by: sortModules)
    }

    static func loadModule(at packageURL: URL, source: OrbModule.Source) -> OrbModule? {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename, isDirectory: false)
        do {
            let data = try Data(contentsOf: manifestURL)
            let descriptor = try JSONDecoder().decode(OrbModuleDescriptor.self, from: data)
            guard descriptor.manifestVersion == 1 else { return nil }
            return OrbModule(descriptor: descriptor, packageURL: packageURL, source: source)
        } catch {
            NSLog("[Orb] Failed to load module at \(packageURL.path): \(error)")
            return nil
        }
    }

    static func sortModules(_ lhs: OrbModule, _ rhs: OrbModule) -> Bool {
        let lhsOrder = lhs.descriptor.displayOrder ?? Int.max
        let rhsOrder = rhs.descriptor.displayOrder ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
