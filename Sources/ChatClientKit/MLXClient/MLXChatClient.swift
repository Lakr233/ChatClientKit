import CoreImage
import Foundation
@preconcurrency import MLXLMCommon

public class MLXChatClient: ChatService, @unchecked Sendable {
    let modelConfiguration: ModelConfiguration
    let emptyImage: CIImage = MLXImageUtilities.placeholderImage(
        size: .init(width: 64, height: 64),
    )
    let coordinator: MLXModelCoordinating
    let preferredKind: MLXModelKind

    // Hex UTF-8 bytes EF BF BD
    static let decoderErrorSuffix = String(data: Data([0xEF, 0xBF, 0xBD]), encoding: .utf8)!

    public let errorCollector = ErrorCollector.new()

    public init(
        url: URL,
        preferredKind: MLXModelKind = .llm,
        coordinator: MLXModelCoordinating = MLXModelCoordinator.shared,
    ) {
        modelConfiguration = .init(directory: url)
        self.preferredKind = preferredKind
        self.coordinator = coordinator
    }

    public func streamingChat(
        body: ChatRequestBody,
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        let resolvedBody = resolve(body: body, stream: true)
        logger.info("starting streaming chat completion request with \(resolvedBody.messages.count) messages, max tokens: \(resolvedBody.maxCompletionTokens ?? 4096)")
        let token = MLXChatClientQueue.shared.acquire()
        do {
            return try await streamingChatCompletionRequestExecute(body: resolvedBody, token: token)
        } catch {
            logger.error("streaming request failed: \(error.localizedDescription)")
            MLXChatClientQueue.shared.release(token: token)
            throw error
        }
    }

}
