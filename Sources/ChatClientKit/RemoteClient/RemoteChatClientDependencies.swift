//
//  RemoteChatClientDependencies.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
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

private struct DefaultEventStreamTask: EventStreamTask, @unchecked Sendable {
    let dataTask: EventSource.DataTask

    func events() -> AsyncStream<EventSource.EventType> {
        dataTask.events()
    }
}

public struct RemoteChatClientDependencies: Sendable {
    var session: URLSessioning
    var eventSourceFactory: EventSourceProducing
    var responseDecoderFactory: @Sendable () -> JSONDecoding
    var chunkDecoderFactory: @Sendable () -> JSONDecoding
    var errorExtractor: RemoteChatErrorExtractor
    var reasoningParser: ReasoningContentParser

    static var live: RemoteChatClientDependencies {
        .init(
            session: URLSession.shared,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: ReasoningContentParser()
        )
    }
}

protocol JSONDecoding: Sendable {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

struct JSONDecoderWrapper: JSONDecoding {
    private let makeDecoder: @Sendable () -> JSONDecoder

    init(makeDecoder: @escaping @Sendable () -> JSONDecoder = { JSONDecoder() }) {
        self.makeDecoder = makeDecoder
    }

    func decode<T>(_ type: T.Type, from data: Data) throws -> T where T: Decodable {
        let decoder = makeDecoder()
        return try decoder.decode(type, from: data)
    }
}
