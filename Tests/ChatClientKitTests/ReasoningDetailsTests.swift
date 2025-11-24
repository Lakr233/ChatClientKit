//
//  ReasoningDetailsTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/11/11.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("Reasoning Details Parsing")
struct ReasoningDetailsTests {
    @Test("Decodes reasoning_details from chunks and exposes assistant turn")
    func decodingReasoningDetailsFromChunk() throws {
        let json = """
        {
          "id":"gen-123",
          "object":"chat.completion.chunk",
          "model":"google/gemini-3-pro-preview",
          "created":1763947025,
          "choices":[
            {
              "index":0,
              "delta":{
                "role":"assistant",
                "content":"",
                "reasoning":"partial",
                "reasoning_details":[{"type":"reasoning.text","text":"partial","format":"google-gemini-v1","index":0}]
              },
              "finish_reason":null
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)

        let delta = try #require(chunk.choices.first?.delta)
        #expect(delta.reasoning == "partial")
        let details = try #require(delta.reasoningDetails)
        #expect(details.count == 1)
        #expect(details.first?.text == "partial")

        let turn = delta.assistantTurn
        #expect(turn.reasoningDetails.count == 1)
        #expect(turn.reasoning == "partial")
        #expect(turn.toolCalls.isEmpty)
    }

    @Test("Adjacent assistant messages are merged before serialization")
    func mergesAdjacentAssistantMessages() throws {
        let request = ChatRequest {
            ChatRequest.messages {
                ChatRequest.Message.assistant(content: .text("first"), reasoning: "r1", reasoningDetails: [
                    ReasoningDetail(type: "reasoning.text", text: "a", index: 0),
                ])
                ChatRequest.Message.assistant(content: .text("second"), reasoningDetails: [
                    ReasoningDetail(type: "reasoning.text", text: "b", index: 0),
                ])
                ChatRequest.Message.user(content: .text("break"))
            }
        }

        let body = try request.asChatRequestBody()
        #expect(body.messages.count == 2)
        guard case let .assistant(content, _, _, _, reasoning, details) = body.messages.first else {
            Issue.record("Expected assistant message at index 0")
            return
        }
        if case let .text(text) = content {
            #expect(text.contains("first"))
            #expect(text.contains("second"))
        } else {
            Issue.record("Merged content should remain text")
        }
        #expect(reasoning == "r1")
        let mergedDetails = try #require(details)
        #expect(mergedDetails.count == 1)
        #expect(mergedDetails.first?.text == "ab" || mergedDetails.first?.text == "ba")
    }
}
