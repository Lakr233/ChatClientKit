//
//  ChatClientKitScriptConfig.swift
//  ChatClientKit
//
//  Strong-typed view of the plist-encoded blob stored at
//  `CloudModel.ext_data["chat_client_kit_scripts"]`.
//
//  Top-level shape:
//      <dict>
//        <key>pre_process</key>
//        <dict>
//          <key>inherit</key> <true/>
//          <key>script</key>  <string>/* js */</string>
//        </dict>
//        <key>post_process</key>
//        <dict>
//          <key>inherit</key> <false/>
//          <key>script</key>  <string>/* js */</string>
//        </dict>
//      </dict>
//

import Foundation

public struct ChatClientKitScriptConfig: Codable, Sendable, Equatable {
    public struct Stage: Codable, Sendable, Equatable {
        public var inherit: Bool
        public var script: String

        public init(inherit: Bool, script: String) {
            self.inherit = inherit
            self.script = script
        }
    }

    public var preProcess: Stage?
    public var postProcess: Stage?

    public init(preProcess: Stage? = nil, postProcess: Stage? = nil) {
        self.preProcess = preProcess
        self.postProcess = postProcess
    }

    enum CodingKeys: String, CodingKey {
        case preProcess = "pre_process"
        case postProcess = "post_process"
    }
}

public extension ChatClientKitScriptConfig {
    /// Decode from the plist string typically stored in
    /// `CloudModel.ext_data[ExtensionKey.chatClientKitScripts]`.
    ///
    /// Returns `nil` if the string is empty or malformed — caller should
    /// treat that as "scripting disabled".
    static func decodePList(_ string: String) -> Self? {
        guard !string.isEmpty,
              let data = string.data(using: .utf8)
        else { return nil }
        return try? PropertyListDecoder().decode(Self.self, from: data)
    }

    /// Whether any stage is configured. Convenience for the call site.
    var hasAnyStage: Bool {
        preProcess != nil || postProcess != nil
    }
}
