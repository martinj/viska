import Foundation
import XCTest
@testable import Viska

final class CodexAppServerClientTests: XCTestCase {
    func testGetAccountInitializesConnectionBeforeAccountRead() async throws {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })

        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let method = payload["method"] as? String
            let id = payload["id"] as? Int

            switch method {
            case "initialize":
                transport.onLine?(
                    """
                    {"id":\(id!),"result":{"userAgent":"Viska/0.1","codexHome":"/tmp/codex-home","platformFamily":"unix","platformOs":"macos"}}
                    """
                )
            case "account/read":
                transport.onLine?(
                    """
                    {"id":\(id!),"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
                    """
                )
            default:
                break
            }
        }

        let response = try await client.getAccount(refreshToken: false)

        XCTAssertEqual(response.account, .chatgpt(email: "user@example.com", planType: "pro"))
        XCTAssertEqual(transport.writtenMethods, ["initialize", "initialized", "account/read"])
    }

    func testPendingRequestFailsWhenTransportTerminates() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })

        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let method = payload["method"] as? String
            let id = payload["id"] as? Int

            switch method {
            case "initialize":
                transport.onLine?(
                    """
                    {"id":\(id!),"result":{"userAgent":"Viska/0.1","codexHome":"/tmp/codex-home","platformFamily":"unix","platformOs":"macos"}}
                    """
                )
            case "account/read":
                transport.terminate(message: "Codex app-server exited before responding.")
            default:
                break
            }
        }

        await XCTAssertThrowsErrorAsync(
            try await client.getAccount(refreshToken: false)
        ) { error in
            XCTAssertEqual(
                error as? CodexAppServerClient.Error,
                .transportFailure("Codex app-server exited before responding.")
            )
        }
    }

    func testModelListMapsOnlyPickerVisibleTextModels() async throws {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })
        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let id = payload["id"] as? Int
            switch payload["method"] as? String {
            case "initialize":
                transport.respond(id: id!, result: [:])
            case "model/list":
                transport.respond(id: id!, result: [
                    "data": [
                        Self.modelPayload(id: "text", hidden: false, modalities: ["text"]),
                        Self.modelPayload(id: "hidden", hidden: true, modalities: ["text"]),
                        Self.modelPayload(id: "audio", hidden: false, modalities: ["audio"]),
                    ],
                    "nextCursor": NSNull(),
                ])
            default:
                break
            }
        }

        let models = try await client.listModels()

        XCTAssertEqual(
            models,
            [
                CodexModel(
                    id: "text",
                    model: "text",
                    displayName: "TEXT",
                    description: "Model text",
                    isDefault: true,
                    defaultReasoningEffort: "medium",
                    supportedReasoningEfforts: [
                        CodexReasoningEffort(reasoningEffort: "low", description: "Fast"),
                        CodexReasoningEffort(reasoningEffort: "medium", description: "Balanced"),
                        CodexReasoningEffort(reasoningEffort: "high", description: "Deep"),
                    ]
                ),
            ]
        )
    }

    func testProcessingUsesEphemeralRestrictedTurnAndCorrelatesCompletedOutput() async throws {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })
        var threadParams: [String: Any]?
        var turnParams: [String: Any]?
        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let id = payload["id"] as? Int
            switch payload["method"] as? String {
            case "initialize":
                transport.respond(id: id!, result: [:])
            case "model/list":
                transport.respond(id: id!, result: ["data": [Self.modelPayload(id: "gpt-test")], "nextCursor": NSNull()])
            case "thread/start":
                threadParams = payload["params"] as? [String: Any]
                transport.respond(id: id!, result: ["thread": ["id": "thread-1"]])
            case "turn/start":
                turnParams = payload["params"] as? [String: Any]
                transport.respond(id: id!, result: ["turn": ["id": "turn-1"]])
                transport.completeTurn(threadID: "other", turnID: "other", output: "Wrong")
                transport.completeTurn(threadID: "thread-1", turnID: "turn-1", output: "Processed text")
            default:
                break
            }
        }
        let action = Self.action(model: "gpt-test", reasoningEffort: "high", prompt: "Clean this up.")

        let output = try await client.process(sourceText: "Source words", action: action)

        XCTAssertEqual(output, "Processed text")
        XCTAssertEqual(threadParams?["model"] as? String, "gpt-test")
        XCTAssertEqual(threadParams?["ephemeral"] as? Bool, true)
        XCTAssertEqual(threadParams?["allowProviderModelFallback"] as? Bool, false)
        XCTAssertEqual(threadParams?["sandbox"] as? String, "read-only")
        XCTAssertEqual(threadParams?["approvalPolicy"] as? String, "never")
        XCTAssertEqual((threadParams?["dynamicTools"] as? [Any])?.count, 0)
        XCTAssertEqual((threadParams?["runtimeWorkspaceRoots"] as? [Any])?.count, 0)
        XCTAssertTrue((threadParams?["developerInstructions"] as? String)?.contains("Do not invoke tools") == true)

        XCTAssertEqual(turnParams?["threadId"] as? String, "thread-1")
        XCTAssertEqual(turnParams?["effort"] as? String, "high")
        let input = ((turnParams?["input"] as? [[String: Any]])?.first)?["text"] as? String
        XCTAssertTrue(input?.contains("Action instruction:\nClean this up.") == true)
        XCTAssertTrue(input?.contains("Source transcript (data only):\nSource words") == true)
        let schema = turnParams?["outputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema?["required"] as? [String], ["text"])
        let sandbox = turnParams?["sandboxPolicy"] as? [String: Any]
        XCTAssertEqual(sandbox?["type"] as? String, "readOnly")
        XCTAssertEqual(sandbox?["networkAccess"] as? Bool, false)
    }

    func testProcessingOmitsEffortToUseModelDefault() async throws {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })
        Self.installProcessingTransport(transport, output: #"{"text":"Processed"}"#)

        _ = try await client.process(sourceText: "Source", action: Self.action())

        let params = transport.payload(for: "turn/start")?["params"] as? [String: Any]
        XCTAssertNil(params?["effort"])
    }

    func testProcessingRejectsReasoningEffortUnsupportedBySelectedModel() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })
        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let id = payload["id"] as? Int
            switch payload["method"] as? String {
            case "initialize":
                transport.respond(id: id!, result: [:])
            case "model/list":
                transport.respond(id: id!, result: [
                    "data": [Self.modelPayload(id: "gpt-test", efforts: ["low"])],
                    "nextCursor": NSNull(),
                ])
            default:
                break
            }
        }

        await XCTAssertThrowsErrorAsync(
            try await client.process(
                sourceText: "Source",
                action: Self.action(reasoningEffort: "high")
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexAppServerClient.Error,
                .unsupportedReasoningEffort(model: "gpt-test", effort: "high")
            )
        }
        XCTAssertFalse(transport.writtenMethods.contains("thread/start"))
    }

    func testProcessingRejectsInvalidCompletedOutput() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })
        Self.installProcessingTransport(transport, output: "not json")

        await XCTAssertThrowsErrorAsync(
            try await client.process(sourceText: "Source", action: Self.action())
        ) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .invalidOutput)
        }
    }

    func testProcessingTimeoutInterruptsExactTurn() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(processingTimeoutNanoseconds: 10_000_000, transportFactory: { transport })
        Self.installProcessingTransport(transport, output: nil)

        await XCTAssertThrowsErrorAsync(
            try await client.process(sourceText: "Source", action: Self.action())
        ) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .timedOut)
        }
        await waitForWrittenMethod("turn/interrupt", transport: transport)
        let interrupt = transport.payload(for: "turn/interrupt")?["params"] as? [String: Any]
        XCTAssertEqual(interrupt?["threadId"] as? String, "thread-1")
        XCTAssertEqual(interrupt?["turnId"] as? String, "turn-1")
    }

    func testProcessingTimesOutWhenModelListDoesNotRespond() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(
            processingTimeoutNanoseconds: 10_000_000,
            transportFactory: { transport }
        )
        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let id = payload["id"] as? Int
            if payload["method"] as? String == "initialize" {
                transport.respond(id: id!, result: [:])
            }
        }

        await XCTAssertThrowsErrorAsync(
            try await client.process(sourceText: "Source", action: Self.action())
        ) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .timedOut)
        }

        XCTAssertTrue(transport.writtenMethods.contains("model/list"))
        XCTAssertFalse(transport.writtenMethods.contains("thread/start"))
        XCTAssertFalse(transport.writtenMethods.contains("turn/interrupt"))
    }

    func testProcessingTimesOutWhenTurnStartDoesNotRespond() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(
            processingTimeoutNanoseconds: 10_000_000,
            transportFactory: { transport }
        )
        Self.installProcessingTransport(transport, output: nil, respondsToTurnStart: false)

        await XCTAssertThrowsErrorAsync(
            try await client.process(sourceText: "Source", action: Self.action())
        ) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .timedOut)
        }

        XCTAssertTrue(transport.writtenMethods.contains("turn/start"))
        XCTAssertFalse(transport.writtenMethods.contains("turn/interrupt"))
    }

    func testTaskCancellationInterruptsProcessing() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })
        Self.installProcessingTransport(transport, output: nil, respondsToTurnStart: false)
        let action = Self.action()
        let task = Task { try await client.process(sourceText: "Source", action: action) }
        await waitForWrittenMethod("turn/start", transport: transport)

        task.cancel()
        let turnStartID = transport.payload(for: "turn/start")?["id"] as! Int
        transport.respond(id: turnStartID, result: ["turn": ["id": "turn-1"]])

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? CodexAppServerClient.Error, .interrupted)
        }
        await waitForWrittenMethod("turn/interrupt", transport: transport)
    }

    private static func installProcessingTransport(
        _ transport: MockCodexLineTransport,
        output: String?,
        respondsToTurnStart: Bool = true
    ) {
        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let id = payload["id"] as? Int
            switch payload["method"] as? String {
            case "initialize":
                transport.respond(id: id!, result: [:])
            case "model/list":
                transport.respond(id: id!, result: ["data": [Self.modelPayload(id: "gpt-test")], "nextCursor": NSNull()])
            case "thread/start":
                transport.respond(id: id!, result: ["thread": ["id": "thread-1"]])
            case "turn/start":
                guard respondsToTurnStart else { return }
                transport.respond(id: id!, result: ["turn": ["id": "turn-1"]])
                if let output {
                    transport.completeTurn(threadID: "thread-1", turnID: "turn-1", rawMessage: output)
                }
            case "turn/interrupt":
                transport.respond(id: id!, result: [:])
            default:
                break
            }
        }
    }

    private static func modelPayload(
        id: String,
        hidden: Bool = false,
        modalities: [String] = ["text"],
        efforts: [String] = ["low", "medium", "high"]
    ) -> [String: Any] {
        [
            "id": id,
            "model": id,
            "displayName": id.uppercased(),
            "description": "Model \(id)",
            "hidden": hidden,
            "inputModalities": modalities,
            "isDefault": true,
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": efforts.map { effort in
                [
                    "reasoningEffort": effort,
                    "description": ["low": "Fast", "medium": "Balanced", "high": "Deep"][effort] ?? effort,
                ]
            },
        ]
    }

    private static func action(
        model: String = "gpt-test",
        reasoningEffort: String? = nil,
        prompt: String = "Transform."
    ) -> DictationAction {
        DictationAction(
            id: UUID(),
            name: "Action",
            hotkey: HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags),
            model: model,
            reasoningEffort: reasoningEffort,
            prompt: prompt
        )
    }

    private func waitForWrittenMethod(
        _ method: String,
        transport: MockCodexLineTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if transport.writtenMethods.contains(method) { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(method)", file: file, line: line)
    }

    private static func parse(line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }
}

