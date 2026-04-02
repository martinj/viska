import AVFoundation
import Foundation

struct AudioLevelAnalyzer {
    static func normalizedLevel(for buffer: AVAudioPCMBuffer) -> Float {
        if let floatData = buffer.floatChannelData {
            return normalizedLevel(
                samples: UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength))
            )
        }

        if let int16Data = buffer.int16ChannelData {
            let samples = UnsafeBufferPointer(start: int16Data[0], count: Int(buffer.frameLength))
            let normalizedSamples = samples.map { Float($0) / Float(Int16.max) }
            return normalizedLevel(samples: normalizedSamples[...])
        }

        return 0
    }

    private static func normalizedLevel<S: Sequence>(samples: S) -> Float where S.Element == Float {
        var peak: Float = 0

        for sample in samples {
            peak = max(peak, abs(sample))
        }

        return min(max(peak, 0), 1)
    }
}
