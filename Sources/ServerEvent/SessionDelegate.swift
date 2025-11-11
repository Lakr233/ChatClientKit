//
//  SessionDelegate.swift
//  EventSource
//
//  Copyright © 2023 Firdavs Khaydarov (Recouse). All rights reserved.
//  Licensed under the MIT License.
//

import Foundation

final class SessionDelegate: NSObject, URLSessionDataDelegate {
    enum Event: Sendable {
        case didCompleteWithError(Error?)
        case didReceiveResponse(URLResponse, @Sendable (URLSession.ResponseDisposition) -> Void)
        case didReceiveData(Data)
    }

    private let internalStream = AsyncStream<Event>.makeStream()

    var eventStream: AsyncStream<Event> { internalStream.stream }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        internalStream.continuation.yield(.didCompleteWithError(error))
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @Sendable @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        internalStream.continuation.yield(.didReceiveResponse(response, completionHandler))
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive data: Data
    ) {
        internalStream.continuation.yield(.didReceiveData(data))
    }
}
