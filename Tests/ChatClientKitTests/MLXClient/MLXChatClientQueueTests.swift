//
//  MLXChatClientQueueTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/11/11.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("MLX Chat Client Queue")
struct MLXChatClientQueueTests {
    private actor AcquisitionTracker {
        private var didAcquire = false

        func markAcquired() {
            didAcquire = true
        }

        func value() -> Bool {
            didAcquire
        }
    }

    private actor TimingTracker {
        private var attemptTimes: [String: Date] = [:]
        private var firstChunkTimes: [String: Date] = [:]
        private var completionTimes: [String: Date] = [:]

        func recordAttempt(_ label: String, at date: Date = Date()) {
            if attemptTimes[label] == nil {
                attemptTimes[label] = date
            }
        }

        func recordFirstChunkIfNeeded(_ label: String, at date: Date = Date()) {
            if firstChunkTimes[label] == nil {
                firstChunkTimes[label] = date
            }
        }

        func recordCompletion(_ label: String, at date: Date = Date()) {
            completionTimes[label] = date
        }

        func attemptTime(for label: String) -> Date? {
            attemptTimes[label]
        }

        func firstChunkTime(for label: String) -> Date? {
            firstChunkTimes[label]
        }

        func completionTime(for label: String) -> Date? {
            completionTimes[label]
        }
    }

    @Test("Queue blocks concurrent acquisitions until release")
    func queue_blocksConcurrentAcquisitions() async throws {
        let queue = MLXChatClientQueue.shared
        let tracker = AcquisitionTracker()

        let firstToken = queue.acquire()
        var firstTokenReleased = false
        defer {
            if !firstTokenReleased {
                queue.release(token: firstToken)
            }
        }

        let secondTask = Task.detached(priority: .utility) {
            let token = queue.acquire()
            await tracker.markAcquired()
            try? await Task.sleep(nanoseconds: 50_000_000)
            queue.release(token: token)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let acquiredBeforeRelease = await tracker.value()
        #expect(acquiredBeforeRelease == false)

        queue.release(token: firstToken)
        firstTokenReleased = true

        await secondTask.value

        let acquiredAfterRelease = await tracker.value()
        #expect(acquiredAfterRelease == true)
    }

    @Test("Queue allows only a single MLX inference at a time", .enabled(if: TestHelpers.checkGPU()))
    func queue_allowsSingleInferenceAtATimeWithMLX() async throws {
        guard TestHelpers.checkGPU() else { return }

        let modelURL = TestHelpers.fixtureURLOrSkip(named: "mlx_testing_model")
        let client = MLXChatClient(url: modelURL, preferredKind: .llm, coordinator: MLXModelCoordinator())
        let tracker = TimingTracker()

        var secondTask: Task<Int, Error>?
        let firstChunks = try await runStreamingInference(
            label: "first",
            prompt: "Respond with the word FIRST and nothing else.",
            client: client,
            tracker: tracker
        ) {
            secondTask = Task(priority: .userInitiated) {
                try await runStreamingInference(
                    label: "second",
                    prompt: "Respond with the word SECOND and nothing else.",
                    client: client,
                    tracker: tracker
                )
            }
        }

        let launchedSecondTask = try #require(secondTask)
        let secondChunks = try await launchedSecondTask.value

        #expect(firstChunks > 0)
        #expect(secondChunks > 0)

        let firstCompletion = try #require(await tracker.completionTime(for: "first"))
        let secondAttempt = try #require(await tracker.attemptTime(for: "second"))
        let secondFirstChunk = try #require(await tracker.firstChunkTime(for: "second"))

        #expect(secondAttempt <= firstCompletion)
        let tolerance: TimeInterval = 0.05
        #expect(secondFirstChunk.timeIntervalSince(firstCompletion) >= -tolerance)
    }

    private func runStreamingInference(
        label: String,
        prompt: String,
        client: MLXChatClient,
        tracker: TimingTracker,
        onFirstChunk: (() -> Void)? = nil
    ) async throws -> Int {
        await tracker.recordAttempt(label)
        let request = makeStreamingRequest(prompt: prompt)
        let stream = try await client.streamingChatCompletionRequest(body: request)

        var chunkEvents = 0
        var recordedFirstChunk = false

        for try await event in stream {
            switch event {
            case .chatCompletionChunk:
                chunkEvents += 1
                if !recordedFirstChunk {
                    await tracker.recordFirstChunkIfNeeded(label)
                    recordedFirstChunk = true
                    onFirstChunk?()
                }
            case .tool:
                continue
            }
        }

        await tracker.recordCompletion(label)
        return chunkEvents
    }

    private func makeStreamingRequest(prompt: String) -> ChatRequestBody {
        ChatRequestBody(
            messages: [
                .system(content: .text("You are a concise testing assistant.")),
                .user(content: .text(prompt)),
            ],
            maxCompletionTokens: 64,
            stream: true,
            temperature: 0.0
        )
    }
}
