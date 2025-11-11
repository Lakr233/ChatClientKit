//
//  RemoteChatRequestBuilder.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

struct RemoteChatRequestBuilder {
    let baseURL: String?
    let path: String?
    let apiKey: String?
    var additionalHeaders: [String: String]

    private let encoder: JSONEncoder

    init(
        baseURL: String?,
        path: String?,
        apiKey: String?,
        additionalHeaders: [String: String],
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.baseURL = baseURL
        self.path = path
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
        self.encoder = encoder
    }

    func makeRequest(
        body: ChatRequestBody,
        additionalField: [String: Any]
    ) throws -> URLRequest {
        guard let baseURL else {
            logger.errorFile("invalid base URL")
            throw RemoteChatClient.Error.invalidURL
        }

        guard let apiKey else {
            logger.errorFile("invalid API key")
            throw RemoteChatClient.Error.invalidApiKey
        }

        var normalizedPath = path ?? ""
        if !normalizedPath.isEmpty, !normalizedPath.starts(with: "/") {
            normalizedPath = "/\(normalizedPath)"
        }

        guard var baseComponents = URLComponents(string: baseURL),
              let pathComponents = URLComponents(string: normalizedPath)
        else {
            logger.errorFile(
                "failed to parse URL components from baseURL: \(baseURL), path: \(normalizedPath)"
            )
            throw RemoteChatClient.Error.invalidURL
        }

        baseComponents.path += pathComponents.path
        baseComponents.queryItems = pathComponents.queryItems

        guard let url = baseComponents.url else {
            logger.errorFile("failed to construct final URL from components")
            throw RemoteChatClient.Error.invalidURL
        }

        logger.debugFile("constructed request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if !additionalField.isEmpty {
            var originalDictionary: [String: Any] = [:]
            if let body = request.httpBody,
               let dictionary = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                originalDictionary = dictionary
            }
            for (key, value) in additionalField {
                originalDictionary[key] = value
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: originalDictionary, options: [])
        }

        return request
    }
}
