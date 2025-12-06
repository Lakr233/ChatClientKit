import Foundation

struct RemoteCompletionsChatResponseDecoder {
    let decoder: JSONDecoding

    init(
        decoder: JSONDecoding = JSONDecoderWrapper(),
    ) {
        self.decoder = decoder
    }

    func decodeResponse(from data: Data) throws -> [ChatResponseChunk] {
        let payload = try decoder.decode(ProviderResponse.self, from: data)
        guard let choice = payload.choices?.first, let message = choice.message else {
            return [.text("")]
        }

        if let toolCall = message.toolCalls?.first, let function = toolCall.function, let name = function.name {
            let args = function.arguments ?? "{}"
            let id = toolCall.id ?? UUID().uuidString
            return [.tool(ToolRequest(id: id, name: name, args: args))]
        }

        if let images = message.images,
           let first = images.first,
           let urlString = first.imageURL?.url,
           let parsed = parseDataURL(urlString)
        {
            return [.image(ImageContent(data: parsed.data, mimeType: parsed.mimeType))]
        }

        let text = message.content ?? ""
        return [.text(text)]
    }
}

// MARK: - Provider DTOs

struct ProviderResponse: Decodable {
    let choices: [Choice]?
}

struct Choice: Decodable {
    let message: Message?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

struct Message: Decodable {
    let content: String?
    let role: String?
    let toolCalls: [ToolCall]?
    let images: [CompletionImageCollector]?

    private enum CodingKeys: String, CodingKey {
        case content
        case role
        case toolCalls = "tool_calls"
        case images // Expected for providers like google/gemini-2.5-flash-image
    }
}

struct ToolCall: Decodable {
    let id: String?
    let type: String?
    let function: Function?
}

struct Function: Decodable {
    let name: String?
    let arguments: String?
}

struct ImageURL: Decodable {
    let url: String?
    let mimeType: String?

    enum CodingKeys: String, CodingKey {
        case url
        case mimeType = "mime_type"
    }
}

// MARK: - Helpers

extension RemoteCompletionsChatResponseDecoder {
    func parseDataURL(_ text: String) -> (data: Data, mimeType: String?)? {
        guard text.lowercased().hasPrefix("data:") else { return nil }
        let parts = text.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let header = parts[0] // data:image/png;base64
        let body = parts[1]
        let mimeType = header
            .replacingOccurrences(of: "data:", with: "")
            .replacingOccurrences(of: ";base64", with: "")
        guard let decoded = Data(base64Encoded: body) else { return nil }
        return (decoded, mimeType.isEmpty ? nil : mimeType)
    }
}
