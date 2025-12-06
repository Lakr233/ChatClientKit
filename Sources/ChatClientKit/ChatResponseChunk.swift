import Foundation

public enum ChatResponseChunk: Sendable, Equatable {
    case reasoning(String)
    case text(String)
    case image(ImageContent)
    case tool(ToolRequest)
}

public extension ChatResponseChunk {
    var textValue: String? {
        if case let .text(value) = self { value } else { nil }
    }

    var reasoningValue: String? {
        if case let .reasoning(value) = self { value } else { nil }
    }

    var imageValue: ImageContent? {
        if case let .image(value) = self { value } else { nil }
    }

    var toolValue: ToolRequest? {
        if case let .tool(value) = self { value } else { nil }
    }
}
