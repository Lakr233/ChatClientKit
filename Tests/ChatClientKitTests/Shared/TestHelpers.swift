//
//  TestHelpers.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import CoreFoundation
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
@preconcurrency import MLX
import Testing

/// Helper functions for tests
enum TestHelpers {
    // MARK: - Test Conditions (for use with @Test(.enabled(if:)))

    /// Check if API key is configured (for use with @Test(.enabled(if:)))
    static var isOpenRouterAPIKeyConfigured: Bool {
        loadAPIKey(named: "OPENROUTER_API_KEY") != nil
    }

    /// Check if MLX model fixture is available (for use with @Test(.enabled(if:)))
    static var isMLXModelAvailable: Bool {
        guard !MLX.GPU.deviceInfo().architecture.isEmpty else {
            return false
        }
        return fixtureURL(named: "mlx_testing_model") != nil
    }

    /// Check if Apple Intelligence is available (for use with @Test(.enabled(if:)))
    static var isAppleIntelligenceAvailable: Bool {
        if #available(iOS 26, macOS 26, macCatalyst 26, *) {
            AppleIntelligenceModel.shared.isAvailable
        } else {
            false
        }
    }

    // MARK: - Test Helpers

    /// Gets API key from environment variable; records an issue and returns a placeholder if missing.
    static func requireAPIKey(_ name: String = "OPENROUTER_API_KEY") -> String {
        guard let value = loadAPIKey(named: name) else {
            return "sk-is-missing"
        }
        return value
    }

    /// Creates a RemoteChatClient configured for OpenRouter with google/gemini-2.5-pro
    /// Precondition: API key must be configured (check with isOpenRouterAPIKeyConfigured before using)
    static func makeOpenRouterClient() -> RemoteChatClient {
        let apiKey = requireAPIKey()
        return RemoteChatClient(
            model: "google/gemini-2.5-pro",
            baseURL: "https://openrouter.ai/api",
            path: "/v1/chat/completions",
            apiKey: apiKey,
            additionalHeaders: [
                "HTTP-Referer": "https://github.com/FlowDown/ChatClientKit",
                "X-Title": "ChatClientKit Tests",
            ]
        )
    }

    /// Resolves a fixture URL relative to the repository root.
    /// Precondition: Fixture must exist (check with appropriate condition before using)
    static func fixtureURLOrSkip(named name: String, file: StaticString = #filePath) -> URL {
        guard let url = fixtureURL(named: name, file: file) else {
            fatalError("Fixture \(name) not found. Expected at ~/.testing/\(name) or <repo>/.test/\(name).")
        }
        return url
    }

    private static func loadAPIKey(named name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return value
        }
        #if os(macOS)
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".testing")
                .appendingPathComponent("openrouter.sk")
        #else
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent(".testing")
                .appendingPathComponent("openrouter.sk")
        #endif
        let content = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else {
            return nil
        }
        return content
    }

    /// Creates a simple test image as base64 data URL using Core Graphics
    static func createTestImageDataURL(width: Int = 100, height: Int = 100) -> URL {
        let size = CGSize(width: width, height: height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to create CGContext")
        }

        // Draw a red rectangle
        context.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        context.fill(CGRect(origin: .zero, size: size))

        guard let cgImage = context.makeImage() else {
            fatalError("Failed to create CGImage")
        }

        // Convert to PNG data
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.png" as CFString, 1, nil) else {
            fatalError("Failed to create image destination")
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Failed to finalize image destination")
        }

        let pngData = mutableData as Data
        let base64String = pngData.base64EncodedString()
        let dataURLString = "data:image/png;base64,\(base64String)"
        return URL(string: dataURLString)!
    }

    /// Creates a simple test audio as base64 data
    static func createTestAudioBase64(format _: String = "wav") -> String {
        // Create a minimal WAV file header (44 bytes) + some silence
        var wavData = Data()

        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(36).littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // channels
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) }) // sample rate
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) }) // byte rate
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) }) // block align
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // bits per sample

        // data chunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) })

        return wavData.base64EncodedString()
    }

    /// Resolves a fixture URL relative to the repository root.
    static func fixtureURL(named name: String, file: StaticString = #filePath) -> URL? {
        #if os(macOS)
            let homeFixture = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".testing")
                .appendingPathComponent(name, isDirectory: true)
        #else
            let homeFixture = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent(".testing")
                .appendingPathComponent(name, isDirectory: true)
        #endif

        if FileManager.default.fileExists(atPath: homeFixture.path) {
            return homeFixture
        }

        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0 ..< 5 {
            url.deleteLastPathComponent()
        }
        let repoFixture = url
            .appendingPathComponent(".test")
            .appendingPathComponent(name, isDirectory: true)

        if FileManager.default.fileExists(atPath: repoFixture.path) {
            return repoFixture
        }

        Issue.record("Fixture \(name) is missing. Checked \(homeFixture.path) and \(repoFixture.path)")
        return nil
    }

    static func checkGPU() -> Bool {
        guard !MLX.GPU.deviceInfo().architecture.isEmpty else {
            return false
        }
        return true
    }
}
