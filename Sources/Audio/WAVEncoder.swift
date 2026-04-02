import Foundation

struct WAVEncoder {
    func encodePCM16(samples: [Int16], sampleRate: Int, channelCount: Int = 1) -> Data {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let byteRate = sampleRate * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample
        let dataByteCount = samples.count * bytesPerSample
        let riffChunkSize = 36 + dataByteCount

        var data = Data()
        data.append(ascii: "RIFF")
        data.append(UInt32(riffChunkSize))
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.append(UInt32(16))
        data.append(UInt16(1))
        data.append(UInt16(channelCount))
        data.append(UInt32(sampleRate))
        data.append(UInt32(byteRate))
        data.append(UInt16(blockAlign))
        data.append(UInt16(bitsPerSample))
        data.append(ascii: "data")
        data.append(UInt32(dataByteCount))

        for sample in samples {
            data.append(UInt16(bitPattern: sample))
        }

        return data
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }

    mutating func append(ascii string: String) {
        append(contentsOf: string.utf8)
    }
}
