import SwiftUI

@MainActor
final class RecordingOverlayModel: ObservableObject {
    @Published var level: CGFloat = 0
}

struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .semibold))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.green, Color.yellow, Color.orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(18, proxy.size.width * model.level))
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 260)
        .background(.black.opacity(0.82), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}
