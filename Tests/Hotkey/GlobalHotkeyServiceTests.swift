import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Viska

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

    func testPlainAndActionShortcutsEmitTheirOwnRoutes() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let action = makeAction(keyCode: 2)
        let actionHotkey = try XCTUnwrap(action.hotkey)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        try service.configure(
            registrations: [
                DictationHotkeyRegistration(descriptor: plain, route: .plain),
                DictationHotkeyRegistration(descriptor: actionHotkey, route: .action(action)),
            ],
            mode: .holdToRecord
        )
        registrar.send(.pressed, for: plain)
        registrar.send(.released, for: plain)
        registrar.send(.pressed, for: actionHotkey)
        registrar.send(.released, for: actionHotkey)

        await waitForEventCount(4) { events.count }
        XCTAssertEqual(events, [
            .pressed(route: .plain),
            .released(route: .plain),
            .pressed(route: .action(action)),
            .released(route: .action(action)),
        ])
    }

    func testToggleModeAppliesToEveryRoute() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let action = makeAction(keyCode: 2)
        let actionHotkey = try XCTUnwrap(action.hotkey)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        try service.configure(
            registrations: [DictationHotkeyRegistration(descriptor: actionHotkey, route: .action(action))],
            mode: .toggleToRecord
        )
        registrar.send(.pressed, for: actionHotkey)
        registrar.send(.released, for: actionHotkey)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.toggle(route: .action(action))])
    }

    func testDuplicateShortcutsAreRejectedBeforeRegistration() {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let descriptor = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)

        XCTAssertThrowsError(
            try service.configure(
                registrations: [
                    DictationHotkeyRegistration(descriptor: descriptor, route: .plain),
                    DictationHotkeyRegistration(descriptor: descriptor, route: .action(makeAction(keyCode: 1))),
                ],
                mode: .holdToRecord
            )
        )
        XCTAssertEqual(registrar.registeredDescriptors, [])
    }

    func testFailedReconfigurationPreservesPreviousRegistrations() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let conflicting = HotkeyDescriptor(keyCode: 2, modifiers: HotkeyDescriptor.requiredModifierFlags)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.configure(
            registrations: [DictationHotkeyRegistration(descriptor: plain, route: .plain)],
            mode: .holdToRecord
        )
        registrar.failingDescriptors = [conflicting]

        XCTAssertThrowsError(
            try service.configure(
                registrations: [
                    DictationHotkeyRegistration(descriptor: plain, route: .plain),
                    DictationHotkeyRegistration(descriptor: conflicting, route: .action(makeAction(keyCode: 2))),
                ],
                mode: .toggleToRecord
            )
        )
        registrar.send(.pressed, for: plain)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.pressed(route: .plain)])
        XCTAssertFalse(try XCTUnwrap(registrar.registrations[plain]).isInvalidated)
    }

    func testRemovingActionUnregistersOnlyItsShortcut() throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let action = makeAction(keyCode: 2)
        let actionHotkey = try XCTUnwrap(action.hotkey)
        try service.configure(
            registrations: [
                DictationHotkeyRegistration(descriptor: plain, route: .plain),
                DictationHotkeyRegistration(descriptor: actionHotkey, route: .action(action)),
            ],
            mode: .holdToRecord
        )
        let plainRegistration = try XCTUnwrap(registrar.registrations[plain])
        let actionRegistration = try XCTUnwrap(registrar.registrations[actionHotkey])

        try service.configure(
            registrations: [DictationHotkeyRegistration(descriptor: plain, route: .plain)],
            mode: .holdToRecord
        )

        XCTAssertFalse(plainRegistration.isInvalidated)
        XCTAssertTrue(actionRegistration.isInvalidated)
    }

    private func makeAction(keyCode: UInt32) -> DictationAction {
        DictationAction(
            id: UUID(),
            name: "Action",
            hotkey: HotkeyDescriptor(keyCode: keyCode, modifiers: HotkeyDescriptor.requiredModifierFlags),
            model: "gpt-5.6-luna",
            prompt: "Transform."
        )
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
    var failingDescriptors: Set<HotkeyDescriptor> = []
    private(set) var handlers: [HotkeyDescriptor: (GlobalHotkeyService.RawEvent) -> Void] = [:]
    private(set) var registrations: [HotkeyDescriptor: FakeGlobalHotkeyRegistration] = [:]

    var registeredDescriptors: [HotkeyDescriptor] { Array(registrations.keys) }

    func register(
        descriptor: HotkeyDescriptor,
        handler: @escaping (GlobalHotkeyService.RawEvent) -> Void
    ) throws -> any GlobalHotkeyRegistration {
        if failingDescriptors.contains(descriptor) {
            throw GlobalHotkeyRegistrarError.conflict
        }
        if let error {
            throw error
        }
        let registration = FakeGlobalHotkeyRegistration()
        handlers[descriptor] = handler
        registrations[descriptor] = registration
        return registration
    }

    func send(_ event: GlobalHotkeyService.RawEvent, for descriptor: HotkeyDescriptor) {
        guard registrations[descriptor]?.isInvalidated == false else { return }
        handlers[descriptor]?(event)
    }
}

private final class FakeGlobalHotkeyRegistration: GlobalHotkeyRegistration {
    private(set) var isInvalidated = false
    func invalidate() { isInvalidated = true }
}
