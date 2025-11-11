//
//  RemoteChatClient.swift
//  ChatClientKit
//
//  Created by ktiays on 2025/2/12.
//  Refactored by GPT-5 Codex on 2025/11/10.
//

import Foundation
import ServerEvent

public final class RemoteChatClient: ChatService {
    /// The ID of the model to use.
    ///
    /// The required section should be in alphabetical order.
    public let model: String
    public let baseURL: String?
    public let path: String?
    public let apiKey: String?

    public enum Error: Swift.Error {
        case invalidURL
        case invalidApiKey
        case invalidData
    }

    public let errorCollector = ChatServiceErrorCollector()

    public let additionalHeaders: [String: String]
    public nonisolated(unsafe) let additionalBodyField: [String: Any]

    private let session: URLSessioning
    private let eventSourceFactory: EventSourceProducing
    private let responseDecoderFactory: @Sendable () -> JSONDecoding
    private let chunkDecoderFactory: @Sendable () -> JSONDecoding
    private let errorExtractor: RemoteChatErrorExtractor
    private let reasoningParser: ReasoningContentParser

    public convenience init(
        model: String,
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        additionalHeaders: [String: String] = [:],
        additionalBodyField: [String: Any] = [:]
    ) {
        self.init(
            model: model,
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            additionalHeaders: additionalHeaders,
            additionalBodyField: additionalBodyField,
            dependencies: .live
        )
    }

    public init(
        model: String,
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        additionalHeaders: [String: String] = [:],
        additionalBodyField: [String: Any] = [:],
        dependencies: RemoteChatClientDependencies
    ) {
        self.model = model
        self.baseURL = baseURL
        self.path = path
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
        self.additionalBodyField = additionalBodyField
        session = dependencies.session
        eventSourceFactory = dependencies.eventSourceFactory
        responseDecoderFactory = dependencies.responseDecoderFactory
        chunkDecoderFactory = dependencies.chunkDecoderFactory
        errorExtractor = dependencies.errorExtractor
        reasoningParser = dependencies.reasoningParser
    }

    public func chatCompletionRequest(body: ChatRequestBody) async throws -> ChatResponseBody {
        logger.infoFile("starting non-streaming request to model: \(model) with \(body.messages.count) messages")
        let startTime = Date()

        let requestBody = resolve(body: body, stream: false)
        let request = try makeURLRequest(body: requestBody)
        let (data, _) = try await session.data(for: request)
        logger.debugFile("received response data: \(data.count) bytes")

        if let error = errorExtractor.extractError(from: data) {
            logger.errorFile("received error from server: \(error.localizedDescription)")
            throw error
        }

        let responseDecoder = RemoteChatResponseDecoder(
            decoder: responseDecoderFactory(),
            reasoningParser: reasoningParser
        )
        let response = try responseDecoder.decodeResponse(from: data)
        let duration = Date().timeIntervalSince(startTime)
        let contentLength = response.choices.first?.message.content?.count ?? 0
        logger.infoFile("completed non-streaming request in \(String(format: "%.2f", duration))s, content length: \(contentLength)")
        return response
    }

    public func streamingChatCompletionRequest(
        body: ChatRequestBody
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        let requestBody = resolve(body: body, stream: true)
        let request = try makeURLRequest(body: requestBody)
        logger.infoFile("starting streaming request to model: \(model) with \(body.messages.count) messages, temperature: \(body.temperature ?? 1.0)")

        let processor = RemoteChatStreamProcessor(
            eventSourceFactory: eventSourceFactory,
            chunkDecoder: chunkDecoderFactory(),
            errorExtractor: errorExtractor,
            reasoningParser: reasoningParser
        )

        return processor.stream(request: request) { [weak self] error in
            await self?.collect(error: error)
        }
    }

    public func chatCompletionRequest(
        _ request: some ChatRequestConvertible
    ) async throws -> ChatResponseBody {
        try await chatCompletionRequest(body: request.asChatRequestBody())
    }

    public func streamingChatCompletionRequest(
        _ request: some ChatRequestConvertible
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        try await streamingChatCompletionRequest(body: request.asChatRequestBody())
    }

    /// Executes a chat completion using the Swift DSL for building requests.
    ///
    /// ```swift
    /// let response = try await client.chatCompletion {
    ///     ChatRequest.model("gpt-4o-mini")
    ///     ChatRequest.messages {
    ///         .system(content: .text("You are a helpful assistant."))
    ///         .user(content: .text("Summarize today's meeting."))
    ///     }
    /// }
    /// ```
    public func chatCompletion(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent]
    ) async throws -> ChatResponseBody {
        try await chatCompletionRequest(ChatRequest(builder))
    }

    /// Streams a chat completion using the Swift request DSL.
    public func streamingChatCompletion(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent]
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        try await streamingChatCompletionRequest(ChatRequest(builder))
    }

    public func makeURLRequest(
        from request: some ChatRequestConvertible,
        stream: Bool
    ) throws -> URLRequest {
        let body = try resolve(body: request.asChatRequestBody(), stream: stream)
        return try makeURLRequest(body: body)
    }

    private func makeRequestBuilder() -> RemoteChatRequestBuilder {
        RemoteChatRequestBuilder(
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            additionalHeaders: additionalHeaders
        )
    }

    private func makeURLRequest(body: ChatRequestBody) throws -> URLRequest {
        let builder = makeRequestBuilder()
        return try builder.makeRequest(body: body, additionalField: additionalBodyField)
    }

    private func resolve(body: ChatRequestBody, stream: Bool) -> ChatRequestBody {
        var requestBody = body
        requestBody.model = model
        requestBody.stream = stream
        return requestBody
    }

    private func collect(error: Swift.Error) async {
        if let error = error as? EventSourceError {
            switch error {
            case .undefinedConnectionError:
                await errorCollector.collect(String(localized: "Unable to connect to the server."))
            case let .connectionError(statusCode, response):
                if let decodedError = errorExtractor.extractError(from: response) {
                    await errorCollector.collect(decodedError.localizedDescription)
                } else {
                    await errorCollector.collect(String(localized: "Connection error: \(statusCode)"))
                }
            case .alreadyConsumed:
                assertionFailure()
            }
            return
        }
        await errorCollector.collect(error.localizedDescription)
        logger.errorFile("collected error: \(error.localizedDescription)")
    }
}
