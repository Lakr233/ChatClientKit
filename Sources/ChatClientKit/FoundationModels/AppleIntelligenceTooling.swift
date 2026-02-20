import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
enum AppleIntelligenceToolError: Error {
    case invocationCaptured(ToolRequest)
}

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
@Generable
struct AppleIntelligenceToolArguments: Sendable, Equatable {
    @Guide(description: "Provide a JSON-encoded string representing the arguments for this tool call.")
    var payload: String
}

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
struct AppleIntelligenceToolProxy: Tool {
    let name: String
    let description: String

    init(
        name: String,
        description: String?,
        schemaDescription: String?,
    ) {
        let trimmedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var components: [String] = []
        if let trimmedDescription, !trimmedDescription.isEmpty {
            components.append(trimmedDescription)
        }
        if let schemaDescription, !schemaDescription.isEmpty {
            components.append("Parameters schema (JSON Schema):\n\(schemaDescription)")
        }
        components.append("Return the arguments as a JSON string in the `payload` field.")

        self.name = name
        self.description = components.joined(separator: "\n\n")
    }

    func call(arguments: AppleIntelligenceToolArguments) async throws -> String {
        let payload = arguments.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ToolRequest(name: name, args: payload.isEmpty ? "{}" : payload)
        throw AppleIntelligenceToolError.invocationCaptured(request)
    }
}
