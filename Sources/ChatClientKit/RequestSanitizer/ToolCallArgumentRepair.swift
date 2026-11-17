//
//  ToolCallArgumentRepair.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2026/4/14.
//

import Foundation

public enum ToolCallArgumentRepair {
    public static func normalize(
        messages: [ChatRequestBody.Message],
        using tools: [ChatRequestBody.Tool]?
    ) -> [ChatRequestBody.Message] {
        messages.map { message in
            guard case let .assistant(content, toolCalls, reasoning) = message else {
                return message
            }
            return .assistant(
                content: content,
                toolCalls: normalize(toolCalls: toolCalls, using: tools),
                reasoning: reasoning
            )
        }
    }

    public static func normalize(
        request: ToolRequest,
        using tools: [ChatRequestBody.Tool]?
    ) -> ToolRequest {
        ToolRequest(
            id: request.id,
            name: request.name,
            args: normalize(
                arguments: request.args,
                forToolNamed: request.name,
                using: tools
            ),
            extraFields: request.extraFields
        )
    }

    public static func normalize(
        toolCalls: [ChatRequestBody.Message.ToolCall]?,
        using tools: [ChatRequestBody.Tool]?
    ) -> [ChatRequestBody.Message.ToolCall]? {
        guard let toolCalls else { return nil }
        return toolCalls.map { call in
            .init(
                id: call.id,
                function: .init(
                    name: call.function.name,
                    arguments: normalize(
                        arguments: call.function.arguments,
                        forToolNamed: call.function.name,
                        using: tools
                    )
                ),
                extraFields: call.extraFields
            )
        }
    }

    public static func normalize(
        arguments: String?,
        forToolNamed name: String,
        using tools: [ChatRequestBody.Tool]?
    ) -> String {
        let trimmed = arguments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty else {
            return trimmed
        }

        let repaired = encodeJSONObject(
            synthesizedArguments(
                for: tool(named: name, in: tools)
            )
        )
        logger.debug("repaired empty tool arguments for \(name) to \(repaired)")
        return repaired
    }
}

private extension ToolCallArgumentRepair {
    static func tool(
        named name: String,
        in tools: [ChatRequestBody.Tool]?
    ) -> ChatRequestBody.Tool? {
        tools?.first { tool in
            guard case let .function(toolName, _, _, _) = tool else {
                return false
            }
            return toolName.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    static func synthesizedArguments(
        for tool: ChatRequestBody.Tool?
    ) -> [String: AnyCodingValue] {
        guard case let .function(_, _, parameters, _) = tool else {
            return [:]
        }
        return synthesizedObject(from: .object(parameters ?? [:])) ?? [:]
    }

    static func synthesizedObject(
        from schema: AnyCodingValue
    ) -> [String: AnyCodingValue]? {
        guard let object = schema.objectValue else { return nil }

        if let properties = object["properties"]?.objectValue {
            let required = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var result: [String: AnyCodingValue] = [:]
            for key in required {
                guard let propertySchema = properties[key] else { continue }
                result[key] = defaultValue(for: propertySchema)
            }
            return result
        }

        if primaryType(in: object) == "object" {
            return [:]
        }

        if let first = object["oneOf"]?.arrayValue?.first {
            return synthesizedObject(from: first)
        }
        if let first = object["anyOf"]?.arrayValue?.first {
            return synthesizedObject(from: first)
        }
        if let first = object["allOf"]?.arrayValue?.first {
            return synthesizedObject(from: first)
        }

        return nil
    }

    static func defaultValue(
        for schema: AnyCodingValue
    ) -> AnyCodingValue {
        guard let object = schema.objectValue else {
            return .string("")
        }

        if let const = object["const"] {
            return const
        }
        if let firstEnum = object["enum"]?.arrayValue?.first {
            return firstEnum
        }

        switch primaryType(in: object) {
        case "boolean":
            return .bool(false)
        case "integer":
            return .int(0)
        case "number":
            return .double(0)
        case "array":
            return .array([])
        case "object":
            return .object(synthesizedObject(from: schema) ?? [:])
        case "null":
            return .null(NSNull())
        case "string":
            fallthrough
        default:
            if let first = object["oneOf"]?.arrayValue?.first {
                return defaultValue(for: first)
            }
            if let first = object["anyOf"]?.arrayValue?.first {
                return defaultValue(for: first)
            }
            if let first = object["allOf"]?.arrayValue?.first {
                return defaultValue(for: first)
            }
            return .string("")
        }
    }

    static func primaryType(in schema: [String: AnyCodingValue]) -> String? {
        if let type = schema["type"]?.stringValue {
            return type
        }
        if let values = schema["type"]?.arrayValue?.compactMap(\.stringValue) {
            return values.first
        }
        return nil
    }

    static func encodeJSONObject(
        _ object: [String: AnyCodingValue]
    ) -> String {
        guard let data = try? JSONEncoder.toolArgumentsEncoder.encode(object),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}

private extension AnyCodingValue {
    var objectValue: [String: AnyCodingValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [AnyCodingValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

private extension JSONEncoder {
    static let toolArgumentsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
