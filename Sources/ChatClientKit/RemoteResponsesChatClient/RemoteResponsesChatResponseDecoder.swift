import Foundation

struct RemoteResponsesChatResponseDecoder {
    let decoder: JSONDecoding

    init(decoder: JSONDecoding = JSONDecoderWrapper()) {
        self.decoder = decoder
    }

    func decodeResponse(from data: Data) throws -> [ChatResponseChunk] {
        let response = try decoder.decode(ResponsesAPIResponse.self, from: data)
        return response.asChatResponseBody()
    }
}

struct ResponsesAPIResponse: Decodable {
    let id: String?
    let createdAt: Double?
    let model: String?
    let output: [ResponsesOutputItem]?
    let status: String?
    let error: ResponsesErrorPayload?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case model
        case output
        case status
        case error
    }

    func asChatResponseBody() -> [ChatResponseChunk] {
        let outputItems = output ?? []

        for item in outputItems {
            if let toolCall = item.asToolRequest() {
                return [.tool(toolCall)]
            }
        }

        let reasoning = outputItems
            .compactMap { item -> String? in
                guard let parts = item.content else { return nil }
                let reasoningSegments = parts.compactMap(\.reasoningTextContent)
                guard !reasoningSegments.isEmpty else { return nil }
                return reasoningSegments.joined()
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !reasoning.isEmpty {
            return [.reasoning(reasoning)]
        }

        let text = outputItems
            .compactMap(\.textContent)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            return [.text(text)]
        }

        return [.text("")]
    }
}

struct ResponsesOutputItem: Decodable {
    let id: String?
    let type: String?
    let role: String?
    let content: [ResponsesContentPart]?
    let name: String?
    let callId: String?
    let arguments: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case content
        case name
        case callId = "call_id"
        case arguments
    }

    func asToolRequest() -> ToolRequest? {
        guard type == "function_call" else { return nil }
        let identifier = callId ?? id ?? UUID().uuidString
        let functionName = name ?? "tool"
        let args = arguments ?? "{}"
        return ToolRequest(id: identifier, name: functionName, args: args)
    }

    var textContent: String? {
        guard type == "message" else { return nil }
        let textSegments = content?.compactMap(\.resolvedContent) ?? []
        guard !textSegments.isEmpty else { return nil }
        return textSegments.joined()
    }
}

struct ResponsesContentPart: Decodable {
    let type: String
    let text: String?
}

extension ResponsesContentPart {
    var resolvedContent: String? {
        switch type {
        case "output_text", "input_text":
            text
        case let value where value.contains("refusal"):
            text ?? "[REFUSAL]"
        case let value where value.contains("audio"):
            // Placeholder for unsupported audio output in chat abstraction.
            text ?? "[AUDIO]"
        case let value where value.contains("image"):
            // Placeholder for unsupported image output in chat abstraction.
            text ?? "[IMAGE]"
        case let value where value.contains("file"):
            // Placeholder for unsupported file output in chat abstraction.
            text ?? "[FILE]"
        default:
            nil
        }
    }

    var reasoningContent: String? {
        if type.contains("reasoning"), let text {
            return text
        }
        return nil
    }

    var isRefusal: Bool {
        type.contains("refusal")
    }

    var outputTextContent: String? {
        switch type {
        case "output_text", "input_text":
            text
        default:
            nil
        }
    }

    var reasoningTextContent: String? {
        type.contains("reasoning") ? text : nil
    }

    var refusalContent: String? {
        type.contains("refusal") ? (text ?? "[REFUSAL]") : nil
    }
}

struct ResponsesErrorPayload: Decodable {
    let code: String?
    let message: String?
    let param: String?
}
