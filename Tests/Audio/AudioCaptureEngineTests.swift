import AVFoundation
import XCTest
@testable import Viska

final class AudioCaptureEngineTests: XCTestCase {
    func testCaptureFormatUsesHardwareInputFormatWhenSampleRateDrifts() {
        let hardwareInputFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let nodeOutputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

        let captureFormat = AudioCaptureEngine.captureFormat(
            hardwareInputFormat: hardwareInputFormat,
            nodeOutputFormat: nodeOutputFormat
        )

        XCTAssertEqual(captureFormat.sampleRate, hardwareInputFormat.sampleRate)
        XCTAssertEqual(captureFormat.channelCount, hardwareInputFormat.channelCount)
    }

    func testCaptureFormatKeepsNodeOutputFormatWhenItMatchesHardware() {
        let hardwareInputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let nodeOutputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

        let captureFormat = AudioCaptureEngine.captureFormat(
            hardwareInputFormat: hardwareInputFormat,
            nodeOutputFormat: nodeOutputFormat
        )

        XCTAssertEqual(captureFormat.sampleRate, nodeOutputFormat.sampleRate)
        XCTAssertEqual(captureFormat.channelCount, nodeOutputFormat.channelCount)
    }
}
