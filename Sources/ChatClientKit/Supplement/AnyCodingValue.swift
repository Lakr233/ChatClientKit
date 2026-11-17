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

    private struct StringCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case let .int(int):
            var container = encoder.singleValueContainer()
            try container.encode(int)
        case let .double(double):
            var container = encoder.singleValueContainer()
            try container.encode(double)
        case let .string(string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case let .array(array):
            var container = encoder.singleValueContainer()
            try container.encode(array)
        case let .object(object):
            // Encode with sorted keys so the resulting JSON is deterministic
            // regardless of the host JSONEncoder's outputFormatting. This is
            // required for stable prompt/tool serialization (prefix caching).
            var container = encoder.container(keyedBy: StringCodingKey.self)
            for key in object.keys.sorted() {
                let value = object[key]!
                try container.encode(value, forKey: StringCodingKey(stringValue: key))
            }
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

extension AnyCodingValue: Equatable {
    public static func == (lhs: AnyCodingValue, rhs: AnyCodingValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            true
        case let (.bool(a), .bool(b)):
            a == b
        case let (.int(a), .int(b)):
            a == b
        case let (.double(a), .double(b)):
            a == b
        case let (.string(a), .string(b)):
            a == b
        case let (.array(a), .array(b)):
            a == b
        case let (.object(a), .object(b)):
            a == b
        default:
            false
        }
    }
}

extension AnyCodingValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case let .bool(bool):
            hasher.combine(1)
            hasher.combine(bool)
        case let .int(int):
            hasher.combine(2)
            hasher.combine(int)
        case let .double(double):
            hasher.combine(3)
            hasher.combine(double)
        case let .string(string):
            hasher.combine(4)
            hasher.combine(string)
        case let .array(array):
            hasher.combine(5)
            hasher.combine(array)
        case let .object(object):
            hasher.combine(6)
            hasher.combine(object)
        }
    }
}

public extension [String: AnyCodingValue] {
    var untypedDictionary: [String: Any] {
        convertToUntypedDictionary(self)
    }
}

func convertToUntyped(_ input: AnyCodingValue) -> Any {
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

func convertToUntypedDictionary(
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
