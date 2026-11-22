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
                    return .quotaLimitReached(resetDate: info.resetDate)
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
