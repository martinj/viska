import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorderView: View {
    let currentHotkey: HotkeyDescriptor?
    var onHotkeyClear: (() -> Void)? = nil
    let onHotkeyChange: (HotkeyDescriptor) -> Void

    @StateObject private var coordinator = HotkeyCaptureCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    coordinator.toggleCapture(onHotkeyChange: onHotkeyChange)
                } label: {
                    HStack(spacing: 6) {
                        Text(coordinator.isCapturing ? "Press shortcut…" : currentHotkey?.displayString ?? "Set shortcut")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(coordinator.isCapturing ? .secondary : .primary)
                        Spacer()
                        Image(systemName: coordinator.isCapturing ? "record.circle.fill" : "keyboard")
                            .font(.system(size: 11))
                            .foregroundStyle(coordinator.isCapturing ? Color.red : Color.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(coordinator.isCapturing ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                if currentHotkey != nil, let onHotkeyClear {
                    Button {
                        coordinator.stopCapture()
                        onHotkeyClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Unbind shortcut")
                    .accessibilityLabel("Unbind shortcut")
                }
            }

            if let errorMessage = coordinator.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .onDisappear {
            coordinator.stopCapture()
        }
    }
}

@MainActor
private final class HotkeyCaptureCoordinator: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var errorMessage: String?

    var helpText: String? {
        errorMessage
    }

    private var monitor: Any?

    func toggleCapture(onHotkeyChange: @escaping (HotkeyDescriptor) -> Void) {
        isCapturing ? stopCapture() : startCapture(onHotkeyChange: onHotkeyChange)
    }

    func stopCapture() {
        isCapturing = false

        if let monitor {
            NSEvent.removeMonitor(monitor)
        }

        monitor = nil
    }

    private func startCapture(onHotkeyChange: @escaping (HotkeyDescriptor) -> Void) {
        errorMessage = nil
        isCapturing = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            if event.keyCode == UInt16(kVK_Escape) {
                stopCapture()
                return nil
            }

            guard let descriptor = HotkeyDescriptor.from(event: event) else {
                return nil
            }

            do {
                try descriptor.validate()
                onHotkeyChange(descriptor)
                errorMessage = nil
            } catch let error as HotkeyDescriptor.ValidationError {
                errorMessage = HotkeyDescriptor.errorMessage(for: error)
            } catch {
                errorMessage = "Unable to record that shortcut."
            }

            stopCapture()
            return nil
        }
    }
}
