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

extension MLXChatClient {
    func resolve(body: ChatRequestBody, stream: Bool) -> ChatRequestBody {
        var body = body
        body.stream = stream
        return body
    }

    func userInput(body: ChatRequestBody) -> UserInput {
        var messages: [[String: String]] = []
        var images: [UserInput.Image] = []
        for message in body.messages {
            switch message {
            case let .assistant(content, _, _, _):
                guard let content else {
                    continue
                }
                let msg = ["role": "assistant", "content": userInputContent(for: content)]
                messages.append(msg)
            case let .system(content, _):
                let msg = ["role": "system", "content": userInputContent(for: content)]
                messages.append(msg)
            case let .user(content, _):
                switch content {
                case let .text(text):
                    let msg = ["role": "user", "content": text]
                    messages.append(msg)
                case let .parts(contentParts):
                    for part in contentParts {
                        switch part {
                        case let .text(text):
                            let msg = ["role": "user", "content": text]
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
                }
            default:
                continue
            }
        }
        return .init(messages: messages, images: images)
    }

    func generateParameters(body: ChatRequestBody) -> GenerateParameters {
        var parameters = GenerateParameters()
        if let temperature = body.temperature {
            parameters.temperature = Float(temperature)
        }
        return parameters
    }

    func loadContainer(adjusting userInput: inout UserInput) async throws -> ModelContainer {
        switch preferredKind {
        case .llm:
            let container = try await coordinator.container(for: modelConfiguration, kind: .llm)
            logger.infoFile("successfully loaded LLM model: \(modelConfiguration.name)")
            userInput.images = []
            return container
        case .vlm:
            let container = try await coordinator.container(for: modelConfiguration, kind: .vlm)
            logger.infoFile("successfully loaded VLM model: \(modelConfiguration.name)")
            if userInput.images.isEmpty { userInput.images.append(.ciImage(emptyImage)) }
            return container
        }
    }

    private func userInputContent(for messageContent: ChatRequestBody.Message.MessageContent<String, [String]>) -> String {
        switch messageContent {
        case let .text(text):
            text
        case let .parts(strings):
            strings.joined(separator: "\n")
        }
    }
}
