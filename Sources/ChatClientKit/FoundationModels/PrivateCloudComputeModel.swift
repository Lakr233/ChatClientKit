#if compiler(>=6.4)
    import Foundation
    import FoundationModels

    /// Wraps `PrivateCloudComputeLanguageModel` and maps its state onto the
    /// FoundationModels-free types in `PrivateCloudComputeState.swift`.
    @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
    public final class PrivateCloudComputeModel: Sendable {
        public static let shared = PrivateCloudComputeModel()

        public let languageModel: PrivateCloudComputeLanguageModel

        init(languageModel: PrivateCloudComputeLanguageModel = .init()) {
            self.languageModel = languageModel
        }

        public var availabilityState: PrivateCloudComputeAvailabilityState {
            Self.availabilityState(from: languageModel.availability)
        }

        /// Reads the quota only when the model is available; otherwise the
        /// framework's healthy default would hide the real problem.
        public var quotaState: PrivateCloudComputeQuotaState {
            guard availabilityState.isAvailable else { return .belowLimit }
            let usage = languageModel.quotaUsage
            return Self.quotaState(
                status: usage.status,
                resetDate: usage.resetDate,
                canIncreaseLimit: usage.limitIncreaseSuggestion != nil
            )
        }

        /// Presents the system's iCloud+ sheet. Returns false when the system
        /// offers no way to raise the limit.
        @discardableResult
        public func showLimitIncreaseSuggestion() -> Bool {
            guard let suggestion = languageModel.quotaUsage.limitIncreaseSuggestion else {
                return false
            }
            suggestion.show()
            return true
        }

        public var modelIdentifier: String {
            PrivateCloudComputeIdentity.modelIdentifier
        }

        public var canonicalName: String {
            PrivateCloudComputeIdentity.canonicalName
        }
    }

    @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
    public extension PrivateCloudComputeModel {
        static func availabilityState(
            from availability: PrivateCloudComputeLanguageModel.Availability
        ) -> PrivateCloudComputeAvailabilityState {
            switch availability {
            case .available:
                return .available
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(.deviceNotEligible)
                case .systemNotReady:
                    return .unavailable(.systemNotReady)
                @unknown default:
                    return .unavailable(.other(String(describing: reason)))
                }
            }
        }

        static func quotaState(
            status: PrivateCloudComputeLanguageModel.QuotaUsage.Status,
            resetDate: Date?,
            canIncreaseLimit: Bool
        ) -> PrivateCloudComputeQuotaState {
            switch status {
            case let .belowLimit(info):
                return info.isApproachingLimit ? .approachingLimit : .belowLimit
            case .limitReached:
                return .limitReached(resetDate: resetDate, canIncreaseLimit: canIncreaseLimit)
            @unknown default:
                return .belowLimit
            }
        }

        /// Maps a thrown error onto the failures the app explains in its own
        /// words, or nil for anything else.
        static func failure(from error: any Error) -> PrivateCloudComputeFailure? {
            if let error = error as? PrivateCloudComputeUnavailableError {
                return .unavailable(error.reason)
            }
            if let error = error as? PrivateCloudComputeLanguageModel.Error {
                switch error {
                case .networkFailure:
                    return .networkFailure
                case let .quotaLimitReached(info):
                    return .quotaLimitReached(
                        resetDate: info.resetDate,
                        canIncreaseLimit: info.limitIncreaseSuggestion != nil
                    )
                case .serviceUnavailable:
                    return .serviceUnavailable
                @unknown default:
                    return nil
                }
            }
            if let error = error as? LanguageModelSession.ToolCallError {
                return failure(from: error.underlyingError)
            }
            return nil
        }
    }
#endif
