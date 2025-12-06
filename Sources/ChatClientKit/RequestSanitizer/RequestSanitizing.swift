//
//  RequestSanitizing.swift
//  ChatClientKit
//
//  Created by qaq on 6/12/2025.
//

import Foundation

protocol RequestSanitizing: Sendable {
    func sanitize(_ body: ChatRequestBody) -> ChatRequestBody
}
