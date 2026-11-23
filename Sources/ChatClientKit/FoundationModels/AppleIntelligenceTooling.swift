import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
enum AppleIntelligenceToolError: Error {
    case invocationCaptured(ToolRequest)
}

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
struct AppleIntelligenceToolProxy: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema

    init(
        name: String,
        description: String?,
        parameters: [String: AnyCodingValue]?
    ) throws {
        self.name = name
        self.description = description?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.parameters = try AppleIntelligenceToolSchema.makeGenerationSchema(
            from: parameters
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let request = ToolRequest(name: name, args: arguments.jsonString)
        throw AppleIntelligenceToolError.invocationCaptured(request)
    }
}

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
extension AppleIntelligenceToolProxy {
    struct SkippedTool {
        let name: String
        let error: any Error
    }

    struct Conversion {
        let tools: [any Tool]
        let skipped: [SkippedTool]
    }

    /// Converts each tool on its own, so one schema FoundationModels can't
    /// read drops only that tool (with a warning) instead of the request.
    /// Throws only when every tool failed and the tool choice needs one.
    static func makeProxies(
        from tools: [ChatRequestBody.Tool],
        toolChoice: ChatRequestBody.ToolChoice?
    ) throws -> Conversion {
        var proxies: [any Tool] = []
        var skipped: [SkippedTool] = []
        for tool in tools {
            switch tool {
            case let .function(name, description, parameters, _):
                do {
                    try proxies.append(AppleIntelligenceToolProxy(
                        name: name,
                        description: description,
                        parameters: parameters
                    ))
                } catch {
                    logger.warning("skipping tool \(name, privacy: .public) for Apple Intelligence: its parameter schema could not be converted: \(String(describing: error), privacy: .public)")
                    skipped.append(SkippedTool(name: name, error: error))
                }
            }
        }

        if proxies.isEmpty, let firstFailure = skipped.first {
            switch toolChoice {
            case .required, .function:
                throw firstFailure.error
            case .auto, nil:
                break
            }
        }
        return Conversion(tools: proxies, skipped: skipped)
    }
}

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
enum AppleIntelligenceToolSchema {
    static func makeGenerationSchema(
        from parameters: [String: AnyCodingValue]?
    ) throws -> GenerationSchema {
        let schema = normalize(
            AppleIntelligenceJSONSchemaSanitizer.sanitize(
                parameters?.untypedDictionary ?? [
                    "type": "object",
                    "properties": [String: Any](),
                ]
            ),
            title: "ToolArguments"
        )
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return try JSONDecoder().decode(GenerationSchema.self, from: data)
    }

    private static func normalize(_ value: Any, title: String) -> Any {
        if let array = value as? [Any] {
            return array.enumerated().map { index, item in
                normalize(item, title: "\(title)Item\(index)")
            }
        }

        guard var object = value as? [String: Any] else { return value }

        if let properties = object["properties"] as? [String: Any] {
            let names = properties.keys.sorted()
            object["properties"] = Dictionary(uniqueKeysWithValues: names.map { name in
                (name, normalize(properties[name]!, title: "\(title)_\(name)"))
            })
            object["x-order"] = names
            object["required"] = object["required"] ?? [String]()
        }

        if let items = object["items"] {
            object["items"] = normalize(items, title: "\(title)Item")
        }

        if object["type"] as? String == "object" || object["properties"] != nil {
            object["type"] = "object"
            object["title"] = object["title"] ?? title
            object["properties"] = object["properties"] ?? [String: Any]()
            object["x-order"] = object["x-order"] ?? [String]()
            object["required"] = object["required"] ?? [String]()
            object["additionalProperties"] = false
        }

        return object.mapValues { normalize($0, title: title) }
    }
}

