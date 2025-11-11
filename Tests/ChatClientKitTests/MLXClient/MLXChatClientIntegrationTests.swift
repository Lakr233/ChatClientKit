//
//  MLXChatClientIntegrationTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
@preconcurrency import MLX
import Testing

@Suite("MLX ChatClient Integration")
struct MLXChatClientIntegrationTests {
    @Test("Local MLX chat completion returns content", .enabled(if: TestHelpers.isMLXModelAvailable))
    func localModelProducesContent() async throws {
        let modelURL = TestHelpers.fixtureURLOrSkip(named: "mlx_testing_model")
        let client = MLXChatClient(url: modelURL)

        let response = try await client.chatCompletionRequest(
            body: .init(
                messages: [
                    .system(content: .text("Respond succinctly with HELLO.")),
                    .user(content: .text("Say HELLO")),
                ],
                maxCompletionTokens: 32,
                temperature: 0.0
            )
        )

        let content = response.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        #expect(!content.isEmpty)
    }
}
