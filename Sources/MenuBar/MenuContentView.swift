import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var dictationStore: DictationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "mic.badge.xmark")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("VoiceCompanion")
                        .font(.system(size: 14, weight: .semibold))

                    Text("Global hotkey dictation")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                statusBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            // Status detail
            if case .unavailable = dictationStore.state {
                Text(dictationStore.state.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if let hotkeyErrorMessage = dictationStore.hotkeyErrorMessage {
                Label(hotkeyErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            // Settings sections
            VStack(alignment: .leading, spacing: 16) {
                // Recording mode section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording Mode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Picker("Recording mode", selection: recordingModeBinding) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Hotkey section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shortcut")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    HotkeyRecorderView(currentHotkey: settingsStore.preferences.hotkey) { descriptor in
                        dictationStore.updateHotkey(descriptor)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Spacer(minLength: 0)

            Divider()
                .padding(.horizontal, 12)

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit")
                        .font(.system(size: 12))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 300, height: 320, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(dictationStore.state.statusTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1), in: Capsule())
    }

    private var recordingModeBinding: Binding<RecordingMode> {
        Binding(
            get: { settingsStore.preferences.recordingMode },
            set: { settingsStore.updateRecordingMode($0) }
        )
    }

    private var statusSymbolName: String {
        switch dictationStore.state {
        case .unavailable:
            "exclamationmark.triangle.fill"
        case .idle:
            "checkmark.circle.fill"
        case .recording:
            "mic.circle.fill"
        case .transcribing:
            "waveform.and.magnifyingglass"
        case .inserting:
            "text.cursor"
        }
    }

    private var statusColor: Color {
        switch dictationStore.state {
        case .unavailable:
            .orange
        case .idle:
            .green
        case .recording:
            .red
        case .transcribing, .inserting:
            .blue
        }
    }
}
