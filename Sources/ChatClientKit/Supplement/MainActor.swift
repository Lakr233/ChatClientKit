//
//  MainActor.swift
//  ChatClientKit
//
//  Created by qaq on 7/12/2025.
//

import Foundation

extension MainActor {
    static func isolated<T: Sendable>(_ body: @MainActor @Sendable () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            try MainActor.assumeIsolated {
                try body()
            }
        } else {
            try DispatchQueue.main.sync {
                try body()
            }
        }
    }
}
