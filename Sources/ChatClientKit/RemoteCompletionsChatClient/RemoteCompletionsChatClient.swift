import Foundation
import ServerEvent

public final class RemoteCompletionsChatClient: ChatService {
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
    let errorExtractor: RemoteCompletionsChatErrorExtractor
    let reasoningParser: CompletionReasoningDecoder
    let requestSanitizer: RequestSanitizing

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
        dependencies: RemoteClientDependencies
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
        requestSanitizer = dependencies.requestSanitizer
    }

    public func streamingChat(
        body: ChatRequestBody
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try await streamingChat(body: body, scripting: nil)
    }

    public func streamingChat(
        body: ChatRequestBody,
        scripting: ChatScriptingHandle?
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        let requestBody = resolve(body: body, stream: true)

        // Build the per-request scripting runtime (if configured).
        // The runner stays alive for the duration of this streamingChat
        // call — one runner per request, never reused across requests.
        let runtime = try makeScriptRuntime(body: requestBody, scripting: scripting)

        let request = try makeURLRequest(
            body: requestBody,
            preProcessor: runtime?.preProcessor
        )

        let this = self
        logger.info("starting streaming request to model: \(this.model) with \(body.messages.count) messages, temperature: \(body.temperature ?? 1.0)")

        let processor = RemoteCompletionsChatStreamProcessor(
            eventSourceFactory: eventSourceFactory,
            chunkDecoder: chunkDecoderFactory(),
            errorExtractor: errorExtractor,
            reasoningParser: reasoningParser,
            postProcessor: runtime?.postProcessor
        )

        return processor.stream(request: request) { [weak self] error in
            await self?.collect(error: error)
        }
    }

    func makeRequestBuilder() -> RemoteCompletionsChatRequestBuilder {
        RemoteCompletionsChatRequestBuilder(
            baseURL: baseURL,
            path: path,
            apiKey: apiKey,
            additionalHeaders: additionalHeaders
        )
    }

    func makeURLRequest(body: ChatRequestBody) throws -> URLRequest {
        let builder = makeRequestBuilder()
        return try builder.makeRequest(body: body, additionalField: additionalBodyField)
    }

    func makeURLRequest(
        body: ChatRequestBody,
        preProcessor: PreProcessor?
    ) throws -> URLRequest {
        let builder = makeRequestBuilder()
        return try builder.makeRequest(
            body: body,
            additionalField: additionalBodyField,
            preProcessor: preProcessor
        )
    }

    /// Build a fresh ScriptRunner + pre/post processors for this request.
    /// Returns nil if scripting is not enabled.
    private func makeScriptRuntime(
        body: ChatRequestBody,
        scripting: ChatScriptingHandle?
    ) throws -> ScriptRuntime? {
        guard let scripting, scripting.config.hasAnyStage else { return nil }
        return try ScriptRuntime.make(
            body: body,
            handle: scripting
        )
    }

    func resolve(body: ChatRequestBody, stream: Bool) -> ChatRequestBody {
        var requestBody = body.mergingAdjacentAssistantMessages()
        requestBody.model = model
        requestBody.stream = stream
        return requestSanitizer.sanitize(requestBody)
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
        logger.error("collected error: \(error.localizedDescription)")
    }
}
