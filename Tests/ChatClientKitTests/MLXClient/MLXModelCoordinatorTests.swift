//
//  MLXModelCoordinatorTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
@preconcurrency import MLXVLM
import Testing

@Suite(.serialized)
struct MLXModelCoordinatorTests {
    @Test
    func `Coordinator caches containers for identical configuration and kind`() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        guard TestHelpers.checkGPU() else { return }

        let config = try modelConfiguration()
        let coordinator = MLXModelCoordinator(tokenizerLoader: StubTokenizerLoader())

        let first = try await coordinator.container(for: config, kind: .llm)
        let second = try await coordinator.container(for: config, kind: .llm)

        #expect(first === second)
    }

    @Test
    func `Coordinator reuses in-flight task for identical concurrent requests`() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        guard TestHelpers.checkGPU() else { return }

        let config = try modelConfiguration()
        let coordinator = MLXModelCoordinator(tokenizerLoader: StubTokenizerLoader())

        async let pendingFirst = coordinator.container(for: config, kind: .llm)
        async let pendingSecond = coordinator.container(for: config, kind: .llm)

        let containers = try await (pendingFirst, pendingSecond)
        #expect(containers.0 === containers.1)
    }

    @Test
    func `Reset clears cached container`() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        guard TestHelpers.checkGPU() else { return }

        let config = try modelConfiguration()
        let coordinator = MLXModelCoordinator(tokenizerLoader: StubTokenizerLoader())

        let first = try await coordinator.container(for: config, kind: .llm)
        await coordinator.reset()
        let second = try await coordinator.container(for: config, kind: .llm)

        #expect(first !== second)
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
func modelConfiguration() throws -> ModelConfiguration {
    let url = TestHelpers.fixtureURLOrSkip(named: "mlx_testing_model")
    return ModelConfiguration(directory: url)
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
private struct StubTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any Tokenizer {
        _ = directory
        return StubTokenizer()
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
private struct StubTokenizer: Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        _ = text
        _ = addSpecialTokens
        return []
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        _ = tokenIds
        _ = skipSpecialTokens
        return ""
    }

    func convertTokenToId(_ token: String) -> Int? {
        _ = token
        return nil
    }

    func convertIdToToken(_ id: Int) -> String? {
        _ = id
        return nil
    }

    var bosToken: String? {
        nil
    }

    var eosToken: String? {
        nil
    }

    var unknownToken: String? {
        nil
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
    ) throws -> [Int] {
        _ = messages
        _ = tools
        _ = additionalContext
        return []
    }
}
