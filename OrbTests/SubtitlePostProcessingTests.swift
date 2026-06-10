import Foundation
import Testing
@testable import Orb

struct SubtitlePostProcessingTests {

    @Test func normalizeSrtDropsWhisperPhraseLoops() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("Resources/Scripts/gen_subtitles.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let python = try normalizeSrtPython(from: script)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let srtURL = directory.appendingPathComponent("loop.srt")
        try whisperLoopFixture.write(to: srtURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-", srtURL.path, "en"]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        input.fileHandleForWriting.write(Data(python.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "normalize_srt failed: \(stderr)")

        let normalized = try String(contentsOf: srtURL, encoding: .utf8)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let occurrences = normalized
            .components(separatedBy: "Why don't you study my Chinese")
            .count - 1
        #expect(occurrences == 1)
        #expect(!normalized.contains("Why don't you study my Chinese She said"))
    }

    @Test func fixedWhisperLanguageDoesNotFallBackToEnglish() throws {
        let script = try subtitleScript()
        let shell = try languageResolutionShell(from: script)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("whisper.log")
        try "main: processing sample.wav, lang = zh, task = transcribe\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        let resolved = try runZsh(
            shell + "\nresolve_whisper_language \"$1\" \"$2\"",
            arguments: [logURL.path, "zh"]
        )

        #expect(resolved == "zh")
    }

    @Test func automaticWhisperLanguageStillUsesDetectedLanguage() throws {
        let script = try subtitleScript()
        let shell = try languageResolutionShell(from: script)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("whisper.log")
        try "whisper_full_with_state: auto-detected language: ja (p = 0.99)\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        let resolved = try runZsh(
            shell + "\nresolve_whisper_language \"$1\" \"$2\"",
            arguments: [logURL.path, "auto"]
        )

        #expect(resolved == "ja")
    }

    @Test func subtitleModelSelectionOnlyUsesInstalledModels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let turbo = directory.appendingPathComponent("ggml-large-v3-turbo.bin")
        FileManager.default.createFile(atPath: turbo.path, contents: Data())

        let available = SubtitleConfiguration.availableWhisperModels(in: directory)
        let resolved = SubtitleConfiguration.resolvedWhisperModel(
            storedValue: "ggml-medium.bin",
            modelsDirectory: directory
        )

        #expect(available.map(\.filename) == ["ggml-large-v3-turbo.bin"])
        #expect(resolved == "ggml-large-v3-turbo.bin")
    }

    private func subtitleScript() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("Resources/Scripts/gen_subtitles.sh")
        return try String(contentsOf: scriptURL, encoding: .utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func languageResolutionShell(from script: String) throws -> String {
        guard let start = script.range(of: "parse_whisper_language() {") else {
            throw ExtractionError.missingLanguageFunction
        }
        guard let end = script.range(
            of: "\nsmooth_eta_text() {",
            range: start.upperBound..<script.endIndex
        ) else {
            throw ExtractionError.missingLanguageFunctionEnd
        }
        return String(script[start.lowerBound..<end.lowerBound])
    }

    private func runZsh(_ source: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", source, "orb-test"] + arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "zsh helper failed: \(stderr)")
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizeSrtPython(from script: String) throws -> String {
        guard let functionRange = script.range(of: "normalize_srt() {") else {
            throw ExtractionError.missingNormalizeFunction
        }
        let functionBody = script[functionRange.upperBound...]
        guard let heredocRange = functionBody.range(of: "<<'PY'\n") else {
            throw ExtractionError.missingPythonHeredoc
        }
        guard let endRange = functionBody.range(
            of: "\nPY\n}",
            range: heredocRange.upperBound..<functionBody.endIndex
        ) else {
            throw ExtractionError.missingPythonEnd
        }
        return String(functionBody[heredocRange.upperBound..<endRange.lowerBound])
    }

    private enum ExtractionError: Error {
        case missingNormalizeFunction
        case missingPythonHeredoc
        case missingPythonEnd
        case missingLanguageFunction
        case missingLanguageFunctionEnd
    }

    private var whisperLoopFixture: String {
        """
        1
        00:10:19,520 --> 00:10:23,520
        She said, "Why don't you study my Chinese She said,"Why don't you study my Chinese

        2
        00:10:23,520 --> 00:10:27,520
        She said, "Why don't you study my Chinese

        3
        00:10:27,520 --> 00:10:31,520
        She said, "Why don't you study my Chinese

        4
        00:10:31,520 --> 00:10:35,520
        She said, "Why don't you study my Chinese

        5
        00:10:35,520 --> 00:10:39,520
        She said, "Why don't you study my Chinese

        """
    }
}
