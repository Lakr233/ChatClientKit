import Foundation

public protocol ChatService: AnyObject, Sendable {
    var errorCollector: ErrorCollector { get }

    func chat(body: ChatRequestBody) async throws -> ChatResponse
    func chat(body: ChatRequestBody) async throws -> [ChatResponseChunk]

    func streamingChat(body: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk>
}

public extension ChatService {
    var collectedErrors: String? {
        MainActor.isolated { errorCollector.getError() }
    }

    func setCollectedErrors(_ error: String?) async {
        await self.errorCollector.collect(error)
    }

    func chat(body: ChatRequestBody) async throws -> ChatResponse {
        let chunks: [ChatResponseChunk] = try await chat(body: body)
        return ChatResponse(chunks: chunks)
    }
    
    func chat(body: ChatRequestBody) async throws -> [ChatResponseChunk] {
        var chunks: [ChatResponseChunk] = []
        for try await chunk in try await streamingChat(body: body) {
            chunks.append(chunk)
        }
        return chunks
    }

    // MARK: - Convenience entry points

    func chat(_ request: some ChatRequestConvertible) async throws -> ChatResponse {
        try await chat(body: request.asChatRequestBody())
    }

    func chat(_ request: some ChatRequestConvertible) async throws -> [ChatResponseChunk] {
        try await chat(body: request.asChatRequestBody())
    }

    func streamingChat(_ request: some ChatRequestConvertible) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(body: request.asChatRequestBody())
    }

    func chat(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent]
    ) async throws -> [ChatResponseChunk] {
        try await chat(ChatRequest(builder))
    }

    func streamingChat(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent]
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(ChatRequest(builder))
    }
}
