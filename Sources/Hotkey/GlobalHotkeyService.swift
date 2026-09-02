import AppKit
import Carbon.HIToolbox
import Foundation

protocol GlobalHotkeyRegistration {
    func invalidate()
}

enum GlobalHotkeyRegistrarError: Error, Equatable {
    case conflict
    case registrationFailed(OSStatus)
}

protocol GlobalHotkeyRegistering {
    func register(
        descriptor: HotkeyDescriptor,
        handler: @escaping (GlobalHotkeyService.RawEvent) -> Void
    ) throws -> any GlobalHotkeyRegistration
}

@MainActor
protocol GlobalHotkeyControlling: AnyObject {
    var onEvent: ((GlobalHotkeyService.Event) -> Void)? { get set }
    func configure(registrations: [DictationHotkeyRegistration], mode: RecordingMode) throws
    func beginPickerChoiceSession(actionCount: Int) throws
    func endPickerChoiceSession() throws
}

struct DictationHotkeyRegistration: Equatable {
    let descriptor: HotkeyDescriptor
    let route: DictationRoute
}

@MainActor
final class GlobalHotkeyService: GlobalHotkeyControlling {
    enum RawEvent: Equatable {
        case pressed
        case released
    }

    enum Event: Equatable {
        case pressed(route: DictationRoute)
        case released(route: DictationRoute)
        case toggle(route: DictationRoute)
        case cancel
        case pickerChoice(PickerChoice)
    }

    enum Error: Swift.Error, Equatable {
        case invalidDescriptor(HotkeyDescriptor.ValidationError)
        case registrationConflict
        case registrationFailed(OSStatus)
        case pickerSessionActive
    }

    var onEvent: ((Event) -> Void)?

    private let registrar: any GlobalHotkeyRegistering
    private var registrations: [HotkeyDescriptor: any GlobalHotkeyRegistration] = [:]
    private var registrationGenerations: [HotkeyDescriptor: UInt64] = [:]
    private var routesByDescriptor: [HotkeyDescriptor: DictationRoute] = [:]
    private var configuredRegistrations: [DictationHotkeyRegistration] = []
    private var recordingMode: RecordingMode = .holdToRecord
    private var pickerRegistrations: [any GlobalHotkeyRegistration] = []
    private var pickerSessionGeneration: UInt64?
    private var nextRegistrationGeneration: UInt64 = 0
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?

    init(registrar: any GlobalHotkeyRegistering = CarbonGlobalHotkeyRegistrar()) {
        self.registrar = registrar
        installEscapeMonitorsIfNeeded()
    }

    func configure(registrations requested: [DictationHotkeyRegistration], mode: RecordingMode) throws {
        try validate(requested)

        if pickerSessionGeneration != nil {
            guard hasSamePersistentConfiguration(requested) else {
                throw Error.pickerSessionActive
            }

            recordingMode = mode
            return
        }

        let requestedDescriptors = Set(requested.map(\.descriptor))
        let descriptorsToAdd = requestedDescriptors.subtracting(registrations.keys)
        var additions: [HotkeyDescriptor: any GlobalHotkeyRegistration] = [:]

        do {
            for descriptor in descriptorsToAdd {
                let generation = allocateRegistrationGeneration()
                additions[descriptor] = try registrar.register(
                    descriptor: descriptor,
                    handler: makeRawEventHandler(descriptor: descriptor, generation: generation)
                )
                registrationGenerations[descriptor] = generation
            }
        } catch let error as GlobalHotkeyRegistrarError {
            additions.values.forEach { $0.invalidate() }
            for descriptor in additions.keys {
                registrationGenerations.removeValue(forKey: descriptor)
            }
            switch error {
            case .conflict:
                throw Error.registrationConflict
            case .registrationFailed(let status):
                throw Error.registrationFailed(status)
            }
        }

        for descriptor in Set(registrations.keys).subtracting(requestedDescriptors) {
            registrations.removeValue(forKey: descriptor)?.invalidate()
            registrationGenerations.removeValue(forKey: descriptor)
        }
        registrations.merge(additions) { current, _ in current }
        routesByDescriptor = Dictionary(
            uniqueKeysWithValues: requested.map { ($0.descriptor, $0.route) }
        )
        configuredRegistrations = requested
        recordingMode = mode
    }

