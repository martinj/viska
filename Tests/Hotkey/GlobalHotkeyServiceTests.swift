import AppKit
import Carbon.HIToolbox
import XCTest
@testable import VoiceCompanion

@MainActor
final class GlobalHotkeyServiceTests: XCTestCase {
    func testHoldModeEmitsPressedAndReleasedEvents() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        try service.configure(
            descriptor: HotkeyDescriptor(keyCode: 49, modifiers: HotkeyDescriptor.requiredModifierFlags),
            mode: .holdToRecord
        )

        service.handle(rawEvent: .pressed)
        service.handle(rawEvent: .released)

        await waitForEventCount(2) { events.count }
        XCTAssertEqual(events, [.pressed, .released])
    }

    func testToggleModeEmitsOnlyToggleEvents() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        try service.configure(
            descriptor: HotkeyDescriptor(keyCode: 49, modifiers: HotkeyDescriptor.requiredModifierFlags),
            mode: .toggleToRecord
        )

        service.handle(rawEvent: .pressed)
        service.handle(rawEvent: .released)
        service.handle(rawEvent: .pressed)

        await waitForEventCount(2) { events.count }
        XCTAssertEqual(events, [.toggle, .toggle])
    }

    func testEscapePressEmitsCancelEvent() async {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        service.handleEscapePressed()

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.cancel])
    }

    func testLocalEscapeMonitorHandlerCancelsAndSuppressesEscapeEvent() async {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        let handler = service.makeLocalEscapeMonitorHandler()
        let event = makeKeyEvent(keyCode: UInt16(kVK_Escape), characters: "\u{1B}")

        let result = handler(event)

        XCTAssertNil(result)
        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.cancel])
    }

    func testLocalEscapeMonitorHandlerPassesThroughNonEscapeEvent() {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)

        let handler = service.makeLocalEscapeMonitorHandler()
        let event = makeKeyEvent(keyCode: UInt16(kVK_Space), characters: " ")

        let result = handler(event)

        XCTAssertTrue(result === event)
    }

    func testDescriptorWithoutRequiredModifierIsRejected() {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)

        XCTAssertThrowsError(
            try service.configure(
                descriptor: HotkeyDescriptor(keyCode: 49, modifiers: 0),
                mode: .holdToRecord
            )
        )
    }

    func testRegistrationConflictIsReportedCleanly() {
        let registrar = FakeGlobalHotkeyRegistrar()
        registrar.error = .conflict
        let service = GlobalHotkeyService(registrar: registrar)

        XCTAssertThrowsError(
            try service.configure(
                descriptor: HotkeyDescriptor(keyCode: 49, modifiers: HotkeyDescriptor.requiredModifierFlags),
                mode: .holdToRecord
            )
        ) { error in
            XCTAssertEqual(error as? GlobalHotkeyService.Error, .registrationConflict)
        }
    }

    private func waitForEventCount(
        _ expectedCount: Int,
        currentCount: () -> Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if currentCount() == expectedCount {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for \(expectedCount) hotkey events", file: file, line: line)
    }

    private func makeKeyEvent(keyCode: UInt16, characters: String) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            XCTFail("Failed to construct key event for test")
            fatalError("Failed to construct key event for test")
        }

        return event
    }
}

private final class FakeGlobalHotkeyRegistrar: GlobalHotkeyRegistering {
    var error: GlobalHotkeyRegistrarError?

    func register(
        descriptor: HotkeyDescriptor,
        handler: @escaping (GlobalHotkeyService.RawEvent) -> Void
    ) throws -> any GlobalHotkeyRegistration {
        if let error {
            throw error
        }

        return FakeGlobalHotkeyRegistration()
    }
}

private struct FakeGlobalHotkeyRegistration: GlobalHotkeyRegistration {
    func invalidate() {}
}