/// Rewrites a tool's JSON Schema into the subset `GenerationSchema` decodes.
/// Its decoder only reads `"type"` as a single string, so a nullable type
/// such as `["boolean", "null"]` (common in MCP tools) made the whole request
/// throw `DecodingError.typeMismatch`. Nullable values become optional
/// properties instead.
enum AppleIntelligenceJSONSchemaSanitizer {
    /// Keywords that only annotate a schema and are dropped.
    static let droppedKeywords: Set<String> = ["$schema", "$id", "$comment", "nullable"]

    static func sanitize(_ schema: [String: Any]) -> [String: Any] {
        sanitizeSchema(schema).schema
    }

    /// Returns the rewritten schema and whether it accepted `null`.
    static func sanitizeSchema(_ input: [String: Any]) -> (schema: [String: Any], nullable: Bool) {
        var object = input
        var nullable = (object["nullable"] as? Bool) == true
        for keyword in droppedKeywords {
            object.removeValue(forKey: keyword)
        }

        // A nullable union written as anyOf / oneOf: [{X}, {"type": "null"}].
        for keyword in ["anyOf", "oneOf"] {
            guard let branches = object[keyword] as? [Any] else { continue }
            var kept: [[String: Any]] = []
            var keptOther: [Any] = []
            for branch in branches {
                guard let branchObject = branch as? [String: Any] else {
                    keptOther.append(branch)
                    continue
                }
                if isNullOnly(branchObject) {
                    nullable = true
                    continue
                }
                let result = sanitizeSchema(branchObject)
                nullable = nullable || result.nullable
                kept.append(result.schema)
            }
            if kept.count == 1, keptOther.isEmpty {
                object.removeValue(forKey: keyword)
                // The parent's own keys (description, title) win.
                object.merge(kept[0]) { parent, _ in parent }
            } else if kept.isEmpty, keptOther.isEmpty {
                object.removeValue(forKey: keyword)
            } else {
                object[keyword] = kept + keptOther
            }
        }

        if let types = object["type"] as? [Any] {
            let names = types.compactMap { $0 as? String }
            let nonNull = names.filter { $0 != "null" }
            if nonNull.count != names.count || names.isEmpty { nullable = true }
            object["type"] = nonNull.first ?? "string"
        } else if object["type"] as? String == "null" {
            nullable = true
            object["type"] = "string"
        }

        if let values = object["enum"] as? [Any] {
            let nonNull = values.filter { !($0 is NSNull) }
            if nonNull.count != values.count { nullable = true }
            object["enum"] = nonNull
        }

        if var properties = object["properties"] as? [String: Any] {
            var optional: Set<String> = []
            for (name, value) in properties {
                guard let property = value as? [String: Any] else { continue }
                let result = sanitizeSchema(property)
                properties[name] = result.schema
                if result.nullable { optional.insert(name) }
            }
            object["properties"] = properties
            if let required = object["required"] as? [Any] {
                object["required"] = required
                    .compactMap { $0 as? String }
                    .filter { properties[$0] != nil && !optional.contains($0) }
            }
        } else if object["required"] != nil, object["type"] as? String != "object" {
            object.removeValue(forKey: "required")
        }

        if let items = object["items"] as? [String: Any] {
            object["items"] = sanitizeSchema(items).schema
        }

        for keyword in ["$defs", "definitions"] {
            guard var definitions = object[keyword] as? [String: Any] else { continue }
            for (name, value) in definitions {
                if let definition = value as? [String: Any] {
                    definitions[name] = sanitizeSchema(definition).schema
                }
            }
            object[keyword] = definitions
        }

        if object["type"] == nil {
            if object["properties"] != nil {
                object["type"] = "object"
            } else if object["items"] != nil {
                object["type"] = "array"
            }
        }

        return (object, nullable)
    }

    private static func isNullOnly(_ schema: [String: Any]) -> Bool {
        if schema["type"] as? String == "null" { return true }
        if let types = schema["type"] as? [Any] {
            return !types.isEmpty && types.allSatisfy { ($0 as? String) == "null" }
        }
        return false
    }
}
