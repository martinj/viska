import AVFoundation
import Foundation

struct AudioLevelAnalyzer {
    static let bandCount = 40

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

    static func waveformBands(for buffer: AVAudioPCMBuffer) -> [Float] {
        if let floatData = buffer.floatChannelData {
            return bands(
                from: UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength))
            )
        }

        if let int16Data = buffer.int16ChannelData {
            let raw = UnsafeBufferPointer(start: int16Data[0], count: Int(buffer.frameLength))
            let floats = raw.map { Float($0) / Float(Int16.max) }
            return bands(from: floats[...])
        }

        return [Float](repeating: 0, count: bandCount)
    }

    private static func normalizedLevel<S: Sequence>(samples: S) -> Float where S.Element == Float {
        var peak: Float = 0

        for sample in samples {
            peak = max(peak, abs(sample))
        }

        return min(max(peak, 0), 1)
    }

    private static func bands<C: RandomAccessCollection>(from samples: C) -> [Float]
        where C.Element == Float, C.Index == Int
    {
        let count = samples.count
        guard count > 0 else { return [Float](repeating: 0, count: bandCount) }

        let segmentSize = max(count / bandCount, 1)
        var result = [Float]()
        result.reserveCapacity(bandCount)

        for i in 0..<bandCount {
            let start = samples.startIndex + i * segmentSize
            let end = min(start + segmentSize, samples.endIndex)
            guard start < samples.endIndex else {
                result.append(0)
                continue
            }

            var peak: Float = 0
            for j in start..<end {
                peak = max(peak, abs(samples[j]))
            }
            // Amplify and compress: speech peaks are typically 0.05–0.2,
            // so boost by 4x then apply sqrt to lift quiet parts.
            let amplified = min(peak * 4, 1)
            result.append(sqrt(amplified))
        }

        return result
    }
}
