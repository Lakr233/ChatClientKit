//
//  MLXModelCoordinator.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
@preconcurrency import MLXVLM

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
public enum MLXModelKind: Equatable, Sendable {
    case llm
    case vlm
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
public protocol MLXModelCoordinating: Sendable {
    func container(
        for configuration: ModelConfiguration,
        kind: MLXModelKind,
    ) async throws -> ModelContainer

    func reset() async
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
public protocol MLXModelLoading: Sendable {
    func loadLLM(configuration: ModelConfiguration) async throws -> ModelContainer
    func loadVLM(configuration: ModelConfiguration) async throws -> ModelContainer
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
public struct DefaultMLXModelLoader: MLXModelLoading {
    public init() {}

    public func loadLLM(configuration: ModelConfiguration) async throws -> ModelContainer {
        try await LLMModelFactory.shared.loadContainer(configuration: configuration)
    }

    public func loadVLM(configuration: ModelConfiguration) async throws -> ModelContainer {
        try await VLMModelFactory.shared.loadContainer(configuration: configuration)
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
public actor MLXModelCoordinator: MLXModelCoordinating {
    public nonisolated static let shared = MLXModelCoordinator()

    struct CacheKey: Equatable, Sendable {
        let identifier: ModelConfiguration.Identifier
        let kind: MLXModelKind
    }

    let loader: MLXModelLoading
    var cachedKey: CacheKey?
    var cachedContainer: ModelContainer?
    var pendingTask: Task<ModelContainer, Error>?

    public init(loader: MLXModelLoading = DefaultMLXModelLoader()) {
        self.loader = loader
    }

    public func container(
        for configuration: ModelConfiguration,
        kind: MLXModelKind,
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
                try await loader.loadLLM(configuration: configuration)
            case .vlm:
                try await loader.loadVLM(configuration: configuration)
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
