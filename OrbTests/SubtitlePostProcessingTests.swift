import Foundation
import Testing

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
