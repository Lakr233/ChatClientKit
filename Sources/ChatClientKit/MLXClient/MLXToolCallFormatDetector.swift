import Foundation
internal import MLXLMCommon

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
enum MLXToolCallFormatDetector {
    static func detect(in modelDirectory: URL) -> ToolCallFormat? {
        let templateURL = modelDirectory.appendingPathComponent("chat_template.jinja")
        guard let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return nil
        }

        if template.contains("<start_function_call>") {
            return .gemma
        }
        if template.contains("[TOOL_CALLS]") && template.contains("[ARGS]") {
            return .mistral
        }
        if template.contains("<function=") && template.contains("<parameter=") {
            return .xmlFunction
        }
        if template.contains("<|tool_call_start|>") {
            return .lfm2
        }
        if template.contains("<tool_call>") {
            return .json
        }
        return nil
    }
}
