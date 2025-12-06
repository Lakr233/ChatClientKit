//
//  CompletionImage.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/06.
//

import Foundation

// data transfer object
public struct CompletionImage: Sendable, Decodable, Equatable {
    public struct ImageURL: Sendable, Decodable, Equatable {
        public let url: String
    }

    public let type: String
    public let imageURL: ImageURL

    enum CodingKeys: String, CodingKey {
        case type
        case imageURL = "image_url"
    }
}
