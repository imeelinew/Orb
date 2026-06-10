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

    @Test func normalizeSrtDropsMultilingualWhisperLoops() throws {
        let python = try normalizeSrtPython(from: subtitleScript())

        let chinese = try normalize(
            fixture: repeatedCueFixture(text: "我会觉得这个到底是什么东西"),
            language: "zh",
            python: python
        )
        let japanese = try normalize(
            fixture: repeatedTextFixture(text: "音が聞こえたので確認してください"),
            language: "ja",
            python: python
        )
        let korean = try normalize(
            fixture: repeatedCueFixture(text: "이것은 계속 반복되는 긴 자막 문장입니다"),
            language: "ko",
            python: python
        )

        #expect(chinese.components(separatedBy: "我会觉得这个到底是什么东西").count - 1 == 1)
        #expect(japanese.components(separatedBy: "音が聞こえたので確認してください").count - 1 == 1)
        #expect(korean.components(separatedBy: "이것은 계속 반복되는 긴 자막 문장입니다").count - 1 == 1)
    }

    @Test func normalizeSrtKeepsShortIntentionalRepetitions() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let cases = [
            ("zh", "好的我知道"),
            ("en", "go to sleep right now"),
            ("ko", "이제 편히 쉬어요"),
            ("ja", "わかりました")
        ]

        for (language, text) in cases {
            let normalized = try normalize(
                fixture: repeatedCueFixture(text: text),
                language: language,
                python: python
            )
            #expect(
                normalized.components(separatedBy: text).count - 1 == 4,
                "Expected intentional \(language) repetition to remain"
            )
        }
    }

    @Test func normalizeSrtPreservesKoreanWordSpacing() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let text = "이것은 아주 길고 부드러운 한국어 자막 문장이라서 여러 줄로 자연스럽게 나뉘어야 합니다"
        let normalized = try normalize(
            fixture: singleCueFixture(text: text),
            language: "ko",
            python: python
        )

        #expect(subtitleText(from: normalized, language: "ko") == text)
    }

    @Test func normalizeSrtDoesNotDuplicatePunctuationAfterPhraseCleanup() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let phrase = "音が聞こえたので確認してください"
        let normalized = try normalize(
            fixture: singleCueFixture(text: "\(phrase)。\(phrase)。"),
            language: "ja",
            python: python
        )

        #expect(subtitleText(from: normalized, language: "ja") == "\(phrase)。")
    }

    @Test func normalizeSrtPreservesSupportedLanguageText() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let cases = [
            ("en", "This is a deliberately long English subtitle sentence with contractions that shouldn't lose words, punctuation, or spacing when it wraps across several readable subtitle cues."),
            ("zh", "这是一段故意写得很长的中文字幕用来确认断句换行和时间重新分配之后不会丢失任何文字也不会凭空增加空格或标点。"),
            ("ko", "이것은 자막이 여러 줄과 여러 구간으로 나뉘더라도 원래 단어 사이의 공백과 모든 문자가 그대로 유지되는지 확인하기 위한 긴 한국어 문장입니다."),
            ("ja", "これは字幕が複数の行や区間に分割されたあとでも元の文字や句読点が失われず余計な空白も追加されないことを確認するための長い日本語の文章です。")
        ]

        for (language, text) in cases {
            let normalized = try normalize(
                fixture: singleCueFixture(text: text),
                language: language,
                python: python
            )
            #expect(subtitleText(from: normalized, language: language) == text)
        }
    }

    @Test func normalizeSrtPreservesSpacesAfterPunctuation() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let cases = [
            ("en", "word0 word1 word2 word3 word4 word5 word6 word7. word8 word9 word10 word11 word12 word13 word14 word15 word16 word17 word18! word19 word20 word21 word22 word23 word24"),
            ("ko", "하나 둘 셋 넷 다섯 여섯 일곱 여덟. 아홉 열 천천히 숨을 쉬고 편안하게 눈을 감아요! 이제 깊은 잠에 들어갑니다")
        ]

        for (language, text) in cases {
            let normalized = try normalize(
                fixture: singleCueFixture(text: text),
                language: language,
                python: python
            )
            #expect(subtitleText(from: normalized, language: language) == text)
        }
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

    @Test func normalizeSrtKeepsTimingsValidForDenseText() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let cases = [
            ("en", (0..<80).map { "word\($0)" }.joined(separator: " ")),
            ("zh", String((0..<150).compactMap { UnicodeScalar(0x4E00 + $0).map(Character.init) })),
            ("ko", (0..<80).map { "단어\($0)" }.joined(separator: " ")),
            ("ja", String((0..<150).compactMap { UnicodeScalar(0x3041 + ($0 % 80)).map(Character.init) }))
        ]

        for (language, text) in cases {
            let normalized = try normalize(
                fixture: singleCueFixture(text: text, end: "00:00:01,000"),
                language: language,
                python: python
            )
            let timings = subtitleTimings(from: normalized)

            #expect(timings.allSatisfy { $0.start < $0.end })
            #expect(zip(timings, timings.dropFirst()).allSatisfy { $0.end <= $1.start })
            #expect(timings.last?.end ?? 0 <= 1_000)
            #expect(subtitleText(from: normalized, language: language) == text)
        }
    }

    @Test func normalizeSrtPreservesTextWhenDurationIsShorterThanChunkCount() throws {
        let python = try normalizeSrtPython(from: subtitleScript())
        let text = (0..<40).map { "word\($0)" }.joined(separator: " ")
        let normalized = try normalize(
            fixture: singleCueFixture(text: text, end: "00:00:00,001"),
            language: "en",
            python: python
        )
        let timings = subtitleTimings(from: normalized)

        #expect(timings.count == 1)
        #expect(timings.first?.start == 0)
        #expect(timings.first?.end == 1)
        #expect(subtitleText(from: normalized, language: "en") == text)
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

    @Test func unsupportedWhisperLanguageFallsBackToEnglish() throws {
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

        #expect(resolved == "en")
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

    @Test func subtitleLanguageSelectionOnlySupportsChineseEnglishKoreanJapanese() {
        #expect(
            SubtitleConfiguration.supportedWhisperLanguages.map(\.code)
                == ["zh", "en", "ko", "ja"]
        )
        #expect(SubtitleConfiguration.resolvedWhisperLanguage(storedValue: "zh") == "zh")
        #expect(SubtitleConfiguration.resolvedWhisperLanguage(storedValue: "auto") == "en")
        #expect(SubtitleConfiguration.resolvedWhisperLanguage(storedValue: "fr") == "en")
        #expect(SubtitleConfiguration.resolvedWhisperLanguage(storedValue: nil) == "en")
    }

    @Test func subtitleScriptRejectsUnsupportedConfiguredLanguages() throws {
        let script = try subtitleScript()
        let python = try subtitleConfigPython(from: script)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("subtitle-config.json")
        for language in ["zh", "en", "ko", "ja"] {
            try #"{"whisperLang":"\#(language)"}"#
                .write(to: configURL, atomically: true, encoding: .utf8)
            let supported = try runPython(python, arguments: [configURL.path])
            #expect(supported.contains("WHISPER_LANG=\(language)"))
        }

        for language in ["auto", "fr"] {
            try #"{"whisperLang":"\#(language)"}"#
                .write(to: configURL, atomically: true, encoding: .utf8)
            let unsupported = try runPython(python, arguments: [configURL.path])
            #expect(unsupported.contains("WHISPER_LANG=en"))
        }

        #expect(script.contains(#"WHISPER_LANG="en""#))
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
        guard let start = script.range(of: "resolve_whisper_language() {") else {
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

    private func subtitleConfigPython(from script: String) throws -> String {
        guard let heredocRange = script.range(of: "<<'PYCFG'\n") else {
            throw ExtractionError.missingConfigPythonHeredoc
        }
        guard let endRange = script.range(
            of: "\nPYCFG",
            range: heredocRange.upperBound..<script.endIndex
        ) else {
            throw ExtractionError.missingConfigPythonEnd
        }
        return String(script[heredocRange.upperBound..<endRange.lowerBound])
    }

    private enum ExtractionError: Error {
        case missingNormalizeFunction
        case missingPythonHeredoc
        case missingPythonEnd
        case missingLanguageFunction
        case missingLanguageFunctionEnd
        case missingConfigPythonHeredoc
        case missingConfigPythonEnd
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
