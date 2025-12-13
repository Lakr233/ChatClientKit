//
//  RemoteClientDependencies.swift
//  ChatClientKit
//
//  Shared dependency container for remote chat clients.
//

import Foundation
import ServerEvent

public protocol URLSessioning: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessioning {}

public protocol EventStreamTask: Sendable {
    func events() -> AsyncStream<EventSource.EventType>
}

public protocol EventSourceProducing: Sendable {
    func makeDataTask(for request: URLRequest) -> EventStreamTask
}

public struct DefaultEventSourceFactory: EventSourceProducing {
    public func makeDataTask(for request: URLRequest) -> EventStreamTask {
        let eventSource = EventSource()
        let dataTask = eventSource.dataTask(for: request)
        return DefaultEventStreamTask(dataTask: dataTask)
    }
}

public struct DefaultEventStreamTask: EventStreamTask, @unchecked Sendable {
    public let dataTask: EventSource.DataTask

    public func events() -> AsyncStream<EventSource.EventType> {
        dataTask.events()
    }
}

public struct RemoteClientDependencies: Sendable {
    public var session: URLSessioning
    public var eventSourceFactory: EventSourceProducing
    public var responseDecoderFactory: @Sendable () -> JSONDecoding
    public var chunkDecoderFactory: @Sendable () -> JSONDecoding
    public var errorExtractor: RemoteCompletionsChatErrorExtractor
    public var reasoningParser: CompletionReasoningDecoder
    public var requestSanitizer: RequestSanitizing

    public static var live: RemoteClientDependencies {
        .init(
            session: URLSession.shared,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteCompletionsChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )
    }
}

public protocol JSONDecoding: Sendable {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

public struct JSONDecoderWrapper: JSONDecoding {
    public let makeDecoder: @Sendable () -> JSONDecoder

    public init(makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() }) {
        self.makeDecoder = makeDecoder
    }

    public func decode<T>(_ type: T.Type, from data: Data) throws -> T where T: Decodable {
        let decoder = makeDecoder()
        return try decoder.decode(type, from: data)
    }
}
