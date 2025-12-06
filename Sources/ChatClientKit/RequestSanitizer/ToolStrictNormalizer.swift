//
//  ToolStrictNormalizer.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

enum ToolStrictNormalizer {
    static func normalize(_ tools: [ChatRequestBody.Tool]?) -> [ChatRequestBody.Tool]? {
        guard let tools, !tools.isEmpty else { return tools }

        let hasStrictTool = tools.contains { tool in
            if case let .function(_, _, _, strict) = tool {
                strict == true
            } else {
                false
            }
        }

        guard hasStrictTool else { return tools }

        return tools.map { tool in
            switch tool {
            case let .function(name, description, parameters, _):
                .function(name: name, description: description, parameters: parameters, strict: true)
            }
        }
    }
}

