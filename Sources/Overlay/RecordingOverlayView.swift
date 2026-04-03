import SwiftUI

@MainActor
final class RecordingOverlayModel: ObservableObject {
    enum Phase {
        case recording
        case transcribing
    }

    @Published var levels: [CGFloat] = [CGFloat](repeating: 0, count: AudioLevelAnalyzer.bandCount)
    @Published var phase: Phase = .recording
}

struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.phase == .recording ? "mic.fill" : "waveform")
                .foregroundStyle(model.phase == .recording ? .white.opacity(0.7) : transcribingColor)
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
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(transcribingColor)
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
        .animation(.easeInOut(duration: 0.2), value: model.phase == .transcribing)
    }

    private var transcribingColor: Color {
        Color(red: 0.4, green: 0.7, blue: 1.0)
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
