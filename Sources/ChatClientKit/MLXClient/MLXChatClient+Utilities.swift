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

    func userInput(body: ChatRequestBody) -> UserInput {
        var messages: [[String: any Sendable]] = []
        var images: [UserInput.Image] = []
        for message in body.messages {
            switch message {
            case let .assistant(content, toolCalls, _):
                var msg: [String: any Sendable] = ["role": "assistant"]
                if let content { msg["content"] = userInputContent(for: content) }
                if let toolCalls, !toolCalls.isEmpty {
                    msg["tool_calls"] = toolCalls.map { tc -> [String: any Sendable] in
                        [
                            "type": "function",
                            "id": tc.id,
                            "function": [
                                "name": tc.function.name,
                                "arguments": tc.function.arguments ?? "",
                            ] as [String: any Sendable],
                        ]
                    }
                }
                messages.append(msg)
            case let .system(content, _):
                let msg: [String: any Sendable] = ["role": "system", "content": userInputContent(for: content)]
                messages.append(msg)
            case let .tool(content, toolCallID):
                messages.append([
                    "role": "tool",
                    "content": userInputContent(for: content),
                    "tool_call_id": toolCallID,
                ])
            case let .user(content, _):
                switch content {
                case let .text(text):
                    let msg: [String: any Sendable] = ["role": "user", "content": text]
                    messages.append(msg)
                case let .parts(contentParts):
                    for part in contentParts {
                        switch part {
                        case let .text(text):
                            let msg: [String: any Sendable] = ["role": "user", "content": text]
                            messages.append(msg)
                        case let .imageURL(url, _):
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
                                    contentMode: .contentAspectFit,
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
                                    contentMode: .contentAspectFit,
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
                }
            default:
                continue
            }
        }
        let tools = convertToToolSpecs(body.tools)
        return .init(messages: messages, images: images, tools: tools)
    }

    func generateParameters(body: ChatRequestBody) -> GenerateParameters {
        var parameters = GenerateParameters()
        if let temperature = body.temperature {
            parameters.temperature = Float(temperature)
        }
        return parameters
    }

    func loadContainer(adjusting userInput: inout UserInput) async throws -> ModelContainer {
        let this = self
        switch preferredKind {
        case .llm:
            let container = try await coordinator.container(for: modelConfiguration, kind: .llm)
            logger.info("successfully loaded LLM model: \(this.modelConfiguration.name)")
            userInput.images = []
            return container
        case .vlm:
            let container = try await coordinator.container(for: modelConfiguration, kind: .vlm)
            logger.info("successfully loaded VLM model: \(this.modelConfiguration.name)")
            if userInput.images.isEmpty { userInput.images.append(.ciImage(emptyImage)) }
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

    func convertToToolSpecs(_ tools: [ChatRequestBody.Tool]?) -> [[String: any Sendable]]? {
        guard let tools, !tools.isEmpty else { return nil }
        return tools.map { tool -> [String: any Sendable] in
            switch tool {
            case let .function(name, description, parameters, strict):
                var function: [String: any Sendable] = ["name": name]
                if let description { function["description"] = description }
                if let parameters { function["parameters"] = anyCodingValueToSendable(.object(parameters)) }
                if let strict { function["strict"] = strict }
                return [
                    "type": "function",
                    "function": function,
                ]
            }
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
