//
//  MLXChatClient+Utilities.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation
import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
extension MLXChatClient {
    func resolve(body: ChatRequestBody, stream: Bool) -> ChatRequestBody {
        var body = body.mergingAdjacentAssistantMessages()
        body = RequestSanitizer().sanitize(body)
        body.stream = stream
        return body
    }

    func userInput(body: ChatRequestBody) throws -> UserInput {
        var messages: [Chat.Message] = []
        var toolNamesByCallID: [String: String] = [:]
        for message in body.messages {
            switch message {
            case let .assistant(content, toolCalls, _):
                let calls = toolCalls.flatMap { toolCalls -> [MLXLMCommon.ToolCall]? in
                    guard !toolCalls.isEmpty else { return nil }
                    return toolCalls.map { tc in
                        toolNamesByCallID[tc.id] = tc.function.name
                        return MLXLMCommon.ToolCall(
                            function: .init(
                                name: tc.function.name,
                                arguments: decodedToolArguments(tc.function.arguments)
                            ),
                            id: tc.id
                        )
                    }
                }
                messages.append(.assistant(
                    content.map { userInputContent(for: $0) } ?? "",
                    toolCalls: calls
                ))
            case let .system(content, _):
                messages.append(.system(userInputContent(for: content)))
            case let .developer(content, _):
                messages.append(.system(userInputContent(for: content)))
            case let .tool(content, toolCallID):
                messages.append(.tool(
                    userInputContent(for: content),
                    id: toolCallID,
                    name: toolNamesByCallID[toolCallID]
                ))
            case let .user(content, _):
                switch content {
                case let .text(text):
                    messages.append(.user(text))
                case let .parts(contentParts):
                    var textParts: [String] = []
                    var images: [UserInput.Image] = []
                    for part in contentParts {
                        switch part {
                        case let .text(text):
                            textParts.append(text)
                        case let .imageURL(url, _):
                            guard preferredKind == .vlm else { continue }
                            guard let text = url.absoluteString.components(separatedBy: ";base64,").last,
                                  let data = Data(base64Encoded: text),
                                  var image = MLXImageUtilities.decodeImage(data: data)
                            else {
                                assertionFailure()
                                continue
                            }
                            if image.extent.width < 64 || image.extent.height < 64 {
                                guard let resizedImage = MLXImageUtilities.resize(
                                    image: image,
                                    targetSize: .init(width: 64, height: 64),
                                    contentMode: .contentAspectFit
                                ) else {
                                    assertionFailure()
                                    continue
                                }
                                image = resizedImage
                            }
                            if image.extent.width > 512 || image.extent.height > 512 {
                                guard let resizedImage = MLXImageUtilities.resize(
                                    image: image,
                                    targetSize: .init(width: 512, height: 512),
                                    contentMode: .contentAspectFit
                                ) else {
                                    assertionFailure()
                                    continue
                                }
                                image = resizedImage
                            }
                            images.append(.ciImage(image))
                        case .audioBase64:
                            continue
                        }
                    }
                    if !textParts.isEmpty || !images.isEmpty {
                        messages.append(.user(
                            textParts.joined(separator: "\n"),
                            images: images
                        ))
                    }
                }
            }
        }
        let selectedTools = try body.selectedTools()
        if let directive = body.toolChoiceDirective {
            appendSystemDirective(directive, to: &messages)
        }
        let tools = convertToToolSpecs(selectedTools)
        return .init(chat: messages, tools: tools)
    }

    func generateParameters(body: ChatRequestBody) -> GenerateParameters {
        var parameters = GenerateParameters()
        parameters.maxTokens = max(body.maxCompletionTokens ?? 4096, 1)
        if let temperature = body.temperature, temperature.isFinite {
            parameters.temperature = Float(min(max(temperature, 0), 2))
        }
        return parameters
    }

    func loadContainer() async throws -> ModelContainer {
        let this = self
        switch preferredKind {
        case .llm:
            let container = try await coordinator.container(for: modelConfiguration, kind: .llm)
            logger.info("successfully loaded LLM model: \(this.modelConfiguration.name)")
            return container
        case .vlm:
            let container = try await coordinator.container(for: modelConfiguration, kind: .vlm)
            logger.info("successfully loaded VLM model: \(this.modelConfiguration.name)")
            return container
        }
    }

    func userInputContent(for messageContent: ChatRequestBody.Message.MessageContent<String, [String]>) -> String {
        switch messageContent {
        case let .text(text):
            text
        case let .parts(strings):
            strings.joined(separator: "\n")
        }
    }

    func convertToToolSpecs(_ tools: [ChatRequestBody.Tool]) -> [[String: any Sendable]]? {
        guard !tools.isEmpty else { return nil }
        return tools.map { tool -> [String: any Sendable] in
            switch tool {
            case let .function(name, description, parameters, strict):
                var function: [String: any Sendable] = [
                    "name": name,
                    "description": description ?? "",
                    "parameters": anyCodingValueToSendable(.object(parameters ?? [
                        "type": "object",
                        "properties": [:],
                    ])),
                ]
                if let strict { function["strict"] = strict }
                return [
                    "type": "function",
                    "function": function,
                ]
            }
        }
    }

    private func decodedToolArguments(_ arguments: String?) -> [String: any Sendable] {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return [String: any Sendable]()
        }
        return dictionary.mapValues(jsonValueToSendable)
    }

    private func jsonValueToSendable(_ value: Any) -> any Sendable {
        switch value {
        case is NSNull:
            NSNull()
        case let value as Bool:
            value
        case let value as Int:
            value
        case let value as Double:
            value
        case let value as String:
            value
        case let value as [Any]:
            value.map(jsonValueToSendable)
        case let value as [String: Any]:
            value.mapValues(jsonValueToSendable)
        default:
            String(describing: value)
        }
    }

    private func appendSystemDirective(
        _ directive: String,
        to messages: inout [Chat.Message]
    ) {
        if let index = messages.firstIndex(where: { $0.role == .system }) {
            messages[index].content += "\n" + directive
        } else {
            messages.insert(.system(directive), at: 0)
        }
    }

    func anyCodingValueToSendable(_ value: AnyCodingValue) -> any Sendable {
        switch value {
        case .null:
            NSNull()
        case let .bool(bool):
            bool
        case let .int(int):
            int
        case let .double(double):
            double
        case let .string(string):
            string
        case let .array(array):
            array.map { anyCodingValueToSendable($0) }
        case let .object(dictionary):
            dictionary.mapValues { anyCodingValueToSendable($0) } as [String: any Sendable]
        }
    }
}
