//
//  RequestSanitizing.swift
//  ChatClientKit
//
//  Created by qaq on 6/12/2025.
//

import Foundation

public protocol RequestSanitizing: Sendable {
    func sanitize(_ body: ChatRequestBody) -> ChatRequestBody
}
