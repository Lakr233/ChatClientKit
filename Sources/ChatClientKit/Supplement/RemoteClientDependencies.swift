//
//  RemoteClientDependencies.swift
//  ChatClientKit
//
//  Shared dependency container for remote chat clients.
//

import Foundation
import ServerEvent

protocol URLSessioning: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessioning {}

protocol EventStreamTask: Sendable {
    func events() -> AsyncStream<EventSource.EventType>
}

protocol EventSourceProducing: Sendable {
    func makeDataTask(for request: URLRequest) -> EventStreamTask
}

struct DefaultEventSourceFactory: EventSourceProducing {
    func makeDataTask(for request: URLRequest) -> EventStreamTask {
        let eventSource = EventSource()
        let dataTask = eventSource.dataTask(for: request)
        return DefaultEventStreamTask(dataTask: dataTask)
    }
}

struct DefaultEventStreamTask: EventStreamTask, @unchecked Sendable {
    let dataTask: EventSource.DataTask

    func events() -> AsyncStream<EventSource.EventType> {
        dataTask.events()
    }
}

public struct RemoteClientDependencies: Sendable {
    var session: URLSessioning
    var eventSourceFactory: EventSourceProducing
    var responseDecoderFactory: @Sendable () -> JSONDecoding
    var chunkDecoderFactory: @Sendable () -> JSONDecoding
    var errorExtractor: RemoteCompletionsChatErrorExtractor
    var reasoningParser: CompletionReasoningContentCollector
    var requestSanitizer: RequestSanitizing

    static var live: RemoteClientDependencies {
        .init(
            session: URLSession.shared,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteCompletionsChatErrorExtractor(),
            reasoningParser: CompletionReasoningContentCollector(),
            requestSanitizer: RequestSanitizer(),
        )
    }
}

protocol JSONDecoding: Sendable {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

struct JSONDecoderWrapper: JSONDecoding {
    let makeDecoder: @Sendable () -> JSONDecoder

    init(makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() }) {
        self.makeDecoder = makeDecoder
    }

    func decode<T>(_ type: T.Type, from data: Data) throws -> T where T: Decodable {
        let decoder = makeDecoder()
        return try decoder.decode(type, from: data)
    }
}
