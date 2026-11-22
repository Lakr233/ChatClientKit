@testable import ChatClientKit
import Foundation
import Testing

#if compiler(>=6.4)
    import FoundationModels

    struct PrivateCloudComputeMappingTests {
        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `Availability maps every known reason`() {
            #expect(PrivateCloudComputeModel.availabilityState(from: .available) == .available)
            #expect(
                PrivateCloudComputeModel.availabilityState(from: .unavailable(.deviceNotEligible))
                    == .unavailable(.deviceNotEligible)
            )
            #expect(
                PrivateCloudComputeModel.availabilityState(from: .unavailable(.systemNotReady))
                    == .unavailable(.systemNotReady)
            )
        }

        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `Network, quota and service errors map to app failures`() {
            let network = PrivateCloudComputeLanguageModel.Error.networkFailure(
                .init(debugDescription: "offline")
            )
            #expect(PrivateCloudComputeModel.failure(from: network) == .networkFailure)

            let reset = Date(timeIntervalSince1970: 1_800_000_000)
            let quota = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
                .init(resetDate: reset, debugDescription: "limit")
            )
            #expect(
                PrivateCloudComputeModel.failure(from: quota)
                    == .quotaLimitReached(resetDate: reset)
            )

            let quotaWithoutDate = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
                .init(debugDescription: "limit")
            )
            #expect(
                PrivateCloudComputeModel.failure(from: quotaWithoutDate)
                    == .quotaLimitReached(resetDate: nil)
            )

            let busy = PrivateCloudComputeLanguageModel.Error.serviceUnavailable(
                .init(debugDescription: "busy")
            )
            #expect(PrivateCloudComputeModel.failure(from: busy) == .serviceUnavailable)
        }

        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `Unavailable error keeps its reason and other errors map to nil`() {
            let unavailable = PrivateCloudComputeUnavailableError(reason: .systemNotReady)
            #expect(PrivateCloudComputeModel.failure(from: unavailable) == .unavailable(.systemNotReady))
            #expect(PrivateCloudComputeModel.failure(from: CancellationError()) == nil)
            #expect(PrivateCloudComputeModel.failure(from: URLError(.notConnectedToInternet)) == nil)
        }

        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `A failure inside a tool call is unwrapped`() throws {
            let tool = try AppleIntelligenceToolProxy(name: "noop", description: nil, parameters: nil)
            let wrapped = LanguageModelSession.ToolCallError(
                tool: tool,
                underlyingError: PrivateCloudComputeLanguageModel.Error.networkFailure(
                    .init(debugDescription: "offline")
                )
            )
            #expect(PrivateCloudComputeModel.failure(from: wrapped) == .networkFailure)
        }

        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `Reasoning depth maps onto context reasoning levels`() {
            #expect(PrivateCloudComputeChatClient.reasoningLevel(for: .light) == .light)
            #expect(PrivateCloudComputeChatClient.reasoningLevel(for: .moderate) == .moderate)
            #expect(PrivateCloudComputeChatClient.reasoningLevel(for: .deep) == .deep)
            #expect(PrivateCloudComputeChatClient.reasoningLevel(for: nil) == nil)
        }

        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `Reasoning text joins text segments and skips signature-only entries`() {
            let entries: [Transcript.Entry] = [
                .reasoning(Transcript.Reasoning(segments: [], signature: Data([1, 2, 3]))),
                .reasoning(Transcript.Reasoning(segments: [
                    .text(Transcript.TextSegment(content: "First, ")),
                    .text(Transcript.TextSegment(content: "check the date.")),
                ])),
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "ignored"))])),
            ]
            #expect(PrivateCloudComputeChatClient.reasoningText(in: entries) == "First, check the date.")
            #expect(PrivateCloudComputeChatClient.reasoningText(in: [Transcript.Entry]()) == "")
        }

        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `Session context sends history as transcript and applies reasoning depth`() throws {
            let client = PrivateCloudComputeChatClient(configuration: .init(reasoningDepth: .deep))
            let body = ChatRequestBody(messages: [
                .system(content: .text("Be brief.")),
                .user(content: .text("First question")),
                .assistant(content: .text("First answer")),
                .user(content: .text("Second question")),
            ])

            let context = try client.makeSessionContext(body: body)
            #expect(context.prompt == "Second question")
            #expect(Array(context.session.transcript).count == 3)
            #expect(context.contextOptions.reasoningLevel == .deep)
            #expect(context.options.temperature == nil)
            #expect(context.historyEntries == 2)
            #expect(context.tools == 0)
            #expect(context.instructionsLength == "Be brief.".count)
        }

        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `A snapshot that rewrites earlier text is reported, growth is not`() {
            var state = AppleIntelligenceStreamState()
            _ = state.delta(for: "Hello")

            var events: [PrivateCloudComputeStreamEvent] = []
            PrivateCloudComputeChatClient.reportRewrite(of: .content, from: state, to: "Hello there") {
                events.append($0)
            }
            #expect(events.isEmpty)

            PrivateCloudComputeChatClient.reportRewrite(of: .content, from: state, to: "Hi") {
                events.append($0)
            }
            #expect(events.count == 1)
            if case let .snapshotRewritten(field, previousLength, newLength) = events.first {
                #expect(field == .content)
                #expect(previousLength == 5)
                #expect(newLength == 2)
            } else {
                Issue.record("expected a rewrite event")
            }
        }
    }
#endif

struct PrivateCloudComputeIdentityTests {
    @Test
    func `Model identifier is distinct from the on-device model`() {
        #expect(PrivateCloudComputeIdentity.modelIdentifier == "apple.intelligence.cloud")
        #expect(PrivateCloudComputeIdentity.modelIdentifier != "apple.intelligence.ondevice")
    }

    @Test
    func `Supported OS needs the SDK and iOS or macOS 27`() {
        if PrivateCloudComputeIdentity.isSupportedOperatingSystem {
            #expect(PrivateCloudComputeIdentity.isCompiledIn)
        }
        #if compiler(>=6.4)
            if #available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *) {
                #expect(PrivateCloudComputeIdentity.isSupportedOperatingSystem)
            }
        #endif
    }

    @Test
    func `Availability state reports available only for available`() {
        #expect(PrivateCloudComputeAvailabilityState.available.isAvailable)
        #expect(!PrivateCloudComputeAvailabilityState.unavailable(.deviceNotEligible).isAvailable)
        #expect(!PrivateCloudComputeAvailabilityState.unavailable(.operatingSystemTooOld).isAvailable)
    }
}
