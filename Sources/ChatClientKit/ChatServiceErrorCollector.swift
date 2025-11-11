//
//  ChatServiceErrorCollector.swift
//  ChatClientKit
//
//  Created by AI Assistant on 2025/11/11.
//

import Foundation

/// Thread-safe error collector for chat services.
public actor ChatServiceErrorCollector {
    private var error: String?

    public init() {}

    public func collect(_ error: String?) {
        self.error = error
    }

    public func getError() -> String? {
        error
    }

    public func clear() {
        error = nil
    }
}
