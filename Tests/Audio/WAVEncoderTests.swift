import XCTest
@testable import VoiceCompanion

final class WAVEncoderTests: XCTestCase {
    func testEncodesPCM16WaveHeaderAndData() {
        let encoder = WAVEncoder()
        let samples: [Int16] = [0, Int16.max, Int16.min, 42]

        let data = encoder.encodePCM16(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(readUInt32(from: data, offset: 24), 16_000)
        XCTAssertEqual(readUInt16(from: data, offset: 34), 16)
        XCTAssertEqual(readUInt32(from: data, offset: 40), UInt32(samples.count * 2))
        XCTAssertEqual(data.count, 44 + (samples.count * 2))
    }

    private func readUInt16(from data: Data, offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { pointer in
            UInt16(littleEndian: pointer.load(as: UInt16.self))
        }
    }

    private func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { pointer in
            UInt32(littleEndian: pointer.load(as: UInt32.self))
        }
    }
}
