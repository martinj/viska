import SwiftUI

@MainActor
final class RecordingOverlayModel: ObservableObject {
    enum Phase {
        case recording
        case transcribing
        case processing(actionName: String)
        case inserting
    }

    @Published var levels: [CGFloat] = [CGFloat](repeating: 0, count: AudioLevelAnalyzer.bandCount)
    @Published var phase: Phase = .recording
}

struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
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
