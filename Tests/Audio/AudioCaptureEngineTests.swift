import AVFoundation
import XCTest
@testable import Viska

final class AudioCaptureEngineTests: XCTestCase {
    func testRecordingSettingsProduceMono16BitPCMAtTranscriptionSampleRate() {
        let settings = AudioCaptureEngine.recordingSettings()

        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 16_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
    }

    func testMeterLevelIsClampedAndSilenceIsZero() {
        XCTAssertEqual(AudioCaptureEngine.normalizedMeterLevel(decibels: -80), 0)
        XCTAssertEqual(AudioCaptureEngine.normalizedMeterLevel(decibels: 0), 1)
        XCTAssertGreaterThan(AudioCaptureEngine.normalizedMeterLevel(decibels: -20), 0)
        XCTAssertLessThan(AudioCaptureEngine.normalizedMeterLevel(decibels: -20), 1)
    }
}
