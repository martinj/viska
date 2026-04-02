import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var dictationStore: DictationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("VoiceCompanion")
                    .font(.headline)

                Text("Global hotkey dictation companion for any focused macOS app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(dictationStore.state.statusTitle, systemImage: statusSymbolName)
                        .foregroundStyle(statusColor)

                    Text(dictationStore.state.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let hotkeyErrorMessage = dictationStore.hotkeyErrorMessage {
                        Text(hotkeyErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Recording mode") {
                Picker("Recording mode", selection: recordingModeBinding) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            GroupBox("Hotkey") {
                HotkeyRecorderView(currentHotkey: settingsStore.preferences.hotkey) { descriptor in
                    dictationStore.updateHotkey(descriptor)
                }
            }

            Spacer(minLength: 0)

            Divider()

            Button("Quit VoiceCompanion") {
                NSApp.terminate(nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 340, height: 360, alignment: .topLeading)
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
