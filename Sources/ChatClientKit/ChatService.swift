import Foundation

public protocol ChatService: AnyObject, Sendable {
    var errorCollector: ErrorCollector { get }

    func chat(body: ChatRequestBody) async throws -> ChatResponse
    func streamingChat(body: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk>

    /// Scripting-aware entry point. Default implementation forwards to
    /// `streamingChat(body:)` (i.e. scripting disabled). Conformers that
    /// actually run the JavaScript hooks (`RemoteCompletionsChatClient`,
    /// `RemoteResponsesChatClient`) override this. Local-inference
    /// clients (MLX, Apple Intelligence) keep the default since they
    /// don't issue network requests and `scripting` is not meaningful.
    func streamingChat(
        body: ChatRequestBody,
        scripting: ChatScriptingHandle?
    ) async throws -> AnyAsyncSequence<ChatResponseChunk>
}

public extension ChatService {
    var collectedErrors: String? {
        MainActor.isolated { errorCollector.getError() }
    }

    func setCollectedErrors(_ error: String?) async {
        await errorCollector.collect(error)
    }

    // MARK: CHAT RESPONSE

    func chat(body: ChatRequestBody) async throws -> ChatResponse {
        let chunks: [ChatResponseChunk] = try await chatChunks(body: body)
        return ChatResponse(chunks: chunks)
    }

    func chat(body: ChatRequestBody, scripting: ChatScriptingHandle?) async throws -> ChatResponse {
        let chunks: [ChatResponseChunk] = try await chatChunks(body: body, scripting: scripting)
        return ChatResponse(chunks: chunks)
    }

    func chat(_ request: some ChatRequestConvertible) async throws -> ChatResponse {
        try await chat(body: request.asChatRequestBody())
    }

    // MARK: CHAT RESPONSE CHUNKS

    func chatChunks(body: ChatRequestBody) async throws -> [ChatResponseChunk] {
        try await chatChunks(body: body, scripting: nil)
    }

    func chatChunks(
        body: ChatRequestBody,
        scripting: ChatScriptingHandle?
    ) async throws -> [ChatResponseChunk] {
        var chunks: [ChatResponseChunk] = []
        for try await chunk in try await streamingChat(body: body, scripting: scripting) {
            chunks.append(chunk)
        }
        return chunks
    }

    func chatChunks(_ request: some ChatRequestConvertible) async throws -> [ChatResponseChunk] {
        try await chatChunks(body: request.asChatRequestBody())
    }

    func chatChunks(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent]
    ) async throws -> [ChatResponseChunk] {
        try await chatChunks(ChatRequest(builder))
    }

    // MARK: STREAMING CHAT RESPONSE CHUNKS

    /// Default implementation: forward to the no-scripting variant.
    /// Override in clients that support scripting (RemoteCompletions /
    /// RemoteResponses).
    func streamingChat(
        body: ChatRequestBody,
        scripting _: ChatScriptingHandle?
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(body: body)
    }

    func streamingChat(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent]
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(ChatRequest(builder))
    }

    func streamingChat(_ request: some ChatRequestConvertible) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(body: request.asChatRequestBody())
    }
}
