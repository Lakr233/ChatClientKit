#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

XCFRAMEWORK_PATH=${1:-BinaryTarget/ChatClientKit.xcframework}
if [ ! -d "$XCFRAMEWORK_PATH" ]; then
    echo "[!] xcframework not found: $XCFRAMEWORK_PATH. Run ./Script/build.sh first." >&2
    exit 1
fi

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify --disable-colored-output --disable-logging
    else
        cat
    fi
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Consumer/BinaryTarget" \
    "$WORK_DIR/Consumer/Sources/Consumer" \
    "$WORK_DIR/Consumer/Tests/ConsumerTests"
ditto "$XCFRAMEWORK_PATH" "$WORK_DIR/Consumer/BinaryTarget/ChatClientKit.xcframework"

cat >"$WORK_DIR/Consumer/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "Consumer", targets: ["Consumer"]),
    ],
    targets: [
        .binaryTarget(
            name: "ChatClientKit",
            path: "BinaryTarget/ChatClientKit.xcframework"
        ),
        .target(
            name: "Consumer",
            dependencies: ["ChatClientKit"]
        ),
        .testTarget(
            name: "ConsumerTests",
            dependencies: ["Consumer", "ChatClientKit"]
        ),
    ]
)
EOF

cat >"$WORK_DIR/Consumer/Sources/Consumer/Consumer.swift" <<'EOF'
import ChatClientKit
import Foundation

public func makeSmokeRequest() throws -> ChatRequestBody {
    try ChatRequest {
        ChatRequest.model("smoke-model")
        ChatRequest.messages {
            ChatRequest.Message.system(content: .text("You are helpful."))
            ChatRequest.Message.user(content: .text("Hello"))
        }
    }.asChatRequestBody()
}

public func makeRemoteClient() -> RemoteCompletionsChatClient {
    RemoteCompletionsChatClient(
        model: "smoke-model",
        baseURL: "https://example.com",
        path: "/v1/chat/completions",
        apiKey: "test-key"
    )
}

public func makeResponsesClient() -> RemoteResponsesChatClient {
    RemoteResponsesChatClient(
        model: "smoke-model",
        baseURL: "https://example.com",
        path: "/v1/responses",
        apiKey: "test-key"
    )
}

public func makeMLXClient() -> MLXChatClient {
    MLXChatClient(url: URL(fileURLWithPath: "/tmp/model"), preferredKind: .llm)
}

public func makePromptPreview(_ messages: [ChatRequestBody.Message]) -> String {
    AppleIntelligencePromptBuilder.makePrompt(from: messages)
}
EOF

cat >"$WORK_DIR/Consumer/Tests/ConsumerTests/ConsumerTests.swift" <<'EOF'
import ChatClientKit
import Consumer
import Foundation
import Metal
import Testing

struct ConsumerTests {
    @Test
    func `Consumer links and exercises ChatClientKit binary API`() async throws {
        let body = try makeSmokeRequest()
        #expect(body.model == "smoke-model")
        #expect(body.messages.count == 2)

        let remote = makeRemoteClient()
        let responses = makeResponsesClient()
        let mlx = makeMLXClient()
        #expect(remote.model == "smoke-model")
        #expect(responses.model == "smoke-model")
        #expect(await mlx.errorCollector.getError() == nil)
        #expect(makePromptPreview(body.messages) == "Hello")

        let sse = try #require(ServerSentEvent.parse(from: Data("data: ping\n".utf8)))
        #expect(sse.data == "ping")

        await MLXModelCoordinator.shared.reset()
        #if !targetEnvironment(simulator) && !arch(x86_64)
            if MTLCreateSystemDefaultDevice() != nil {
                MLXModelCoordinator.clearMemoryCache()
            }
        #endif
    }
}
EOF

SLICES=$(python3 - "$XCFRAMEWORK_PATH/Info.plist" <<'PY'
import plistlib, sys
info = plistlib.load(open(sys.argv[1], "rb"))
for lib in info.get("AvailableLibraries", []):
    p = lib.get("SupportedPlatform")
    v = lib.get("SupportedPlatformVariant")
    if p == "macos" and v is None:
        print("macos")
    elif p == "ios" and v is None:
        print("ios")
    elif p == "ios" and v == "simulator":
        print("iossimulator")
    elif p == "ios" and v == "maccatalyst":
        print("maccatalyst")
PY
)

test_build() {
    local destination="$1"
    echo "[*] consumer build destination=$destination"
    if ! xcodebuild \
        -scheme Consumer \
        -destination "$destination" \
        -derivedDataPath "$WORK_DIR/DerivedData" \
        -packageCachePath "$WORK_DIR/PackageCache" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        build 2>&1 | format_output; then
        echo "[!] Consumer build failed for $destination." >&2
        exit 1
    fi
}

test_run() {
    local destination="$1"
    echo "[*] consumer test destination=$destination"
    if ! xcodebuild \
        -scheme Consumer \
        -destination "$destination" \
        -derivedDataPath "$WORK_DIR/DerivedData" \
        -packageCachePath "$WORK_DIR/PackageCache" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        test 2>&1 | format_output; then
        echo "[!] Consumer runtime tests failed for $destination." >&2
        exit 1
    fi
}

(
    cd "$WORK_DIR/Consumer"
    for slice in $SLICES; do
        case "$slice" in
            macos)
                test_build "generic/platform=macOS"
                test_run "platform=macOS"
                ;;
            ios)
                test_build "generic/platform=iOS"
                ;;
            iossimulator)
                test_build "generic/platform=iOS Simulator"
                ;;
            maccatalyst)
                test_build "generic/platform=macOS,variant=Mac Catalyst"
                test_run "platform=macOS,variant=Mac Catalyst"
                ;;
        esac
    done
)

echo "[*] xcframework consumer tests passed"
