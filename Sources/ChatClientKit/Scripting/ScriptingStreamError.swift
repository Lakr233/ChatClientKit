//
//  ScriptingStreamError.swift
//  ChatClientKit
//
//  Errors surfaced by stream processors when the post_process JS
//  hook fails repeatedly. Collected into the client's `errorCollector`
//  so consumers see a clear failure even though `AsyncStream` itself
//  cannot throw.
//

import Foundation

public enum ScriptingStreamError: Error, LocalizedError {
    /// post_process script threw / failed to decode `count` times in a row;
    /// stream was terminated to avoid presenting partial output as success.
    case consecutivePostProcessFailures(count: Int, last: Error)

    public var errorDescription: String? {
        switch self {
        case let .consecutivePostProcessFailures(count, last):
            "post_process script failed \(count) consecutive times; last error: \(last.localizedDescription)"
        }
    }
}