    func configure(descriptor: HotkeyDescriptor, mode: RecordingMode) throws {
        try configure(
            registrations: [DictationHotkeyRegistration(descriptor: descriptor, route: .plain)],
            mode: mode
        )
    }

    func beginPickerChoiceSession(actionCount: Int) throws {
        guard pickerSessionGeneration == nil else {
            throw Error.pickerSessionActive
        }

        suspendPersistentRegistrations()
        let generation = allocateRegistrationGeneration()
        pickerSessionGeneration = generation
        var additions: [any GlobalHotkeyRegistration] = []

        do {
            for (descriptor, event) in pickerCommands(actionCount: actionCount) {
                let registration = try registrar.register(
                    descriptor: descriptor,
                    handler: makePickerEventHandler(event: event, generation: generation)
                )
                additions.append(registration)
            }
            pickerRegistrations = additions
        } catch {
            additions.forEach { $0.invalidate() }
            pickerSessionGeneration = nil
            pickerRegistrations = []
            let registrationError = error

            do {
                try restorePersistentRegistrations()
            } catch let restorationError {
                throw restorationError
            }

            if let registrarError = registrationError as? GlobalHotkeyRegistrarError {
                throw mapRegistrarError(registrarError)
            }
            throw registrationError
        }
    }

    func endPickerChoiceSession() throws {
        guard pickerSessionGeneration != nil else { return }

        pickerSessionGeneration = nil
        pickerRegistrations.forEach { $0.invalidate() }
        pickerRegistrations = []
        try restorePersistentRegistrations()
    }

    nonisolated func handle(rawEvent: RawEvent, descriptor: HotkeyDescriptor) {
        runOnMainActor { service in
            service.handleRawEventOnMainActor(rawEvent, descriptor: descriptor)
        }
    }

    nonisolated func handle(rawEvent: RawEvent) {
        runOnMainActor { service in
            guard let descriptor = service.routesByDescriptor.keys.first else { return }
            service.handleRawEventOnMainActor(rawEvent, descriptor: descriptor)
        }
    }

    nonisolated func handleEscapePressed() {
        runOnMainActor { service in
            // Picker Escape is registered through Carbon so it can be consumed globally.
            // Ignore the observational NSEvent monitor while that exclusive hotkey is active.
            guard service.pickerSessionGeneration == nil else { return }
            service.onEvent?(.cancel)
        }
    }

    private func handleRawEventOnMainActor(_ rawEvent: RawEvent, descriptor: HotkeyDescriptor) {
        guard let route = routesByDescriptor[descriptor] else { return }

        switch (recordingMode, rawEvent) {
        case (.holdToRecord, .pressed):
            onEvent?(.pressed(route: route))
        case (.holdToRecord, .released):
            onEvent?(.released(route: route))
        case (.toggleToRecord, .pressed):
            onEvent?(.toggle(route: route))
        case (.toggleToRecord, .released):
            break
        }
    }

    private func handleRawEventOnMainActor(
        _ rawEvent: RawEvent,
        descriptor: HotkeyDescriptor,
        generation: UInt64
    ) {
        guard registrationGenerations[descriptor] == generation else { return }
        handleRawEventOnMainActor(rawEvent, descriptor: descriptor)
    }

    private func handlePickerEventOnMainActor(
        _ rawEvent: RawEvent,
        event: Event,
        generation: UInt64
    ) {
        guard rawEvent == .pressed, pickerSessionGeneration == generation else { return }
        onEvent?(event)
    }

