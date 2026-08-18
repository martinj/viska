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

    struct Event: Equatable {
        enum Kind: Equatable {
            case pressed
            case released
            case toggle
            case cancel
        }

        let kind: Kind
        let route: DictationRoute?

        static let pressed = Event(kind: .pressed, route: .plain)
        static let released = Event(kind: .released, route: .plain)
        static let toggle = Event(kind: .toggle, route: .plain)
        static let cancel = Event(kind: .cancel, route: nil)

        static func pressed(route: DictationRoute) -> Event { Event(kind: .pressed, route: route) }
        static func released(route: DictationRoute) -> Event { Event(kind: .released, route: route) }
        static func toggle(route: DictationRoute) -> Event { Event(kind: .toggle, route: route) }
    }

    enum Error: Swift.Error, Equatable {
        case invalidDescriptor(HotkeyDescriptor.ValidationError)
        case registrationConflict
        case registrationFailed(OSStatus)
    }

    var onEvent: ((Event) -> Void)?

    private let registrar: any GlobalHotkeyRegistering
    private var registrations: [HotkeyDescriptor: any GlobalHotkeyRegistration] = [:]
    private var routesByDescriptor: [HotkeyDescriptor: DictationRoute] = [:]
    private var recordingMode: RecordingMode = .holdToRecord
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?

    init(registrar: any GlobalHotkeyRegistering = CarbonGlobalHotkeyRegistrar()) {
        self.registrar = registrar
        installEscapeMonitorsIfNeeded()
    }

    func configure(registrations requested: [DictationHotkeyRegistration], mode: RecordingMode) throws {
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

        let requestedDescriptors = Set(requested.map(\.descriptor))
        let descriptorsToAdd = requestedDescriptors.subtracting(registrations.keys)
        var additions: [HotkeyDescriptor: any GlobalHotkeyRegistration] = [:]

        do {
            for descriptor in descriptorsToAdd {
                additions[descriptor] = try registrar.register(
                    descriptor: descriptor,
                    handler: makeRawEventHandler(descriptor: descriptor)
                )
            }
        } catch let error as GlobalHotkeyRegistrarError {
            additions.values.forEach { $0.invalidate() }
            switch error {
            case .conflict:
                throw Error.registrationConflict
            case .registrationFailed(let status):
                throw Error.registrationFailed(status)
            }
        }

        for descriptor in Set(registrations.keys).subtracting(requestedDescriptors) {
            registrations.removeValue(forKey: descriptor)?.invalidate()
        }
        registrations.merge(additions) { current, _ in current }
        routesByDescriptor = Dictionary(
            uniqueKeysWithValues: requested.map { ($0.descriptor, $0.route) }
        )
        recordingMode = mode
    }

    func configure(descriptor: HotkeyDescriptor, mode: RecordingMode) throws {
        try configure(
            registrations: [DictationHotkeyRegistration(descriptor: descriptor, route: .plain)],
            mode: mode
        )
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
