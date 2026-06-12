import Foundation
import Testing
@testable import Orb

struct SubtitlePostProcessingTests {

    @Test func normalizeSrtDropsWhisperPhraseLoops() throws {
        let script = try subtitleScript()
        let python = try normalizeSrtPython(from: script)

        let normalized = try normalize(
            fixture: whisperLoopFixture,
            language: "en",
            python: python
        )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let occurrences = normalized
            .components(separatedBy: "Why don't you study my Chinese")
            .count - 1
        #expect(occurrences == 1)
        #expect(!normalized.contains("Why don't you study my Chinese She said"))
    }

    @Test func normalizeSrtKeepsSimilarButDistinctCues() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let texts = [
            "Please relax your shoulders and breathe slowly tonight",
            "Please relax your hands and breathe slowly tonight",
            "Please relax your shoulders and breathe deeply tonight",
            "Please relax your shoulders and breathe slowly again"
        ]
        let normalized = try normalize(
            fixture: cueFixture(texts: texts),
            language: "en",
            python: python
        )

        #expect(subtitleCueTexts(from: normalized, language: "en") == texts)
    }

    @Test func parseWhisperLanguageDefaultsToEnglishForEmptyLog() throws {
        let script = try subtitleScript()
        let shell = try languageResolutionShell(from: script)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("whisper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())

        let resolved = try runZsh(
            shell + "\nparse_whisper_language \"$1\"",
            arguments: [logURL.path]
        )

        #expect(resolved == "en")
    }

    @Test func parseWhisperLanguageUsesDetectedLanguage() throws {
        let script = try subtitleScript()
        let shell = try languageResolutionShell(from: script)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("whisper.log")
        try "whisper_full_with_state: auto-detected language: ja (p = 0.99)\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        let resolved = try runZsh(
            shell + "\nparse_whisper_language \"$1\"",
            arguments: [logURL.path]
        )

        #expect(resolved == "ja")
    }

    @Test func parseWhisperLanguageReturnsUnsupportedDetectionAsIs() throws {
        let script = try subtitleScript()
        let shell = try languageResolutionShell(from: script)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("whisper.log")
        try "whisper_full_with_state: auto-detected language: fr (p = 0.99)\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        let resolved = try runZsh(
            shell + "\nparse_whisper_language \"$1\"",
            arguments: [logURL.path]
        )

        #expect(resolved == "fr")
    }

    @Test func subtitleScriptUsesSingleFileWhisperPipeline() throws {
        let script = try subtitleScript()

        #expect(script.contains("whisper-cli"))
        #expect(script.contains("semantic_segment_srt"))
        #expect(script.contains("translate_srt_to_bilingual"))
        #expect(script.contains("BILINGUAL TRANSLATED"))
        #expect(script.contains("subtitle-secrets.env"))
        #expect(script.contains(#"WHISPER_LANG="auto""#))
        #expect(script.contains(#"LLM_OPENROUTER_MODEL="mimo-v2.5""#))
        #expect(!script.contains("subtitle_pipeline.py"))
        #expect(!script.contains("subtitle-config.json"))
        #expect(script.range(of: #"LLM_OPENROUTER_API_KEY="sk-"#, options: .regularExpression) == nil)
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

    private func runPython(_ source: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-"] + arguments

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "python helper failed: \(stderr)")
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func normalize(fixture: String, language: String, python: String) throws -> String {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let srtURL = directory.appendingPathComponent("fixture.srt")
        try fixture.write(to: srtURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-", srtURL.path, language]

        let input = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardError = error

        try process.run()
        input.fileHandleForWriting.write(Data(python.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "normalize_srt failed: \(stderr)")
        return try String(contentsOf: srtURL, encoding: .utf8)
    }

    private func subtitleText(from srt: String, language: String) -> String {
        subtitleCueTexts(from: srt, language: language)
            .joined(separator: language == "en" || language == "ko" ? " " : "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subtitleCueTexts(from srt: String, language: String) -> [String] {
        srt.components(separatedBy: "\n\n")
            .compactMap { block in
                let lines = block.components(separatedBy: .newlines)
                guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                    return nil
                }
                let separator = language == "en" || language == "ko" ? " " : ""
                return lines[(timeIndex + 1)...]
                    .filter { !$0.isEmpty }
                    .joined(separator: separator)
            }
    }

    private func subtitleTimings(from srt: String) -> [(start: Int, end: Int)] {
        srt.components(separatedBy: .newlines)
            .filter { $0.contains("-->") }
            .compactMap { line in
                let parts = line.components(separatedBy: "-->")
                guard parts.count == 2,
                      let start = milliseconds(from: parts[0]),
                      let end = milliseconds(from: parts[1]) else {
                    return nil
                }
                return (start, end)
            }
    }

    private func milliseconds(from timestamp: String) -> Int? {
        let parts = timestamp
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { ":,".contains($0) })
            .compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * 1_000 + parts[3]
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

    private func repeatedCueFixture(text: String, count: Int = 4) -> String {
        cueFixture(texts: Array(repeating: text, count: count))
    }

    private func cueFixture(texts: [String]) -> String {
        texts.enumerated().map { offset, text in
            let index = offset + 1
            return """
            \(index)
            00:00:0\(index - 1),000 --> 00:00:0\(index),000
            \(text)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private func singleCueFixture(text: String, end: String = "00:00:10,000") -> String {
        """
        1
        00:00:00,000 --> \(end)
        \(text)

        """
    }

    private func repeatedTextFixture(text: String) -> String {
        """
        1
        00:00:00,000 --> 00:00:04,000
        \(text)\(text)

        """
    }
}
