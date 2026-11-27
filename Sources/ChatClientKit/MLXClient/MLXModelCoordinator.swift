//
//  MLXModelCoordinator.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation
@preconcurrency internal import MLX
@preconcurrency internal import MLXLLM
@preconcurrency internal import MLXLMCommon
@preconcurrency internal import MLXVLM

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
public enum MLXModelKind: Equatable, Sendable {
    case llm
    case vlm
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
protocol MLXModelCoordinating: Sendable {
    func container(
        for configuration: ModelConfiguration,
        kind: MLXModelKind
    ) async throws -> ModelContainer

    func reset() async
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
protocol MLXModelLoading: Sendable {
    func loadLLM(
        configuration: ModelConfiguration,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> ModelContainer
    func loadVLM(
        configuration: ModelConfiguration,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> ModelContainer
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
enum MLXModelLoaderError: LocalizedError, Sendable {
    case tokenizerLoaderUnavailable
    case unsupportedModelSource(ModelConfiguration.Identifier)

    var errorDescription: String? {
        switch self {
        case .tokenizerLoaderUnavailable:
            "A tokenizer loader is required to use local MLX models with the current mlx-swift-lm."
        case .unsupportedModelSource:
            "ChatClientKit currently supports loading MLX models from a local directory only."
        }
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
struct UnavailableMLXTokenizerLoader: TokenizerLoader {
    init() {}

    func load(from directory: URL) async throws -> any Tokenizer {
        _ = directory
        throw MLXModelLoaderError.tokenizerLoaderUnavailable
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
struct DefaultMLXModelLoader: MLXModelLoading {
    init() {}

    func loadLLM(
        configuration: ModelConfiguration,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> ModelContainer {
        let directory = try modelDirectory(from: configuration)
        return try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: tokenizerLoader
        )
    }

    func loadVLM(
        configuration: ModelConfiguration,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> ModelContainer {
        let directory = try modelDirectory(from: configuration)
        return try await VLMModelFactory.shared.loadContainer(
            from: directory,
            using: tokenizerLoader
        )
    }

    private func modelDirectory(from configuration: ModelConfiguration) throws -> URL {
        switch configuration.id {
        case let .directory(directory):
            directory
        case .id:
            throw MLXModelLoaderError.unsupportedModelSource(configuration.id)
        }
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
public actor MLXModelCoordinator {
    public nonisolated static let shared = MLXModelCoordinator()

    public nonisolated static func clearMemoryCache() {
        MLX.Memory.clearCache()
    }

    struct CacheKey: Equatable {
        let identifier: ModelConfiguration.Identifier
        let kind: MLXModelKind
    }

    let loader: MLXModelLoading
    let tokenizerLoader: any TokenizerLoader
    var cachedKey: CacheKey?
    var cachedContainer: ModelContainer?
    var pendingTask: Task<ModelContainer, Error>?

    init(
        loader: MLXModelLoading = DefaultMLXModelLoader(),
        tokenizerLoader: any TokenizerLoader = DefaultMLXTokenizerLoader()
    ) {
        self.loader = loader
        self.tokenizerLoader = tokenizerLoader
    }

    func container(
        for configuration: ModelConfiguration,
        kind: MLXModelKind
    ) async throws -> ModelContainer {
        let key = CacheKey(identifier: configuration.id, kind: kind)

        if let cachedKey, cachedKey == key, let cachedContainer {
            return cachedContainer
        }

        if let cachedKey, cachedKey != key {
            cachedContainer = nil
            pendingTask?.cancel()
            pendingTask = nil
        }

        if let task = pendingTask, cachedKey == key {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            switch kind {
            case .llm:
                try await loader.loadLLM(
                    configuration: configuration,
                    tokenizerLoader: tokenizerLoader
                )
            case .vlm:
                try await loader.loadVLM(
                    configuration: configuration,
                    tokenizerLoader: tokenizerLoader
                )
            }
        }
        pendingTask = task
        cachedKey = key

        do {
            let container = try await task.value
            cachedContainer = container
            pendingTask = nil
            return container
        } catch {
            if cachedKey == key {
                cachedKey = nil
            }
            pendingTask = nil
            throw error
        }
    }

    public func reset() async {
        cachedContainer = nil
        cachedKey = nil
        pendingTask?.cancel()
        pendingTask = nil
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
extension MLXModelCoordinator: MLXModelCoordinating {}
