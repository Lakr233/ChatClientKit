import Foundation

public enum FlowDownChatClientKitExtension: Sendable {
    public static let configurationKey = "_flowdown_chat_client_kit_"
    public static let predefinedOAuthCodexRequestModifier = "_PREDEFINED_OAUTH_CODEX"
}

struct FlowDownChatClientKitCustomization {
    let forwardedBodyFields: [String: Any]
    let environments: [String: Any]
    let requestModifiers: [String]
    let responseModifiers: [String]

    static func resolve(
        from additionalBodyField: [String: Any],
        legacyRequestModifiers: [String] = []
    ) throws -> Self {
        var forwardedBodyFields = additionalBodyField
        var environments: [String: Any] = [:]
        var requestModifiers: [String] = []
        var responseModifiers: [String] = []

        if let rawConfiguration = forwardedBodyFields.removeValue(forKey: FlowDownChatClientKitExtension.configurationKey) {
            guard let configuration = rawConfiguration as? [String: Any] else {
                throw FlowDownChatClientKitScriptError(
                    "Expected \(FlowDownChatClientKitExtension.configurationKey) to be a JSON object."
                )
            }

            environments = try parseEnvironments(from: configuration["environments"])
            requestModifiers = try parseModifiers(
                named: "request_modifiers",
                from: configuration
            )
            responseModifiers = try parseModifiers(
                named: "response_modifiers",
                from: configuration
            )
        }

        for modifier in legacyRequestModifiers where !requestModifiers.contains(modifier) {
            requestModifiers.append(modifier)
        }

        return .init(
            forwardedBodyFields: forwardedBodyFields,
            environments: environments,
            requestModifiers: requestModifiers,
            responseModifiers: responseModifiers
        )
    }

    private static func parseEnvironments(from rawValue: Any?) throws -> [String: Any] {
        guard let rawValue else { return [:] }

        if let dictionary = rawValue as? [String: Any] {
            return dictionary
        }

        guard let entries = rawValue as? [Any] else {
            throw FlowDownChatClientKitScriptError(
                "Expected environments to be an array of {name, value} objects."
            )
        }

        var environments: [String: Any] = [:]
        for entry in entries {
            guard let object = entry as? [String: Any] else {
                throw FlowDownChatClientKitScriptError(
                    "Each environment entry must be a JSON object."
                )
            }
            guard let rawName = object["name"] as? String else {
                throw FlowDownChatClientKitScriptError(
                    "Each environment entry must contain a string name."
                )
            }

            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw FlowDownChatClientKitScriptError(
                    "Environment names must be non-empty strings."
                )
            }
            guard let value = object["value"] else {
                throw FlowDownChatClientKitScriptError(
                    "Environment \(name) must provide a value."
                )
            }

            environments[name] = value
        }

        return environments
    }

    private static func parseModifiers(
        named key: String,
        from configuration: [String: Any]
    ) throws -> [String] {
        guard let rawModifiers = configuration[key] else { return [] }
        guard let modifiers = rawModifiers as? [String] else {
            throw FlowDownChatClientKitScriptError(
                "Expected \(key) to be an array of strings."
            )
        }
        return modifiers
    }
}
