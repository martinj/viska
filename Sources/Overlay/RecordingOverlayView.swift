import SwiftUI

struct PickerPresentation: Equatable {
    let actionNames: [String]
    let transcriptPreview: String?
    let errorMessage: String?
}

@MainActor
final class RecordingOverlayModel: ObservableObject {
    enum Phase: Equatable {
        case recording
        case transcribing
        case choosing(PickerPresentation)
        case processing(actionName: String)
        case inserting
    }

    @Published var levels: [CGFloat] = [CGFloat](repeating: 0, count: AudioLevelAnalyzer.bandCount)
    @Published var phase: Phase = .recording
}

struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
        switch model.phase {
        case .choosing(let presentation):
            picker(presentation)
        case .recording, .transcribing, .processing, .inserting:
            capsule
        }
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            Image(systemName: phaseIcon)
                .foregroundStyle(isRecording ? .white.opacity(0.7) : progressColor)
                .font(.system(size: 14, weight: .medium))

            switch model.phase {
            case .recording:
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                        WaveformBar(level: level)
                    }
                }
                .frame(height: 28)

            case .transcribing:
                progressText("Transcribing…")
            case .choosing:
                EmptyView()
            case .processing(let actionName):
                VStack(alignment: .leading, spacing: 1) {
                    progressText("Processing…")
                    Text(actionName)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            case .inserting:
                progressText("Inserting…")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.85))
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    private func picker(_ presentation: PickerPresentation) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                if let errorMessage = presentation.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                if let transcriptPreview = presentation.transcriptPreview {
                    Text(transcriptPreview)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                } else {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(progressColor)
                        Text("Transcribing…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(progressColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: presentation.errorMessage == nil ? 54 : 78)

            Divider().overlay(.white.opacity(0.08))

            pickerRow(shortcut: "⌘↩", title: "Insert transcript", systemImage: "text.cursor")

            ForEach(Array(presentation.actionNames.enumerated()), id: \.offset) { index, name in
                pickerRow(shortcut: "⌘\(index + 1)", title: name, systemImage: "wand.and.sparkles")
            }

            Divider().overlay(.white.opacity(0.08))

            HStack(spacing: 6) {
                Text("Esc")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 39)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.42), radius: 18, y: 9)
    }

    private func pickerRow(shortcut: String, title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Text(shortcut)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(progressColor)
                .frame(width: 28, alignment: .leading)
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private var progressColor: Color {
        Color(red: 0.4, green: 0.7, blue: 1.0)
    }

    private var isRecording: Bool {
        if case .recording = model.phase { return true }
        return false
    }

    private var phaseIcon: String {
        switch model.phase {
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .choosing: "list.bullet"
        case .processing: "sparkles"
        case .inserting: "text.cursor"
        }
    }

    private func progressText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(progressColor)
    }
}

private struct WaveformBar: View {
    let level: CGFloat

    private var barHeight: CGFloat {
        let minHeight: CGFloat = 2
        let maxHeight: CGFloat = 26
        return minHeight + (maxHeight - minHeight) * level
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white)
            .frame(width: 2.5, height: barHeight)
            .shadow(color: .white.opacity(0.6 * level), radius: 2)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}
