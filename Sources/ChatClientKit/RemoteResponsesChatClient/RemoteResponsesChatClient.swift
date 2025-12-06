import Foundation
import ServerEvent

public class RemoteResponsesChatClient: ChatService, @unchecked Sendable {
    public let model: String
    public let baseURL: String?
    public let path: String?
    public let apiKey: String?

    public enum Error: Swift.Error {
        case invalidURL
        case invalidApiKey
        case invalidData
    }

    public let errorCollector = ErrorCollector.new()

    public let additionalHeaders: [String: String]
    public nonisolated(unsafe) let additionalBodyField: [String: Any]

    let session: URLSessioning
    let eventSourceFactory: EventSourceProducing
    let responseDecoderFactory: @Sendable () -> JSONDecoding
    let chunkDecoderFactory: @Sendable () -> JSONDecoding
    let errorExtractor: RemoteResponsesChatErrorExtractor
    let requestTransformer: ResponsesRequestTransformer
    let requestSanitizer: RequestSanitizing

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
        dependencies: RemoteClientDependencies,
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

    public func streamingChat(
        body: ChatRequestBody,
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
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

    public func streamingChatCompletionsRequest(
        _ request: some ChatRequestConvertible,
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(body: request.asChatRequestBody())
    }

    public func responses(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent],
    ) async throws -> [ChatResponseChunk] {
        try await chat(body: ChatRequest(builder).asChatRequestBody())
    }

    public func streamingResponses(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent],
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(body: ChatRequest(builder).asChatRequestBody())
    }

    // Compatibility helpers mirroring the naming of other clients.
    public func responsesRequest(body: ChatRequestBody) async throws -> [ChatResponseChunk] {
        try await chat(body: body)
    }

    public func streamingResponsesRequest(
        body: ChatRequestBody,
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(body: body)
    }

    public func makeURLRequest(
        from request: some ChatRequestConvertible,
        stream: Bool,
    ) throws -> URLRequest {
        let body = try resolve(body: request.asChatRequestBody(), stream: stream)
        return try makeURLRequest(body: body)
    }
}

extension RemoteResponsesChatClient {
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
