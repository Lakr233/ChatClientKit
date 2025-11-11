import Foundation

public enum AppleIntelligenceAvailabilityState: Sendable, Equatable {
    case available
    case unavailable(String)
}

import FoundationModels

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
public final class AppleIntelligenceModel: Sendable {
    public static let shared = AppleIntelligenceModel()

    public static let frameworkUnavailableReason = "frameworkUnavailable"

    private init() {}

    public var availabilityState: AppleIntelligenceAvailabilityState {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return .available
        case let .unavailable(reason):
            return .unavailable(String(describing: reason))
        @unknown default:
            return .unavailable(String(describing: availability))
        }
    }

    public var isAvailable: Bool {
        if case .available = availabilityState {
            return true
        }
        return false
    }

    public var modelIdentifier: String {
        "apple.intelligence.ondevice"
    }

    public var canonicalName: String {
        "Apple Intelligence"
    }
}
