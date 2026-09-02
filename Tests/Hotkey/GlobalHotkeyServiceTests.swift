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
        XCTAssertEqual(events, [.pressed(route: .plain), .released(route: .plain)])
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
        XCTAssertEqual(events, [.toggle(route: .plain), .toggle(route: .plain)])
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

    func testPlainPickerAndActionShortcutsEmitTheirOwnRoutes() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let picker = HotkeyDescriptor(keyCode: 3, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let action = makeAction(keyCode: 2)
        let actionHotkey = try XCTUnwrap(action.hotkey)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        try service.configure(
            registrations: [
                DictationHotkeyRegistration(descriptor: plain, route: .plain),
                DictationHotkeyRegistration(descriptor: picker, route: .picker),
                DictationHotkeyRegistration(descriptor: actionHotkey, route: .action(action)),
            ],
            mode: .holdToRecord
        )
        registrar.send(.pressed, for: plain)
        registrar.send(.released, for: plain)
        registrar.send(.pressed, for: picker)
        registrar.send(.released, for: picker)
        registrar.send(.pressed, for: actionHotkey)
        registrar.send(.released, for: actionHotkey)

        await waitForEventCount(6) { events.count }
        XCTAssertEqual(events, [
            .pressed(route: .plain),
            .released(route: .plain),
            .pressed(route: .picker),
            .released(route: .picker),
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

    func testPickerChoiceSessionSuspendsPersistentHotkeysAndMapsFixedCommands() async throws {
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
        let plainRegistration = try XCTUnwrap(registrar.registrations[plain])
        let actionRegistration = try XCTUnwrap(registrar.registrations[actionHotkey])

        try service.beginPickerChoiceSession(actionCount: 3)

        XCTAssertTrue(plainRegistration.isInvalidated)
        XCTAssertTrue(actionRegistration.isInvalidated)
        registrar.send(.pressed, for: pickerDescriptor(keyCode: kVK_Return))
        registrar.send(.released, for: pickerDescriptor(keyCode: kVK_Return))
        registrar.send(.pressed, for: pickerDescriptor(keyCode: kVK_ANSI_1))
        registrar.send(.pressed, for: pickerDescriptor(keyCode: kVK_ANSI_3))
        registrar.send(.pressed, for: escapeDescriptor)

        await waitForEventCount(4) { events.count }
        XCTAssertEqual(events, [
            .pickerChoice(.keepAsIs),
            .pickerChoice(.action(index: 0)),
            .pickerChoice(.action(index: 2)),
            .cancel,
        ])
    }

    func testPickerChoiceSessionClampsActionCommandsToNine() throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)

        try service.beginPickerChoiceSession(actionCount: 42)

        XCTAssertEqual(
            Set(registrar.activeDescriptors),
            Set([
                pickerDescriptor(keyCode: kVK_Return),
                pickerDescriptor(keyCode: kVK_ANSI_1),
                pickerDescriptor(keyCode: kVK_ANSI_2),
                pickerDescriptor(keyCode: kVK_ANSI_3),
                pickerDescriptor(keyCode: kVK_ANSI_4),
                pickerDescriptor(keyCode: kVK_ANSI_5),
                pickerDescriptor(keyCode: kVK_ANSI_6),
                pickerDescriptor(keyCode: kVK_ANSI_7),
                pickerDescriptor(keyCode: kVK_ANSI_8),
                pickerDescriptor(keyCode: kVK_ANSI_9),
                escapeDescriptor,
            ])
        )
    }

    func testEscapeMonitorDoesNotDuplicatePickerCarbonCancel() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.beginPickerChoiceSession(actionCount: 0)

        service.handleEscapePressed()
        registrar.send(.pressed, for: escapeDescriptor)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.cancel])
    }

    func testNegativeActionCountStillRegistersKeepAndCancel() throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)

        try service.beginPickerChoiceSession(actionCount: -1)

        XCTAssertEqual(
            Set(registrar.activeDescriptors),
            Set([pickerDescriptor(keyCode: kVK_Return), escapeDescriptor])
        )
    }

    func testBeginningASecondPickerSessionIsRejectedWithoutChangingCommands() throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        try service.beginPickerChoiceSession(actionCount: 1)
        let registrationAttemptCount = registrar.registrationAttempts.count

        XCTAssertThrowsError(try service.beginPickerChoiceSession(actionCount: 9)) { error in
            XCTAssertEqual(error as? GlobalHotkeyService.Error, .pickerSessionActive)
        }

        XCTAssertEqual(registrar.registrationAttempts.count, registrationAttemptCount)
        XCTAssertNil(registrar.registrations[pickerDescriptor(keyCode: kVK_ANSI_2)])
    }

    func testEndingPickerChoiceSessionRestoresPersistentHotkeysAndIsIdempotent() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.configure(descriptor: plain, mode: .holdToRecord)

        try service.beginPickerChoiceSession(actionCount: 1)
        try service.endPickerChoiceSession()
        let registrationAttemptCount = registrar.registrationAttempts.count
        try service.endPickerChoiceSession()
        registrar.send(.pressed, for: plain)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.pressed(route: .plain)])
        XCTAssertEqual(registrar.registrationAttempts.count, registrationAttemptCount)
        XCTAssertFalse(try XCTUnwrap(registrar.registrations[plain]).isInvalidated)
    }

    func testPersistentCommandOneIsReusedByPickerThenRestoredToItsRoute() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let commandOne = pickerDescriptor(keyCode: kVK_ANSI_1)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.configure(
            registrations: [DictationHotkeyRegistration(descriptor: commandOne, route: .picker)],
            mode: .holdToRecord
        )

        try service.beginPickerChoiceSession(actionCount: 1)
        registrar.send(.pressed, for: commandOne)
        await waitForEventCount(1) { events.count }
        try service.endPickerChoiceSession()
        registrar.send(.pressed, for: commandOne)

        await waitForEventCount(2) { events.count }
        XCTAssertEqual(events, [
            .pickerChoice(.action(index: 0)),
            .pressed(route: .picker),
        ])
    }

    func testPickerRegistrationConflictRollsBackAndRestoresPersistentHotkeys() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let conflictingPickerDescriptor = pickerDescriptor(keyCode: kVK_ANSI_2)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.configure(descriptor: plain, mode: .holdToRecord)
        registrar.failingDescriptors = [conflictingPickerDescriptor]

        XCTAssertThrowsError(try service.beginPickerChoiceSession(actionCount: 3)) { error in
            XCTAssertEqual(error as? GlobalHotkeyService.Error, .registrationConflict)
        }
        registrar.send(.pressed, for: plain)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.pressed(route: .plain)])
        XCTAssertFalse(try XCTUnwrap(registrar.registrations[plain]).isInvalidated)
        let partialPickerRegistrations = registrar.registrationHistory
            .filter { $0.descriptor.modifiers == UInt32(cmdKey) }
            .map(\.registration)
        XCTAssertTrue(partialPickerRegistrations.allSatisfy(\.isInvalidated))
    }

    func testRestoreFailureInvalidatesTransientAndPartialPersistentRegistrations() throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let first = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let second = HotkeyDescriptor(keyCode: 2, modifiers: HotkeyDescriptor.requiredModifierFlags)
        try service.configure(
            registrations: [
                DictationHotkeyRegistration(descriptor: first, route: .plain),
                DictationHotkeyRegistration(descriptor: second, route: .picker),
            ],
            mode: .holdToRecord
        )
        try service.beginPickerChoiceSession(actionCount: 1)
        registrar.failingDescriptors = [second]

        XCTAssertThrowsError(try service.endPickerChoiceSession()) { error in
            XCTAssertEqual(error as? GlobalHotkeyService.Error, .registrationConflict)
        }

        XCTAssertEqual(registrar.activeDescriptors, [])
        let pickerDescriptors = Set([
            pickerDescriptor(keyCode: kVK_Return),
            pickerDescriptor(keyCode: kVK_ANSI_1),
            escapeDescriptor,
        ])
        let pickerRegistrations = registrar.registrationHistory
            .filter { pickerDescriptors.contains($0.descriptor) }
            .map(\.registration)
        XCTAssertTrue(pickerRegistrations.allSatisfy(\.isInvalidated))
    }

    func testStalePickerCallbackFromPreviousSessionIsIgnored() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let commandOne = pickerDescriptor(keyCode: kVK_ANSI_1)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }

        try service.beginPickerChoiceSession(actionCount: 1)
        let staleHandler = try XCTUnwrap(registrar.handlers[commandOne])
        try service.endPickerChoiceSession()
        try service.beginPickerChoiceSession(actionCount: 1)
        staleHandler(.pressed)
        registrar.send(.pressed, for: commandOne)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.pickerChoice(.action(index: 0))])
    }

    func testStalePersistentCallbackFromBeforeSuspensionIsIgnored() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.configure(descriptor: plain, mode: .holdToRecord)
        let staleHandler = try XCTUnwrap(registrar.handlers[plain])

        try service.beginPickerChoiceSession(actionCount: 0)
        try service.endPickerChoiceSession()
        staleHandler(.pressed)
        registrar.send(.pressed, for: plain)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.pressed(route: .plain)])
    }

    func testConfigureDuringPickerSessionAllowsModeOnlyChange() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let persistent = [DictationHotkeyRegistration(descriptor: plain, route: .plain)]
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.configure(registrations: persistent, mode: .holdToRecord)
        try service.beginPickerChoiceSession(actionCount: 0)

        try service.configure(registrations: persistent, mode: .toggleToRecord)
        try service.endPickerChoiceSession()
        registrar.send(.pressed, for: plain)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.toggle(route: .plain)])
    }

    func testConfigureDuringPickerSessionRejectsPersistentShortcutChanges() async throws {
        let registrar = FakeGlobalHotkeyRegistrar()
        let service = GlobalHotkeyService(registrar: registrar)
        let plain = HotkeyDescriptor(keyCode: 1, modifiers: HotkeyDescriptor.requiredModifierFlags)
        let replacement = HotkeyDescriptor(keyCode: 2, modifiers: HotkeyDescriptor.requiredModifierFlags)
        var events: [GlobalHotkeyService.Event] = []
        service.onEvent = { events.append($0) }
        try service.configure(descriptor: plain, mode: .holdToRecord)
        try service.beginPickerChoiceSession(actionCount: 0)

        XCTAssertThrowsError(try service.configure(descriptor: replacement, mode: .toggleToRecord)) {
            XCTAssertEqual($0 as? GlobalHotkeyService.Error, .pickerSessionActive)
        }
        try service.endPickerChoiceSession()
        registrar.send(.pressed, for: plain)

        await waitForEventCount(1) { events.count }
        XCTAssertEqual(events, [.pressed(route: .plain)])
        XCTAssertNil(registrar.registrations[replacement])
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

    private var escapeDescriptor: HotkeyDescriptor {
        HotkeyDescriptor(keyCode: UInt32(kVK_Escape), modifiers: 0)
    }

    private func pickerDescriptor(keyCode: Int) -> HotkeyDescriptor {
        HotkeyDescriptor(keyCode: UInt32(keyCode), modifiers: UInt32(cmdKey))
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
    private(set) var registrationAttempts: [HotkeyDescriptor] = []
    private(set) var registrationHistory: [
        (descriptor: HotkeyDescriptor, registration: FakeGlobalHotkeyRegistration)
    ] = []

    var registeredDescriptors: [HotkeyDescriptor] { Array(registrations.keys) }
    var activeDescriptors: [HotkeyDescriptor] {
        registrations.compactMap { descriptor, registration in
            registration.isInvalidated ? nil : descriptor
        }
    }

    func register(
        descriptor: HotkeyDescriptor,
        handler: @escaping (GlobalHotkeyService.RawEvent) -> Void
    ) throws -> any GlobalHotkeyRegistration {
        registrationAttempts.append(descriptor)
        if registrations[descriptor]?.isInvalidated == false {
            throw GlobalHotkeyRegistrarError.conflict
        }
        if failingDescriptors.contains(descriptor) {
            throw GlobalHotkeyRegistrarError.conflict
        }
        if let error {
            throw error
        }
        let registration = FakeGlobalHotkeyRegistration()
        handlers[descriptor] = handler
        registrations[descriptor] = registration
        registrationHistory.append((descriptor, registration))
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
