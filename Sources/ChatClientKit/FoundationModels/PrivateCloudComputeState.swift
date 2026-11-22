import Foundation

/// App-facing view of Apple's Private Cloud Compute model, free of
/// FoundationModels types so it exists on every OS and SDK and can be tested
/// and rendered without the iOS 27 framework.
public enum PrivateCloudComputeIdentity {
    /// Stored as a conversation's model identifier, like
    /// `AppleIntelligenceModel.modelIdentifier` for the on-device model.
    public static let modelIdentifier = "apple.intelligence.cloud"
    public static let canonicalName = "Apple Intelligence Cloud"
    /// A safe budget for the request builder. The real window is read with
    /// `try await PrivateCloudComputeLanguageModel().contextSize`; Apple
    /// documents it as 32K.
    public static let contextLength = 32000

    /// Whether this build was compiled against an SDK that has the model.
    public static var isCompiledIn: Bool {
        #if compiler(>=6.4)
            true
        #else
            false
        #endif
    }

    /// Whether this build and the running OS can use the model at all. The
    /// device and system may still report it unavailable.
    public static var isSupportedOperatingSystem: Bool {
        #if compiler(>=6.4)
            if #available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *) {
                return true
            }
        #endif
        return false
    }
}

public enum PrivateCloudComputeUnavailableReason: Sendable, Equatable {
    /// The OS (or the SDK the app was built with) predates iOS / macOS 27.
    case operatingSystemTooOld
    /// The device can't use Apple Intelligence.
    case deviceNotEligible
    /// The system isn't ready yet, for example Apple Intelligence is off or
    /// still setting up.
    case systemNotReady
    /// A reason added after this code was written; the payload describes it.
    case other(String)
}

public enum PrivateCloudComputeAvailabilityState: Sendable, Equatable {
    case available
    case unavailable(PrivateCloudComputeUnavailableReason)

    public var isAvailable: Bool {
        self == .available
    }
}

/// The failures the cloud model reports beyond ordinary generation errors.
public enum PrivateCloudComputeFailure: Sendable, Equatable {
    case networkFailure
    /// The daily limit is used up; `resetDate` is when it resets, if known.
    case quotaLimitReached(resetDate: Date?)
    case serviceUnavailable
    /// Thrown before any request when the model is unavailable.
    case unavailable(PrivateCloudComputeUnavailableReason)
}

/// How hard the cloud model thinks before answering
/// (`ContextOptions.ReasoningLevel`).
public enum PrivateCloudComputeReasoningDepth: String, CaseIterable, Sendable {
    case light
    case moderate
    case deep
}

/// Thrown by `PrivateCloudComputeChatClient` when the model can't run, so the
/// app can show the reason instead of a generic error.
public struct PrivateCloudComputeUnavailableError: LocalizedError, Sendable, Equatable {
    public let reason: PrivateCloudComputeUnavailableReason

    public init(reason: PrivateCloudComputeUnavailableReason) {
        self.reason = reason
    }

    public var errorDescription: String? {
        "Apple Intelligence Cloud is unavailable: \(reason)"
    }
}

/// What `PrivateCloudComputeChatClient` did with one request, for the app's
/// own log. Lengths count characters and are cumulative for the request.
public enum PrivateCloudComputeStreamEvent: Sendable {
    /// The session is built; nothing has been sent yet.
    case sessionCreated(
        historyEntries: Int,
        tools: Int,
        instructionsLength: Int,
        promptLength: Int,
        reasoningDepth: PrivateCloudComputeReasoningDepth?
    )
    /// `streamResponse` was called and the client is waiting for snapshots.
    case requestSent
    /// A snapshot arrived. `index` starts at 1.
    case snapshot(index: Int, contentLength: Int, reasoningLength: Int, transcriptEntries: Int)
    /// A snapshot's text didn't extend the previous one, so the changed part
    /// could not be forwarded as a delta.
    case snapshotRewritten(field: Field, previousLength: Int, newLength: Int)
    /// The model called a tool; the call goes back to the app.
    case toolCallCaptured(name: String)
    /// The stream ended normally.
    case finished(snapshots: Int, contentLength: Int, reasoningLength: Int)
    /// The consumer stopped the stream.
    case cancelled(snapshots: Int)
    /// The framework threw; the same error ends the stream.
    case failed(snapshots: Int, error: any Error)

    public enum Field: String, Sendable {
        case content
        case reasoning
    }
}
