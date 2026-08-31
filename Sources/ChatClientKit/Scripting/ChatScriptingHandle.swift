//
//  ChatScriptingHandle.swift
//  ChatClientKit
//
//  Connector struct passed by the FlowDown app to a ChatService.streamingChat
//  call when the model has scripting configured. ChatClientKit does NOT
//  depend on Storage; the app builds the handle from CloudModel + Conversation
//  via the ChatScriptingAdapter in the app target.
//

import Foundation

public struct ChatScriptingHandle: @unchecked Sendable {
    /// Stable identifier for the conversation the script runs in.
    public let conversationId: String

    /// Decoded plist-config from `CloudModel.ext_data[chat_client_kit_scripts]`.
    public let config: ChatClientKitScriptConfig

    /// Manifest snapshot — adapter constructs this via a whitelist
    /// (sensitive fields like token are NOT included).
    public let manifest: ManifestSnapshot

    /// Read the current per-conversation context blob.
    /// Adapter's typical implementation:
    ///   `sdb.conversationWith(identifier: id)?.ext_data[ExtensionKey.chatClientKit] ?? ""`
    public let readContext: @Sendable () -> String

    /// Synchronous write of the context blob.
    /// **Caller invariant**: must not be invoked while holding any WCDB
    /// transaction in the streamingChat caller chain — risk of lock
    /// inversion. See plan §8.4.
    public let writeContext: @Sendable (String) throws -> Void

    public init(
        conversationId: String,
        config: ChatClientKitScriptConfig,
        manifest: ManifestSnapshot,
        readContext: @escaping @Sendable () -> String,
        writeContext: @escaping @Sendable (String) throws -> Void
    ) {
        self.conversationId = conversationId
        self.config = config
        self.manifest = manifest
        self.readContext = readContext
        self.writeContext = writeContext
    }
}
