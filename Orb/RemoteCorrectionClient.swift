import Foundation

struct CorrectionSuggestion: Equatable, Sendable {
    let original: String
    let replacement: String
    let location: Int
    let length: Int
    let reason: String
}

struct RemoteModelConfiguration: Sendable {
    let apiKey: String
    let model: String
    let baseURL: String
}

enum RemoteCorrectionClientError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case modelReturnedNoContent
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "缺少 API Key"
        case .invalidBaseURL:
            return "Base URL 无效"
        case .invalidResponse:
            return "模型响应格式无效"
        case .modelReturnedNoContent:
            return "模型没有返回内容"
        case let .httpStatus(statusCode, body):
            let summary = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(summary)"
        }
    }
}

struct RemoteCorrectionClient {
    func check(context: String, configuration: RemoteModelConfiguration) async throws -> CorrectionSuggestion? {
        let content = try await send(
            messages: [
                .init(role: "system", content: correctionSystemPrompt),
                .init(role: "user", content: "请检查这段文本：\n\(context)")
            ],
            configuration: configuration,
            maxTokens: 220
        )
        let response = try decodeCorrectionResponse(from: content)
        guard response.hasError else { return nil }
        guard
            let start = response.start,
            let length = response.length,
            let original = response.original,
            let replacement = response.replacement,
            length > 0,
            replacement != original
        else {
            return nil
        }

        let reason = response.reason ?? ""
        return CorrectionSuggestion(
            original: original,
            replacement: replacement,
            location: start,
            length: length,
            reason: reason
        )
    }

    func testConnection(configuration: RemoteModelConfiguration) async throws {
        _ = try await send(
            messages: [
                .init(role: "user", content: "Reply with OK.")
            ],
            configuration: configuration,
            maxTokens: 8
        )
    }

    private func send(
        messages: [ChatMessage],
        configuration: RemoteModelConfiguration,
        maxTokens: Int
    ) async throws -> String {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteCorrectionClientError.missingAPIKey
        }
        guard let url = URL(string: configuration.baseURL) else {
            throw RemoteCorrectionClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body = ChatRequest(
            model: configuration.model,
            messages: messages,
            temperature: 0,
            maxTokens: maxTokens
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteCorrectionClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw RemoteCorrectionClientError.httpStatus(httpResponse.statusCode, body)
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content, !content.isEmpty else {
            throw RemoteCorrectionClientError.modelReturnedNoContent
        }
        return content
    }

    private func decodeCorrectionResponse(from content: String) throws -> CorrectionResponse {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let response = try? JSONDecoder().decode(CorrectionResponse.self, from: data) {
            return response
        }

        guard
            let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}")
        else {
            throw RemoteCorrectionClientError.invalidResponse
        }

        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8) else {
            throw RemoteCorrectionClientError.invalidResponse
        }
        return try JSONDecoder().decode(CorrectionResponse.self, from: data)
    }

    private var correctionSystemPrompt: String {
        """
        你是中文输入错别字检查器。只检查错别字、同音字、近音字、明显用字错误。
        不要润色，不要改写语气，不要替换标点，不要补全句子。
        只有非常确定时才返回一个修改；不确定就返回 has_error=false。
        start 和 length 必须是用户文本中的 UTF-16 位置，且只返回最近文本内的一个最小替换范围。
        只返回 JSON，不要 Markdown，不要解释。
        格式：
        {"has_error":true,"start":0,"length":1,"original":"错字","replacement":"正字","reason":"简短原因"}
        或：
        {"has_error":false}
        """
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

private struct CorrectionResponse: Decodable {
    let hasError: Bool
    let start: Int?
    let length: Int?
    let original: String?
    let replacement: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case hasError = "has_error"
        case start
        case length
        case original
        case replacement
        case reason
    }
}
