//
//  Created by ktiays on 2025/2/25.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Foundation

public enum AnyCodingValue: Sendable, Codable {
    case null(NSNull)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodingValue])
    case object([String: AnyCodingValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(bool):
            try container.encode(bool)
        case let .int(int):
            try container.encode(int)
        case let .double(double):
            try container.encode(double)
        case let .string(string):
            try container.encode(string)
        case let .array(array):
            try container.encode(array)
        case let .object(object):
            try container.encode(object)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null(NSNull())
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AnyCodingValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: AnyCodingValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unexpected JSON value"
            )
        }
    }
}

public extension [String: AnyCodingValue] {
    var untypedDictionary: [String: Any] {
        convertToUntypedDictionary(self)
    }
}

private func convertToUntyped(_ input: AnyCodingValue) -> Any {
    switch input {
    case .null:
        NSNull()
    case let .bool(bool):
        bool
    case let .int(int):
        int
    case let .double(double):
        double
    case let .string(string):
        string
    case let .array(array):
        array.map { convertToUntyped($0) }
    case let .object(dictionary):
        convertToUntypedDictionary(dictionary)
    }
}

private func convertToUntypedDictionary(
    _ input: [String: AnyCodingValue]
) -> [String: Any] {
    input.mapValues { v in
        switch v {
        case .null:
            NSNull()
        case let .bool(bool):
            bool
        case let .int(int):
            int
        case let .double(double):
            double
        case let .string(string):
            string
        case let .array(array):
            array.map { convertToUntyped($0) }
        case let .object(dictionary):
            convertToUntypedDictionary(dictionary)
        }
    }
}

extension AnyCodingValue: ExpressibleByNilLiteral {
    public init(nilLiteral _: ()) {
        self = .null(NSNull())
    }
}

extension AnyCodingValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: BooleanLiteralType) {
        self = .bool(value)
    }
}

extension AnyCodingValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: IntegerLiteralType) {
        self = .int(value)
    }
}

extension AnyCodingValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: FloatLiteralType) {
        self = .double(value)
    }
}

extension AnyCodingValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self = .string(value)
    }
}

extension AnyCodingValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnyCodingValue...) {
        self = .array(elements)
    }
}

extension AnyCodingValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnyCodingValue)...) {
        self = .object(.init(uniqueKeysWithValues: elements))
    }
}
