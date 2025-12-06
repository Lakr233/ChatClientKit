//
//  RemoteResponsesChatRequestBody.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation

struct ResponsesRequestBody: Sendable, Encodable {
    var model: String?
    let input: [InputItem]
    let instructions: String?
    let stream: Bool?
    let temperature: Double?
    let maxOutputTokens: Int?
    let tools: [ChatRequestBody.Tool]?

    private enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case stream
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case tools
    }
}

extension ResponsesRequestBody {
    enum InputItem: Sendable, Encodable {
        case message(role: String, content: [ContentPart])
        case functionCall(callID: String, name: String, arguments: String?)
        case functionCallOutput(callID: String, output: String)

        private enum CodingKeys: String, CodingKey {
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
            case let .functionCall(callID, name, arguments):
                try container.encode("function_call", forKey: .type)
                try container.encode(callID, forKey: .callID)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(arguments, forKey: .arguments)
            case let .functionCallOutput(callID, output):
                try container.encode("function_call_output", forKey: .type)
                try container.encode(callID, forKey: .callID)
                try container.encode(output, forKey: .output)
            }
        }
    }
}

extension ResponsesRequestBody {
    enum ContentPart: Sendable, Encodable {
        case inputText(String)
        case outputText(String)
        case inputImage(url: URL, detail: ChatRequestBody.Message.ContentPart.ImageDetail?)
        case inputAudio(data: String, format: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case annotations
            case imageURL = "image_url"
            case inputAudio = "input_audio"
        }

        private enum ImageKeys: String, CodingKey {
            case url
            case detail
        }

        private enum AudioKeys: String, CodingKey {
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
                try container.encode("input_image", forKey: .type)
                var nested = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
                try nested.encode(url, forKey: .url)
                try nested.encodeIfPresent(detail, forKey: .detail)
            case let .inputAudio(data, format):
                try container.encode("input_audio", forKey: .type)
                var nested = container.nestedContainer(keyedBy: AudioKeys.self, forKey: .inputAudio)
                try nested.encode(data, forKey: .data)
                try nested.encode(format, forKey: .format)
            }
        }
    }
}

struct ResponsesRequestTransformer: Sendable {
    func makeRequestBody(
        from chatBody: ChatRequestBody,
        model: String,
        stream: Bool,
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
            case let .assistant(content, toolCalls, _, _):
                if let parts = mapAssistantContent(content) {
                    inputItems.append(.message(role: "assistant", content: parts))
                }
                if let toolCalls {
                    for call in toolCalls {
                        inputItems.append(.functionCall(
                            callID: call.id,
                            name: call.function.name,
                            arguments: call.function.arguments,
                        ))
                    }
                }
            case let .tool(content, toolCallID):
                if let text = flattenTextContent(content) {
                    inputItems.append(.functionCallOutput(callID: toolCallID, output: text))
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
            tools: chatBody.tools,
        )
    }
}

private extension ResponsesRequestTransformer {
    func flattenTextContent(
        _ content: ChatRequestBody.Message.MessageContent<String, [String]>,
    ) -> String? {
        switch content {
        case let .text(text):
            text
        case let .parts(parts):
            parts.joined(separator: "\n")
        }
    }

    func mapAssistantContent(
        _ content: ChatRequestBody.Message.MessageContent<String, [String]>?,
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
        _ content: ChatRequestBody.Message.MessageContent<String, [ChatRequestBody.Message.ContentPart]>,
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