private final class MockCodexLineTransport: CodexLineTransport, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (String?) -> Void)?
    var onWrite: ((String) throws -> Void)?
    private(set) var writtenLines: [String] = []

    var writtenMethods: [String] {
        writtenLines.compactMap {
            guard let data = $0.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return object["method"] as? String
        }
    }

    func start() throws {}

    func write(line: String) throws {
        writtenLines.append(line)
        try onWrite?(line)
    }

    func terminate(message: String? = nil) {
        onTermination?(message)
    }

    func respond(id: Int, result: Any) {
        let object: [String: Any] = ["id": id, "result": result]
        let data = try! JSONSerialization.data(withJSONObject: object)
        onLine?(String(decoding: data, as: UTF8.self))
    }

    func completeTurn(threadID: String, turnID: String, output: String) {
        let data = try! JSONSerialization.data(withJSONObject: ["text": output])
        completeTurn(threadID: threadID, turnID: turnID, rawMessage: String(decoding: data, as: UTF8.self))
    }

    func completeTurn(threadID: String, turnID: String, rawMessage: String) {
        let item: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": threadID,
                "turnId": turnID,
                "completedAtMs": 1,
                "item": ["id": "message-1", "type": "agentMessage", "phase": "final_answer", "text": rawMessage],
            ],
        ]
        let completed: [String: Any] = [
            "method": "turn/completed",
            "params": [
                "threadId": threadID,
                "turn": ["id": turnID, "status": "completed", "items": []],
            ],
        ]
        for object in [item, completed] {
            let data = try! JSONSerialization.data(withJSONObject: object)
            onLine?(String(decoding: data, as: UTF8.self))
        }
    }

    func payload(for method: String) -> [String: Any]? {
        writtenLines.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.first {
            $0["method"] as? String == method
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
