# ChatClientKit

ChatClientKit is a Swift Package that unifies remote LLM APIs, local MLX models, and Apple Intelligence into a single, streaming-first interface. It ships with an ergonomic request DSL, rich tool-calling support, and a flexible error-collection pipeline so you can embed conversational AI in macOS, iOS, and Catalyst apps without rewriting clients per provider.

## Highlights
- **One `ChatService` protocol** powering Remote (OpenAI-style), MLX, and Apple Intelligence clients with interchangeable APIs.
- **Streaming built-in** via `AsyncSequence` and Server-Sent Events, including structured reasoning and tool-call payloads.
- **Swift-first ergonomics** thanks to `ChatRequestBuilder` and `ChatMessageBuilder`, letting you compose prompts declaratively.
- **Tooling aware**: Tool call routing, request supplements, and custom headers/body fields for provider-specific knobs.
- **Observability ready** with the included `ChatServiceErrorCollector` and the shared `Logger` dependency.

## Requirements
- Swift 6.0 toolchain (Xcode 16 beta or Swift 6 nightly).
- macOS 14+ for MLX builds; iOS 17+/macCatalyst 17+ for runtime targets.
- Apple Intelligence integrations require the Foundation models runtime (iOS 26/macOS 26 SDKs) and run-time availability checks.

## Installation (Swift Package Manager)

```swift
// In Package.swift
dependencies: [
    .package(url: "https://github.com/your-org/ChatClientKit.git", branch: "main")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "ChatClientKit", package: "ChatClientKit")
        ]
    )
]
```

> If you vend the Logger dependency separately, keep the relative path declared in `Package.swift` or adjust to your organization’s logging package.

## Usage

### Configure a remote model
```swift
import ChatClientKit

let client = RemoteChatClient(
    model: "gpt-4o-mini",
    baseURL: "https://api.openai.com/v1/chat/completions",
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
    additionalHeaders: ["X-Client": "ChatClientKit-Demo"]
)

let response = try await client.chatCompletion {
    ChatRequest.system("You are a precise release-notes assistant.")
    ChatRequest.user("Summarize the last test run.")
    ChatRequest.temperature(0.2)
}

print(response.choices.first?.message.content ?? "")
```

### Stream responses
```swift
let stream = try await client.streamingChatCompletion {
    ChatRequest.system("You stream thoughts and final answers.")
    ChatRequest.user("Walk me through the onboarding checklist.")
}

for try await event in stream {
    switch event {
    case let .chatCompletionChunk(chunk):
        let text = chunk.choices.first?.delta.content ?? ""
        print(text, terminator: "")
    case let .tool(call):
        // Dispatch tool call to your executor.
        triggerTool(call)
    }
}
```

### Run local MLX models
```swift
let localClient = MLXChatClient(
    url: URL(fileURLWithPath: "/Models/Qwen2.5-7B-Instruct")
)

let reply = try await localClient.chatCompletion {
    ChatRequest.system("You are a privacy-first assistant running fully on-device.")
    ChatRequest.user("Draft a release tweet for ChatClientKit.")
    ChatRequest.maxCompletionTokens(512)
}
```

### Tap into Apple Intelligence
```swift
if #available(iOS 26, macOS 26, macCatalyst 26, *) {
    let aiClient = AppleIntelligenceChatClient()
    let aiResponse = try await aiClient.chatCompletion {
        ChatRequest.user("Find the action items from the last note.")
    }
}
```

### Build chat requests declaratively
```swift
let makeStandupRequest = {
    ChatRequest {
        ChatRequest.model("gpt-4o-realtime-preview")
        ChatRequest.messages {
            .system(content: .text("Keep answers concise."))
            .user(parts: [
                .text("Turn these bullet points into a standup update."),
                .fileData(.init(filename: "status.md", mimeType: "text/markdown", data: statusData))
            ])
        }
        ChatRequest.tools([
            .jsonSchema(
                name: "create_ticket",
                description: "Open a Jira ticket",
                schema: ticketSchema
            )
        ])
    }
}
```

### Collect and surface errors
```swift
do {
    _ = try await client.chatCompletion { /* ... */ }
} catch {
    let message = await client.errorCollector.getError() ?? error.localizedDescription
    presentAlert(message)
}
```

## Architecture at a Glance
- `ChatService` is the core abstraction; `RemoteChatClient`, `MLXChatClient`, and `AppleIntelligenceChatClient` conform to it.
- `RemoteClient` uses Server-Sent Events via the `ServerEvent` helper target plus `RemoteChatStreamProcessor` to decode incremental JSON chunks.
- `MLXClient` wraps MLX, MLXLLM, and MLXVLM to coordinate weights, vision inputs, and request queues for on-device inference.
- `FoundationModels` bridges Apple Intelligence personas, prompt building, and tool proxies with `LanguageModelSession`.
- `RequestBuilder` and `Supplement` keep request construction expressive while enabling additional metadata injection per provider.

## Development
- Build: `swift build`
- Test: `swift test`
- Update dependencies: `swift package update`
- When running MLX locally, make sure your model folder matches the expected MLX layout (`tokenizer.json`, `config.json`, weights shards, etc.).

## License
ChatClientKit is available under the [MIT License](LICENSE).
