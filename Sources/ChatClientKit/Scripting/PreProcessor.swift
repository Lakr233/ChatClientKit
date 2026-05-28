//
//  PreProcessor.swift
//  ChatClientKit
//
//  Wraps a ScriptRunner.invoke for the `pre_process` stage. Called once
//  per request, right before URLSession.dataTask. The result rewrites
//  the request headers (in script-provided order) and HTTP body.
//

import Foundation

struct PreProcessor {
    let runner: ScriptRunner
    let stage: ChatClientKitScriptConfig.Stage

    /// Run pre_process on a constructed URLRequest.
    ///
    /// - inherit=true: feeds JS the current headers + body (from
    ///   our normal build flow). JS may tweak / re-sign / re-order.
    /// - inherit=false: feeds JS empty headers + empty body. JS
    ///   constructs everything from `chatSession` / `manifest`.
    ///
    /// Returns a mutated URLRequest: headers are wiped and re-set in
    /// JS-provided order, body becomes the JSON-encoded
    /// PreProcessOutput.body.
    func apply(to request: URLRequest) throws -> URLRequest {
        var mutated = request

        let inputHeaders: ScriptHeaderList
        let inputBody: AnyCodingValue
        if stage.inherit {
            inputHeaders = ScriptHeaderList(
                entries: orderedHeaderEntries(from: mutated)
            )
            inputBody = decodeBody(mutated.httpBody)
        } else {
            inputHeaders = ScriptHeaderList(entries: [])
            inputBody = .object([:])
        }

        let bindings: [String: Any] = [
            "headers": try toJSAny(inputHeaders),
            "body": try toJSAny(inputBody),
        ]
        let out: PreProcessOutput = try runner.invoke(
            script: stage.script,
            bindings: bindings
        )

        // Wipe and re-set headers in JS-given order.
        mutated.allHTTPHeaderFields = nil
        for entry in out.headers.entries {
            mutated.setValue(entry.value, forHTTPHeaderField: entry.name)
        }

        // Replace body with JS output.
        let bodyData = try JSONEncoder().encode(out.body)
        mutated.httpBody = bodyData

        return mutated
    }

    private func orderedHeaderEntries(from request: URLRequest) -> [ScriptHeaderList.Entry] {
        // URLRequest.allHTTPHeaderFields is a Dictionary — we can't
        // guarantee on-the-wire order (see plan §1.6). Sort by name
        // to at least give scripts a deterministic input order.
        let raw = request.allHTTPHeaderFields ?? [:]
        return raw.keys.sorted().map { key in
            ScriptHeaderList.Entry(name: key, value: raw[key] ?? "")
        }
    }

    private func decodeBody(_ data: Data?) -> AnyCodingValue {
        guard let data, !data.isEmpty else { return .object([:]) }
        return (try? JSONDecoder().decode(AnyCodingValue.self, from: data)) ?? .object([:])
    }

    private func toJSAny<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
