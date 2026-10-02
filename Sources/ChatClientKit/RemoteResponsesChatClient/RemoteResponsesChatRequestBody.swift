//
//  RemoteResponsesChatRequestBody.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation

struct ResponsesRequestBody: Encodable {
    var model: String?
    let input: [InputItem]
    let instructions: String?
    let stream: Bool?
    let temperature: Double?
    let maxOutputTokens: Int?
    let tools: [Tool]?
    let toolChoice: ToolChoice?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case stream
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case tools
        case toolChoice = "tool_choice"
    }
}

extension ResponsesRequestBody {
    /// Responses API `tool_choice`: modes stay bare strings, a specific
    /// function uses the flat `{"type": "function", "name": ...}` object.
    enum ToolChoice: Encodable {
        case mode(String)
        case function(name: String)

        init(_ choice: ChatRequestBody.ToolChoice) {
            switch choice {
            case .auto: self = .mode("auto")
            case .required: self = .mode("required")
            case let .function(name): self = .function(name: name)
            }
        }

        enum RootKey: CodingKey {
            case type
            case name
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case let .mode(value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case let .function(name):
                var container = encoder.container(keyedBy: RootKey.self)
                try container.encode("function", forKey: .type)
                try container.encode(name, forKey: .name)
            }
        }
    }
}

extension ResponsesRequestBody {
    struct Tool: Encodable {
        let type: String
        let name: String
        let description: String?
        let parameters: [String: AnyCodingValue]?
        let strict: Bool?

        init(_ tool: ChatRequestBody.Tool) {
            switch tool {
            case let .function(
                name: name,
                description: description,
                parameters: parameters,
                strict: strict
            ):
                type = "function"
                self.name = name
                self.description = description
                self.parameters = parameters
                self.strict = strict
            }
        }
    }
}

extension ResponsesRequestBody {
    enum InputItem: Encodable {
        case message(role: String, content: [ContentPart])
        case functionCall(id: String, callID: String, name: String, arguments: String?)
        case functionCallOutput(id: String, callID: String, output: String)

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case role
            case content
            case callID = "call_id"
            case name
            case arguments
            case output
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .message(role, content):
                try container.encode("message", forKey: .type)
                try container.encode(role, forKey: .role)
                try container.encode(content, forKey: .content)
            case let .functionCall(id, callID, name, arguments):
                try container.encode("function_call", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(callID, forKey: .callID)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(arguments, forKey: .arguments)
            case let .functionCallOutput(id, callID, output):
                try container.encode("function_call_output", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(callID, forKey: .callID)
                try container.encode(output, forKey: .output)
            }
        }
    }
}

extension ResponsesRequestBody {
    enum ContentPart: Encodable {
        case inputText(String)
        case outputText(String)
        case inputImage(url: URL, detail: ChatRequestBody.Message.ContentPart.ImageDetail?)
        case inputAudio(data: String, format: String)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case annotations
            case imageURL = "image_url"
            case detail
            case inputAudio = "input_audio"
        }

        enum AudioKeys: String, CodingKey {
            case data
            case format
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .inputText(text):
                try container.encode("input_text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .outputText(text):
                try container.encode("output_text", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encode([String](), forKey: .annotations)
            case let .inputImage(url, detail):
                // Unlike Chat Completions, the Responses API takes `image_url`
                // as a flat string next to `detail`, not as a nested object.
                try container.encode("input_image", forKey: .type)
                try container.encode(url.absoluteString, forKey: .imageURL)
                try container.encode(detail ?? .auto, forKey: .detail)
            case let .inputAudio(data, format):
                try container.encode("input_audio", forKey: .type)
                var nested = container.nestedContainer(keyedBy: AudioKeys.self, forKey: .inputAudio)
                try nested.encode(data, forKey: .data)
                try nested.encode(format, forKey: .format)
            }
        }
    }
}

struct ResponsesRequestTransformer {
    func makeRequestBody(
        from chatBody: ChatRequestBody,
        model: String,
        stream: Bool
    ) -> ResponsesRequestBody {
        var instructionsChunks: [String] = []
        var inputItems: [ResponsesRequestBody.InputItem] = []

        for message in chatBody.messages {
            switch message {
            case let .system(content, _),
                 let .developer(content, _):
                if let text = flattenTextContent(content) {
                    instructionsChunks.append(text)
                }
            case let .user(content, _):
                let parts = mapUserContent(content)
                if !parts.isEmpty {
                    inputItems.append(.message(role: "user", content: parts))
                }
            case let .assistant(content, toolCalls, _):
                if let parts = mapAssistantContent(content) {
                    inputItems.append(.message(role: "assistant", content: parts))
                }
                if let toolCalls {
                    for call in toolCalls {
                        inputItems.append(.functionCall(
                            id: makeResponsesItemID(prefix: "fc", callID: call.id),
                            callID: call.id,
                            name: call.function.name,
                            arguments: call.function.arguments
                        ))
                    }
                }
            case let .tool(content, toolCallID):
                if let text = flattenTextContent(content) {
                    inputItems.append(.functionCallOutput(
                        id: makeResponsesItemID(prefix: "fco", callID: toolCallID),
                        callID: toolCallID,
                        output: text
                    ))
                }
            }
        }

        let instructions = instructionsChunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return ResponsesRequestBody(
            model: model,
            input: inputItems,
            instructions: instructions.isEmpty ? nil : instructions,
            stream: stream,
            temperature: chatBody.temperature,
            maxOutputTokens: chatBody.maxCompletionTokens,
            tools: chatBody.tools?.map(ResponsesRequestBody.Tool.init),
            toolChoice: chatBody.toolChoice.map(ResponsesRequestBody.ToolChoice.init)
        )
    }
}

extension ResponsesRequestTransformer {
    func makeResponsesItemID(prefix: String, callID: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in callID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(prefix)_\(String(hash, radix: 16))"
    }

    func flattenTextContent(
        _ content: ChatRequestBody.Message.MessageContent<String, [String]>
    ) -> String? {
        switch content {
        case let .text(text):
            text
        case let .parts(parts):
            parts.joined(separator: "\n")
        }
    }

    func mapAssistantContent(
        _ content: ChatRequestBody.Message.MessageContent<String, [String]>?
    ) -> [ResponsesRequestBody.ContentPart]? {
        guard let content else { return nil }
        switch content {
        case let .text(text):
            if text.isEmpty { return nil }
            return [.outputText(text)]
        case let .parts(parts):
            let normalized = parts.filter { !$0.isEmpty }
            if normalized.isEmpty { return nil }
            return normalized.map(ResponsesRequestBody.ContentPart.outputText)
        }
    }

    func mapUserContent(
        _ content: ChatRequestBody.Message.MessageContent<String, [ChatRequestBody.Message.ContentPart]>
    ) -> [ResponsesRequestBody.ContentPart] {
        switch content {
        case let .text(text):
            text.isEmpty ? [] : [.inputText(text)]
        case let .parts(parts):
            parts.compactMap { part in
                switch part {
                case let .text(text):
                    text.isEmpty ? nil : .inputText(text)
                case let .imageURL(url, detail):
                    .inputImage(url: url, detail: detail)
                case let .audioBase64(data, format):
                    data.isEmpty ? nil : .inputAudio(data: data, format: format)
                }
            }
        }
    }
}
