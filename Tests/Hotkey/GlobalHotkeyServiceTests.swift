import XCTest
@testable import VoiceCompanion

@MainActor
final class GlobalHotkeyServiceTests: XCTestCase {
    func testHoldModeEmitsPressedAndReleasedEvents() throws {
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

        XCTAssertEqual(events, [.pressed, .released])
    }

    func testToggleModeEmitsOnlyToggleEvents() throws {
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

        XCTAssertEqual(events, [.toggle, .toggle])
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
