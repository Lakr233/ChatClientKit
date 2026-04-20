//
//  RemoteCompletionsChatRequestBuilder.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

struct RemoteCompletionsChatRequestBuilder {
    let baseURL: String?
    let path: String?
    let apiKey: String?
    var additionalHeaders: [String: String]
    let customization: FlowDownChatClientKitCustomization

    let encoder: JSONEncoder

    init(
        baseURL: String?,
        path: String?,
        apiKey: String?,
        additionalHeaders: [String: String],
        customization: FlowDownChatClientKitCustomization,
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.baseURL = baseURL
        self.path = path
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
        self.customization = customization
        self.encoder = encoder
    }

    func makeRequest(
        body: ChatRequestBody,
        additionalField: [String: Any]
    ) throws -> URLRequest {
        guard let baseURL else {
            logger.error("invalid base URL")
            throw RemoteCompletionsChatClient.Error.invalidURL
        }

        var normalizedPath = path ?? ""
        if !normalizedPath.isEmpty, !normalizedPath.starts(with: "/") {
            normalizedPath = "/\(normalizedPath)"
        }

        guard var baseComponents = URLComponents(string: baseURL),
              let pathComponents = URLComponents(string: normalizedPath)
        else {
            logger.error(
                "failed to parse URL components from baseURL: \(baseURL), path: \(normalizedPath)"
            )
            throw RemoteCompletionsChatClient.Error.invalidURL
        }

        baseComponents.path += pathComponents.path
        baseComponents.queryItems = pathComponents.queryItems

        guard let url = baseComponents.url else {
            logger.error("failed to construct final URL from components")
            throw RemoteCompletionsChatClient.Error.invalidURL
        }

        logger.debug("constructed request URL: \(url.absoluteString)")

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

        var originalDictionary: [String: Any] = [:]
        if let body = request.httpBody,
           let dictionary = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        {
            originalDictionary = dictionary
        }
        for (key, value) in customization.forwardedBodyFields {
            originalDictionary[key] = value
        }
        for (key, value) in additionalField where key != FlowDownChatClientKitExtension.configurationKey {
            originalDictionary[key] = value
        }

        var mutableRequest = request
        try FlowDownChatClientKitModifierRuntime(environments: customization.environments)
            .applyRequestModifiers(
                customization.requestModifiers,
                to: &mutableRequest,
                body: &originalDictionary
            )
        request = mutableRequest
        request.httpBody = try JSONSerialization.data(withJSONObject: originalDictionary, options: [])

        return request
    }
}
