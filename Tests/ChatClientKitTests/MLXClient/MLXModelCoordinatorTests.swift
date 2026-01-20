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

@Suite("MLX Model Coordinator", .serialized)
struct MLXModelCoordinatorTests {
    @Test("Coordinator caches containers for identical configuration and kind")
    func coordinator_cachesContainerForSameKey() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        guard TestHelpers.checkGPU() else { return }

        let config = try modelConfiguration()
        let coordinator = MLXModelCoordinator()

        let first = try await coordinator.container(for: config, kind: .llm)
        let second = try await coordinator.container(for: config, kind: .llm)

        #expect(first === second)
    }

    @Test("Coordinator reuses in-flight task for identical concurrent requests")
    func coordinator_reusesInFlightLoads() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        guard TestHelpers.checkGPU() else { return }

        let config = try modelConfiguration()
        let coordinator = MLXModelCoordinator()

        async let pendingFirst = coordinator.container(for: config, kind: .llm)
        async let pendingSecond = coordinator.container(for: config, kind: .llm)

        let containers = try await (pendingFirst, pendingSecond)
        #expect(containers.0 === containers.1)
    }

    @Test("Reset clears cached container")
    func coordinator_resetClearsCache() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        guard TestHelpers.checkGPU() else { return }

        let config = try modelConfiguration()
        let coordinator = MLXModelCoordinator()

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
