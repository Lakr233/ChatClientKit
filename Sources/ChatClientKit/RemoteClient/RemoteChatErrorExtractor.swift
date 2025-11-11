//
//  RemoteChatErrorExtractor.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

struct RemoteChatErrorExtractor {
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
            var errorMessage = "Server returns an error: \(status) \(domain)"
            var bfs: [Any] = [dictionary]
            while !bfs.isEmpty {
                let current = bfs.removeFirst()
                if let currentDictionary = current as? [String: Any] {
                    if let message = currentDictionary["message"] as? String {
                        errorMessage = message
                        break
                    }
                    for (_, value) in currentDictionary {
                        bfs.append(value)
                    }
                }
            }
            return NSError(
                domain: domain,
                code: status,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
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
                        localized: "Server returns an error: \(code) \(message)"
                    ),
                ]
            )
        }

        return nil
    }
}