    nonisolated private func runOnMainActor(
        _ operation: @escaping @MainActor (GlobalHotkeyService) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            operation(self)
        }
    }

    private func installEscapeMonitorsIfNeeded() {
        guard localEscapeMonitor == nil, globalEscapeMonitor == nil else { return }

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown],
            handler: makeLocalEscapeMonitorHandler()
        )

        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown],
            handler: makeGlobalEscapeMonitorHandler()
        )
    }

    nonisolated func makeRawEventHandler(descriptor: HotkeyDescriptor) -> (RawEvent) -> Void {
        { [weak self] rawEvent in
            self?.handle(rawEvent: rawEvent, descriptor: descriptor)
        }
    }

    nonisolated private func makeRawEventHandler(
        descriptor: HotkeyDescriptor,
        generation: UInt64
    ) -> (RawEvent) -> Void {
        { [weak self] rawEvent in
            self?.runOnMainActor { service in
                service.handleRawEventOnMainActor(
                    rawEvent,
                    descriptor: descriptor,
                    generation: generation
                )
            }
        }
    }

    nonisolated private func makePickerEventHandler(
        event: Event,
        generation: UInt64
    ) -> (RawEvent) -> Void {
        { [weak self] rawEvent in
            self?.runOnMainActor { service in
                service.handlePickerEventOnMainActor(rawEvent, event: event, generation: generation)
            }
        }
    }

    nonisolated func makeLocalEscapeMonitorHandler() -> (NSEvent) -> NSEvent? {
        { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else {
                return event
            }

            self?.handleEscapePressed()
            return nil
        }
    }

    nonisolated func makeGlobalEscapeMonitorHandler() -> (NSEvent) -> Void {
        { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            self?.handleEscapePressed()
        }
    }

    private func validate(_ requested: [DictationHotkeyRegistration]) throws {
        var descriptors = Set<HotkeyDescriptor>()
        for requestedRegistration in requested {
            do {
                try requestedRegistration.descriptor.validate()
            } catch let error as HotkeyDescriptor.ValidationError {
                throw Error.invalidDescriptor(error)
            }

            guard descriptors.insert(requestedRegistration.descriptor).inserted else {
                throw Error.registrationConflict
            }
        }
    }

    private func hasSamePersistentConfiguration(
        _ requested: [DictationHotkeyRegistration]
    ) -> Bool {
        guard requested.count == configuredRegistrations.count else { return false }
        let requestedRoutes = Dictionary(
            uniqueKeysWithValues: requested.map { ($0.descriptor, $0.route) }
        )
        return requestedRoutes == routesByDescriptor
    }

    private func suspendPersistentRegistrations() {
        registrations.values.forEach { $0.invalidate() }
        registrations = [:]
        registrationGenerations = [:]
    }

    private func restorePersistentRegistrations() throws {
        var restored: [HotkeyDescriptor: any GlobalHotkeyRegistration] = [:]
        var restoredGenerations: [HotkeyDescriptor: UInt64] = [:]

        do {
            for configuredRegistration in configuredRegistrations {
                let descriptor = configuredRegistration.descriptor
                let generation = allocateRegistrationGeneration()
                restored[descriptor] = try registrar.register(
                    descriptor: descriptor,
                    handler: makeRawEventHandler(descriptor: descriptor, generation: generation)
                )
                restoredGenerations[descriptor] = generation
            }
        } catch {
            restored.values.forEach { $0.invalidate() }
            if let registrarError = error as? GlobalHotkeyRegistrarError {
                throw mapRegistrarError(registrarError)
            }
            throw error
        }

        registrations = restored
        registrationGenerations = restoredGenerations
    }

    private func pickerCommands(actionCount: Int) -> [(HotkeyDescriptor, Event)] {
        let commandModifier = UInt32(cmdKey)
        let numberKeyCodes = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
        ]
        let clampedActionCount = min(max(actionCount, 0), numberKeyCodes.count)
        var commands: [(HotkeyDescriptor, Event)] = [
            (
                HotkeyDescriptor(keyCode: UInt32(kVK_Return), modifiers: commandModifier),
                .pickerChoice(.keepAsIs)
            ),
        ]
        commands += numberKeyCodes.prefix(clampedActionCount).enumerated().map { index, keyCode in
            (
                HotkeyDescriptor(keyCode: keyCode, modifiers: commandModifier),
                .pickerChoice(.action(index: index))
            )
        }
        commands.append(
            (
                HotkeyDescriptor(keyCode: UInt32(kVK_Escape), modifiers: 0),
                .cancel
            )
        )
        return commands
    }

    private func allocateRegistrationGeneration() -> UInt64 {
        nextRegistrationGeneration &+= 1
        return nextRegistrationGeneration
    }

    private func mapRegistrarError(_ error: GlobalHotkeyRegistrarError) -> Error {
        switch error {
        case .conflict:
            .registrationConflict
        case .registrationFailed(let status):
            .registrationFailed(status)
        }
    }
}

