//
//  RemoteCompletionsChatErrorExtractor.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

struct RemoteCompletionsChatErrorExtractor {
    private let unknownErrorMessage: String

    init(unknownErrorMessage: String = String(localized: "Unknown Error")) {
        self.unknownErrorMessage = unknownErrorMessage
    }

    func extractError(from input: Data) -> Swift.Error? {
        guard let dictionary = try? JSONSerialization.jsonObject(with: input, options: []) as? [String: Any] else {
            return nil
        }

        if let status = dictionary["status"] as? Int, (400 ... 599).contains(status) {
            let domain = dictionary["error"] as? String ?? unknownErrorMessage
            let errorMessage = extractMessage(in: dictionary) ?? "Server returns an error: \(status) \(domain)"
            return NSError(
                domain: domain,
                code: status,
                userInfo: [NSLocalizedDescriptionKey: errorMessage],
            )
        }

        if let status = dictionary["status"] as? String {
            let normalizedStatus = status.lowercased()
            let successStatus: Set<String> = ["succeeded", "completed", "success", "incomplete", "in_progress", "queued"]
            if !successStatus.contains(normalizedStatus) {
                let message = extractMessage(in: dictionary) ?? "Server returns an error status: \(status)"
                return NSError(
                    domain: String(localized: "Server Error"),
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }

        if let errorContent = dictionary["error"] as? [String: Any], !errorContent.isEmpty {
            var message = errorContent["message"] as? String ?? unknownErrorMessage
            let code = errorContent["code"] as? Int ?? 403
            if let metadata = errorContent["metadata"] as? [String: Any],
               let metadataMessage = metadata["message"] as? String
            {
                message += " \(metadataMessage)"
            }
            return NSError(
                domain: String(localized: "Server Error"),
                code: code,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Server returns an error: \(code) \(message)",
                    ),
                ],
            )
        }

        return nil
    }

    private func extractMessage(in dictionary: [String: Any]) -> String? {
        var queue: [Any] = [dictionary]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let dict = current as? [String: Any] {
                if let message = dict["message"] as? String {
                    return message
                }
                for (_, value) in dict {
                    queue.append(value)
                }
            }
        }
        return nil
    }
}
