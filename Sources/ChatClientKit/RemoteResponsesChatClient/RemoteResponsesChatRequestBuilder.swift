//
//  RemoteResponsesChatRequestBuilder.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation

struct RemoteResponsesRequestBuilder {
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
        encoder: JSONEncoder = JSONEncoder(),
    ) {
        self.baseURL = baseURL
        self.path = path
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
        self.encoder = encoder
    }

    func makeRequest(
        body: ResponsesRequestBody,
        additionalField: [String: Any],
    ) throws -> URLRequest {
        guard let baseURL else {
            logger.error("invalid base URL for responses client")
            throw RemoteResponsesChatClient.Error.invalidURL
        }

        var normalizedPath = path ?? ""
        if !normalizedPath.isEmpty, !normalizedPath.starts(with: "/") {
            normalizedPath = "/\(normalizedPath)"
        }

        guard var baseComponents = URLComponents(string: baseURL),
              let pathComponents = URLComponents(string: normalizedPath)
        else {
            logger.error("failed to parse URL components from baseURL: \(baseURL), path: \(normalizedPath)")
            throw RemoteResponsesChatClient.Error.invalidURL
        }

        baseComponents.path += pathComponents.path
        baseComponents.queryItems = pathComponents.queryItems

        guard let url = baseComponents.url else {
            logger.error("failed to construct final URL from components for responses client")
            throw RemoteResponsesChatClient.Error.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedApiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedApiKey, !trimmedApiKey.isEmpty {
            request.setValue("Bearer \(trimmedApiKey)", forHTTPHeaderField: "Authorization")
        }

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

        logger.debug("constructed responses request URL: \(url.absoluteString)")
        return request
    }
}
