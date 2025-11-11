//
//  Created by ktiays on 2025/2/18.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Foundation

/// An `AsyncSequence` that performs type erasure by wrapping another.
public struct AnyAsyncSequence<Element>: AsyncSequence {
    private let source: () -> AnyAsyncIterator

    public struct AnyAsyncIterator: AsyncIteratorProtocol {
        private let nextSource: () async throws -> Element?

        public init<I>(_ iterator: I) where I: AsyncIteratorProtocol, I.Element == Element {
            var iter = iterator
            nextSource = {
                try await iter.next()
            }
        }

        public func next() async throws -> Element? {
            try await nextSource()
        }
    }

    public init<S>(_ sequence: S) where S: AsyncSequence, S.Element == Element {
        source = {
            AnyAsyncIterator(sequence.makeAsyncIterator())
        }
    }

    public func makeAsyncIterator() -> AnyAsyncIterator {
        .init(source())
    }
}

extension AsyncSequence {
    /// Wraps this asynchronous sequence with a type eraser.
    func eraseToAnyAsyncSequence() -> AnyAsyncSequence<Element> {
        .init(self)
    }
}