private final class CarbonGlobalHotkeyRegistrar: GlobalHotkeyRegistering {
    private let dispatcher = CarbonHotkeyDispatcher.shared

    func register(
        descriptor: HotkeyDescriptor,
        handler: @escaping (GlobalHotkeyService.RawEvent) -> Void
    ) throws -> any GlobalHotkeyRegistration {
        let id = dispatcher.allocateID(handler: handler)
        var ref: EventHotKeyRef?

        try withUnsafeMutablePointer(to: &ref) { pointer in
            let hotKeyID = EventHotKeyID(signature: CarbonHotkeyDispatcher.signature, id: id)
            let status = RegisterEventHotKey(
                descriptor.keyCode,
                descriptor.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                UInt32(kEventHotKeyExclusive),
                pointer
            )

            if status == eventHotKeyExistsErr {
                dispatcher.removeHandler(id: id)
                throw GlobalHotkeyRegistrarError.conflict
            }

            guard status == noErr, pointer.pointee != nil else {
                dispatcher.removeHandler(id: id)
                throw GlobalHotkeyRegistrarError.registrationFailed(status)
            }
        }

        return CarbonGlobalHotkeyRegistration(dispatcher: dispatcher, id: id, ref: ref)
    }
}

private final class CarbonGlobalHotkeyRegistration: GlobalHotkeyRegistration {
    private let dispatcher: CarbonHotkeyDispatcher
    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(dispatcher: CarbonHotkeyDispatcher, id: UInt32, ref: EventHotKeyRef?) {
        self.dispatcher = dispatcher
        self.id = id
        self.ref = ref
    }

    func invalidate() {
        dispatcher.removeHandler(id: id)

        if let ref {
            UnregisterEventHotKey(ref)
        }

        ref = nil
    }

    deinit {
        invalidate()
    }
}

private final class CarbonHotkeyDispatcher: @unchecked Sendable {
    static let shared = CarbonHotkeyDispatcher()
    static let signature = OSType(0x56434458)

    private var nextID: UInt32 = 1
    private var handlers: [UInt32: (GlobalHotkeyService.RawEvent) -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {
        installHandler()
    }

    func allocateID(handler: @escaping (GlobalHotkeyService.RawEvent) -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return id
    }

    func removeHandler(id: UInt32) {
        handlers.removeValue(forKey: id)
    }

    private func installHandler() {
        guard handlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let dispatcher = Unmanaged<CarbonHotkeyDispatcher>.fromOpaque(userData).takeUnretainedValue()
            return dispatcher.handle(event: event)
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handle(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = withUnsafeMutablePointer(to: &hotKeyID) { pointer in
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                pointer
            )
        }

        guard status == noErr else {
            return status
        }

        guard let handler = handlers[hotKeyID.id] else {
            return noErr
        }

        let rawEvent: GlobalHotkeyService.RawEvent = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            ? .pressed
            : .released
        handler(rawEvent)
        return noErr
    }
}
