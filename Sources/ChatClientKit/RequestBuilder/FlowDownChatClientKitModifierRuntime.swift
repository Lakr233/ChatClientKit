import Foundation

struct FlowDownChatClientKitScriptError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

/// This runtime only reads immutable JSON-like config captured during request setup.
/// The script engine never mutates shared state after initialization.
struct FlowDownChatClientKitModifierRuntime: @unchecked Sendable {
    let environments: [String: Any]

    func applyRequestModifiers(
        _ modifiers: [String],
        to request: inout URLRequest,
        body: inout [String: Any]
    ) throws {
        for statement in flattenedStatements(from: modifiers) {
            if statement == FlowDownChatClientKitExtension.predefinedOAuthCodexRequestModifier {
                applyOAuthCodexPreset(to: &body)
                continue
            }

            let invocation = try parseInvocation(from: statement)
            switch invocation.name {
            case "request.body.set":
                try applySet(arguments: invocation.arguments, to: &body, scope: "request.body")
            case "request.body.remove":
                try applyRemove(arguments: invocation.arguments, from: &body, scope: "request.body")
            case "request.header.set":
                try applyHeaderSet(arguments: invocation.arguments, to: &request)
            case "request.header.remove":
                try applyHeaderRemove(arguments: invocation.arguments, from: &request)
            default:
                throw FlowDownChatClientKitScriptError("Unsupported request modifier: \(statement)")
            }
        }
    }

    func applyResponseModifiers(
        _ modifiers: [String],
        body: inout [String: Any]
    ) throws {
        for statement in flattenedStatements(from: modifiers) {
            let invocation = try parseInvocation(from: statement)
            switch invocation.name {
            case "response.body.set":
                try applySet(arguments: invocation.arguments, to: &body, scope: "response.body")
            case "response.body.remove":
                try applyRemove(arguments: invocation.arguments, from: &body, scope: "response.body")
            default:
                throw FlowDownChatClientKitScriptError("Unsupported response modifier: \(statement)")
            }
        }
    }

    private func applyOAuthCodexPreset(to body: inout [String: Any]) {
        [
            "max_output_tokens",
            "service_tier",
            "temperature",
            "text",
            "text_formatting",
            "top_p",
            "truncation",
            "user",
        ].forEach { body.removeValue(forKey: $0) }

        // ChatGPT's Codex backend stores conversations unless the caller opts out.
        // FlowDown keeps cloud models stateless unless a model config says otherwise.
        body["store"] = false
        body["instructions"] = ResponsesRequestProfile.codexHarnessInstructions
    }

    private func applySet(
        arguments: [String],
        to body: inout [String: Any],
        scope: String
    ) throws {
        switch arguments.count {
        case 1:
            let value = try resolveValue(arguments[0])
            guard let object = value as? [String: Any] else {
                throw FlowDownChatClientKitScriptError(
                    "\(scope).set(value) expects value to resolve to a JSON object."
                )
            }
            for (key, value) in object {
                body[key] = value
            }
        case 2:
            let path = try resolvePath(arguments[0])
            let value = try resolveValue(arguments[1])
            setJSONValue(value, at: path, in: &body)
        default:
            throw FlowDownChatClientKitScriptError(
                "\(scope).set expects one or two arguments."
            )
        }
    }

    private func applyRemove(
        arguments: [String],
        from body: inout [String: Any],
        scope: String
    ) throws {
        guard !arguments.isEmpty else {
            throw FlowDownChatClientKitScriptError("\(scope).remove expects at least one argument.")
        }

        for argument in arguments {
            let path = try resolvePath(argument)
            removeJSONValue(at: path, from: &body)
        }
    }

    private func applyHeaderSet(
        arguments: [String],
        to request: inout URLRequest
    ) throws {
        guard arguments.count == 2 else {
            throw FlowDownChatClientKitScriptError("request.header.set expects two arguments.")
        }

        let name = try resolveString(arguments[0], label: "request header name")
        let value = try resolveHeaderValue(arguments[1])
        request.setValue(value, forHTTPHeaderField: name)
    }

    private func applyHeaderRemove(
        arguments: [String],
        from request: inout URLRequest
    ) throws {
        guard !arguments.isEmpty else {
            throw FlowDownChatClientKitScriptError("request.header.remove expects at least one argument.")
        }

        for argument in arguments {
            let name = try resolveString(argument, label: "request header name")
            request.setValue(nil, forHTTPHeaderField: name)
        }
    }

