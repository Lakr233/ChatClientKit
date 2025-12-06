//
//  RemoteResponsesChatClient.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation
import ServerEvent

public final class RemoteResponsesChatClient: ChatService {
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
    private let errorExtractor: RemoteResponsesChatErrorExtractor
    private let requestTransformer: ResponsesRequestTransformer
    private let requestSanitizer: ChatRequestSanitizing

    public convenience init(
        model: String,
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        additionalHeaders: [String: String] = [:],
        additionalBodyField: [String: Any] = [:],
    ) {
        self.init(
            model: model,
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            additionalHeaders: additionalHeaders,
            additionalBodyField: additionalBodyField,
            dependencies: .live,
        )
    }

    public init(
        model: String,
        baseURL: String? = nil,
        path: String? = nil,
        apiKey: String? = nil,
        additionalHeaders: [String: String] = [:],
        additionalBodyField: [String: Any] = [:],
        dependencies: RemoteResponsesClientDependencies,
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
        requestTransformer = ResponsesRequestTransformer()
        requestSanitizer = dependencies.requestSanitizer
    }

    public func chatCompletionRequest(body: ChatRequestBody) async throws -> ChatResponseBody {
        let this = self
        logger.info("starting responses request to model: \(this.model) with \(body.messages.count) messages")
        let startTime = Date()

        let requestBody = resolve(body: body, stream: false)
        let request = try makeURLRequest(body: requestBody)
        let (data, _) = try await session.data(for: request)
        logger.debug("received responses data: \(data.count) bytes")

        if let error = errorExtractor.extractError(from: data) {
            logger.error("received responses error: \(error.localizedDescription)")
            throw error
        }

        let decoder = RemoteResponsesChatResponseDecoder(decoder: responseDecoderFactory())
        let response = try decoder.decodeResponse(from: data)
        let duration = Date().timeIntervalSince(startTime)
        let contentLength = response.choices.first?.message.content?.count ?? 0
        logger.info("completed responses request in \(String(format: "%.2f", duration))s, content length: \(contentLength)")
        return response
    }

    public func streamingChatCompletionRequest(
        body: ChatRequestBody,
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        let requestBody = resolve(body: body, stream: true)
        let request = try makeURLRequest(body: requestBody)
        let this = self
        logger.info("starting streaming responses request to model: \(this.model) with \(body.messages.count) messages, temperature: \(body.temperature ?? 1.0)")

        let processor = RemoteResponsesChatStreamProcessor(
            eventSourceFactory: eventSourceFactory,
            chunkDecoder: chunkDecoderFactory(),
            errorExtractor: errorExtractor,
        )

        return processor.stream(request: request) { [weak self] error in
            await self?.collect(error: error)
        }
    }

    public func chatCompletionsRequest(
        _ request: some ChatRequestConvertible,
    ) async throws -> ChatResponseBody {
        try await chatCompletionRequest(body: request.asChatRequestBody())
    }

    public func streamingChatCompletionsRequest(
        _ request: some ChatRequestConvertible,
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        try await streamingChatCompletionRequest(body: request.asChatRequestBody())
    }

    public func responses(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent],
    ) async throws -> ChatResponseBody {
        try await chatCompletionsRequest(ChatRequest(builder))
    }

    public func streamingResponses(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent],
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        try await streamingChatCompletionsRequest(ChatRequest(builder))
    }

    // Compatibility helpers mirroring the naming of other clients.
    public func responsesRequest(body: ChatRequestBody) async throws -> ChatResponseBody {
        try await chatCompletionRequest(body: body)
    }

    public func streamingResponsesRequest(
        body: ChatRequestBody,
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        try await streamingChatCompletionRequest(body: body)
    }

    public func makeURLRequest(
        from request: some ChatRequestConvertible,
        stream: Bool,
    ) throws -> URLRequest {
        let body = try resolve(body: request.asChatRequestBody(), stream: stream)
        return try makeURLRequest(body: body)
    }
}

private extension RemoteResponsesChatClient {
    func makeRequestBuilder() -> RemoteResponsesRequestBuilder {
        RemoteResponsesRequestBuilder(
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            additionalHeaders: additionalHeaders,
        )
    }

    func makeURLRequest(body: ResponsesRequestBody) throws -> URLRequest {
        let builder = makeRequestBuilder()
        return try builder.makeRequest(body: body, additionalField: additionalBodyField)
    }

    func resolve(body: ChatRequestBody, stream: Bool) -> ResponsesRequestBody {
        var requestBody = body.mergingAdjacentAssistantMessages()
        requestBody.model = model
        requestBody.stream = stream
        let sanitized = requestSanitizer.sanitize(requestBody)
        return requestTransformer.makeRequestBody(from: sanitized, model: model, stream: stream)
    }

    func collect(error: Swift.Error) async {
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
        logger.error("collected responses error: \(error.localizedDescription)")
    }
}
