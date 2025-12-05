//
//  RemoteResponsesToolCallCollector.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation

final class ResponsesToolCallCollector {
    struct Pending {
        var id: String
        var name: String
        var arguments: String
    }

    private var storage: [String: Pending] = [:]
    private var order: [String] = []

    func observe(item: ResponsesOutputItem) {
        guard item.type == "function_call" else { return }
        let identifier = item.callId ?? item.id ?? UUID().uuidString
        var pending = storage[identifier] ?? Pending(id: identifier, name: "", arguments: "")
        if let name = item.name {
            pending.name = name
        }
        if let arguments = item.arguments {
            pending.arguments = arguments
        }
        storage[identifier] = pending
        if !order.contains(identifier) {
            order.append(identifier)
        }
    }

    func appendDelta(
        for itemID: String?,
        name: String?,
        delta: String?,
        outputIndex: Int?
    ) {
        guard let itemID else { return }
        var pending = storage[itemID] ?? Pending(id: itemID, name: name ?? "", arguments: "")
        if let name, pending.name.isEmpty {
            pending.name = name
        }
        if let delta {
            pending.arguments.append(delta)
        }
        storage[itemID] = pending
        if !order.contains(itemID) {
            order.append(itemID)
        }
    }

    func finalize(
        for itemID: String?,
        name: String?,
        arguments: String?,
        outputIndex: Int?
    ) {
        guard let itemID else { return }
        var pending = storage[itemID] ?? Pending(id: itemID, name: name ?? "", arguments: "")
        if let name {
            pending.name = name
        }
        if let arguments {
            pending.arguments = arguments
        }
        storage[itemID] = pending
        if !order.contains(itemID) {
            order.append(itemID)
        }
    }

    func finalizeRequests() -> [ToolCallRequest] {
        order.map { id in
            let pending = storage[id] ?? Pending(id: id, name: "", arguments: "")
            return ToolCallRequest(id: pending.id, name: pending.name, args: pending.arguments)
        }
    }

    var hasPendingRequests: Bool {
        !storage.isEmpty
    }
}