    private func parseInvocation(from statement: String) throws -> (name: String, arguments: [String]) {
        guard let openParenIndex = statement.firstIndex(of: "("),
              statement.hasSuffix(")")
        else {
            throw FlowDownChatClientKitScriptError(
                "Expected modifier statement to look like target.action(...): \(statement)"
            )
        }

        let name = statement[..<openParenIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let argumentStart = statement.index(after: openParenIndex)
        let argumentEnd = statement.index(before: statement.endIndex)
        let argumentText = String(statement[argumentStart..<argumentEnd])
        let arguments = try splitExpression(argumentText, delimiter: ",")
        return (name, arguments)
    }

    private func flattenedStatements(from modifiers: [String]) -> [String] {
        modifiers.flatMap { modifier in
            (try? splitExpression(modifier, delimiter: ";")) ?? [modifier]
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func splitExpression(_ expression: String, delimiter: Character) throws -> [String] {
        var results: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        var previousWasEscape = false

        for character in expression {
            if previousWasEscape {
                current.append(character)
                previousWasEscape = false
                continue
            }

            if character == "\\" {
                current.append(character)
                previousWasEscape = true
                continue
            }

            if let currentQuote = quote {
                current.append(character)
                if character == currentQuote {
                    quote = nil
                }
                continue
            }

            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth -= 1
                if depth < 0 {
                    throw FlowDownChatClientKitScriptError("Unbalanced modifier expression: \(expression)")
                }
                current.append(character)
            default:
                if character == delimiter, depth == 0 {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        results.append(trimmed)
                    }
                    current.removeAll(keepingCapacity: true)
                } else {
                    current.append(character)
                }
            }
        }

        if quote != nil || depth != 0 {
            throw FlowDownChatClientKitScriptError("Unbalanced modifier expression: \(expression)")
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            results.append(trimmed)
        }
        return results
    }

    private func resolveValue(_ expression: String) throws -> Any {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("env.") {
            return try resolveEnvironmentValue(for: String(trimmed.dropFirst("env.".count)))
        }

        if trimmed == "true" {
            return true
        }
        if trimmed == "false" {
            return false
        }
        if trimmed == "null" {
            return NSNull()
        }
        if let integer = Int(trimmed) {
            return integer
        }
        if let double = Double(trimmed) {
            return double
        }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            guard let data = trimmed.data(using: .utf8) else {
                throw FlowDownChatClientKitScriptError("Failed to encode JSON expression: \(trimmed)")
            }
            return try JSONSerialization.jsonObject(with: data)
        }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return try decodeQuotedString(trimmed)
        }

        return trimmed
    }

    private func resolveEnvironmentValue(for pathExpression: String) throws -> Any {
        let path = pathExpression
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !path.isEmpty else {
            throw FlowDownChatClientKitScriptError("Environment references must include a key path.")
        }

        var current: Any = environments
        for component in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component]
            else {
                throw FlowDownChatClientKitScriptError("Missing environment value for env.\(pathExpression)")
            }
            current = next
        }
        return current
    }

    private func decodeQuotedString(_ expression: String) throws -> String {
        if expression.hasPrefix("\"") {
            guard let data = expression.data(using: .utf8)
            else {
                throw FlowDownChatClientKitScriptError("Invalid quoted string: \(expression)")
            }
            return try JSONDecoder().decode(String.self, from: data)
        }

        let content = expression.dropFirst().dropLast()
        return String(content)
            .replacingOccurrences(of: #"\'"#, with: "'")
            .replacingOccurrences(of: #"\\\\"#, with: "\\")
    }

    private func resolvePath(_ expression: String) throws -> [String] {
        let value = try resolveValue(expression)
        guard let text = value as? String else {
            throw FlowDownChatClientKitScriptError("Expected a string key path, received \(value).")
        }
        let path = text
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !path.isEmpty else {
            throw FlowDownChatClientKitScriptError("Key paths must not be empty.")
        }
        return path
    }

    private func resolveString(_ expression: String, label: String) throws -> String {
        let value = try resolveValue(expression)
        guard let text = value as? String else {
            throw FlowDownChatClientKitScriptError("Expected \(label) to resolve to a string.")
        }
        return text
    }

    private func resolveHeaderValue(_ expression: String) throws -> String {
        let value = try resolveValue(expression)
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case _ as NSNull:
            throw FlowDownChatClientKitScriptError("HTTP header values cannot be null.")
        default:
            throw FlowDownChatClientKitScriptError("HTTP header values must resolve to a scalar.")
        }
    }

    private func setJSONValue(
        _ value: Any,
        at path: [String],
        in object: inout [String: Any]
    ) {
        guard let head = path.first else { return }
        guard path.count > 1 else {
            object[head] = value
            return
        }

        var child = object[head] as? [String: Any] ?? [:]
        setJSONValue(value, at: Array(path.dropFirst()), in: &child)
        object[head] = child
    }

    private func removeJSONValue(
        at path: [String],
        from object: inout [String: Any]
    ) {
        guard let head = path.first else { return }
        guard path.count > 1 else {
            object.removeValue(forKey: head)
            return
        }

        guard var child = object[head] as? [String: Any] else { return }
        removeJSONValue(at: Array(path.dropFirst()), from: &child)
        object[head] = child
    }
}
