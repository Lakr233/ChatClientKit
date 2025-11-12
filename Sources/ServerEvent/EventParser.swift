//
//  EventParser.swift
//  EventSource
//
//  Copyright © 2023 Firdavs Khaydarov (Recouse). All rights reserved.
//  Licensed under the MIT License.
//

import Foundation

public protocol EventParser: Sendable {
    mutating func parse(_ data: Data) -> [EVEvent]
}

/// ``ServerEventParser`` is used to parse text data into ``ServerSentEvent``.
struct ServerEventParser: EventParser {
    private let mode: EventSource.Mode
    private var buffer = Data()

    init(mode: EventSource.Mode = .default) {
        self.mode = mode
    }

    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let colon: UInt8 = 0x3A

    mutating func parse(_ data: Data) -> [EVEvent] {
        let (separatedMessages, remainingData) = splitBuffer(for: buffer + data)
        buffer = remainingData
        return parseBuffer(for: separatedMessages)
    }

    private func parseBuffer(for rawMessages: [Data]) -> [EVEvent] {
        // Parse data to ServerMessage model
        let messages: [ServerSentEvent] = rawMessages.compactMap { ServerSentEvent.parse(from: $0, mode: mode) }

        return messages
    }

    private func splitBuffer(for data: Data) -> (completeData: [Data], remainingData: Data) {
        let separators: [[UInt8]] = [[Self.lf, Self.lf], [Self.cr, Self.lf, Self.cr, Self.lf]]

        // find last range of our separator, most likely to be fast enough
        let (chosenSeparator, lastSeparatorRange) = findLastSeparator(in: data, separators: separators)
        guard let separator = chosenSeparator, let lastSeparator = lastSeparatorRange else {
            return ([], data)
        }

        // chop everything before the last separator, going forward, O(n) complexity
        let bufferRange = data.startIndex ..< lastSeparator.upperBound
        let remainingRange = lastSeparator.upperBound ..< data.endIndex
        let rawMessages: [Data] = data[bufferRange].split(separator: separator)

        // now clean up the messages and return
        let cleanedMessages = rawMessages.map { cleanMessageData($0) }
        return (cleanedMessages, data[remainingRange])
    }

    private func findLastSeparator(in data: Data, separators: [[UInt8]]) -> ([UInt8]?, Range<Data.Index>?) {
        var chosenSeparator: [UInt8]?
        var lastSeparatorRange: Range<Data.Index>?
        for separator in separators {
            if let range = data.lastRange(of: separator) {
                if lastSeparatorRange == nil || range.upperBound > lastSeparatorRange!.upperBound {
                    chosenSeparator = separator
                    lastSeparatorRange = range
                }
            }
        }
        return (chosenSeparator, lastSeparatorRange)
    }

    private func cleanMessageData(_ messageData: Data) -> Data {
        var cleanData = messageData

        // remove trailing CR/LF characters from the end
        while !cleanData.isEmpty, cleanData.last == Self.cr || cleanData.last == Self.lf {
            cleanData = cleanData.dropLast()
        }

        // also clean internal lines within each message to remove trailing \r
        let cleanedLines = cleanData.split(separator: Self.lf)
            .map { line in line.trimming(while: { $0 == Self.cr }) }
            .joined(separator: [Self.lf])

        return Data(cleanedLines)
    }
}
