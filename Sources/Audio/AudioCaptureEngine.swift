import AVFoundation
import Foundation

struct RecordedAudio: Equatable {
    let fileURL: URL
    let sampleRate: Int
    let sampleCount: Int
}

@MainActor
protocol AudioCaptureControlling: AnyObject {
    func startCapture(levelHandler: @escaping (Float) -> Void) throws
    func stopCapture() throws -> RecordedAudio
    func cancelCapture()
}

@MainActor
final class AudioCaptureEngine: AudioCaptureControlling {
    enum Error: Swift.Error {
        case alreadyCapturing
        case inputUnavailable
        case unsupportedFormat
        case nothingCaptured
    }

    private let engine = AVAudioEngine()
    private let wavEncoder = WAVEncoder()
    private let fileManager: FileManager

    private var currentSampleRate = 16_000
    private var captureSession: CaptureSession?
    private var isCapturing = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func startCapture(levelHandler: @escaping (Float) -> Void) throws {
        guard !isCapturing else { throw Error.alreadyCapturing }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0 else {
            throw Error.inputUnavailable
        }

        currentSampleRate = Int(inputFormat.sampleRate.rounded())
        let captureSession = CaptureSession(levelRelay: MainQueueLevelRelay(levelHandler: levelHandler))
        self.captureSession = captureSession

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat,
            block: Self.makeTapBlock(captureSession: captureSession)
        )

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    func stopCapture() throws -> RecordedAudio {
        guard isCapturing else { throw Error.nothingCaptured }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        guard let captureSession else {
            throw Error.nothingCaptured
        }

        self.captureSession = nil

        let samples = captureSession.snapshot()
        guard !samples.isEmpty else {
            throw Error.nothingCaptured
        }

        let wavData = wavEncoder.encodePCM16(samples: samples, sampleRate: currentSampleRate)
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("voice-companion-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        try wavData.write(to: outputURL, options: .atomic)

        return RecordedAudio(
            fileURL: outputURL,
            sampleRate: currentSampleRate,
            sampleCount: samples.count
        )
    }

    func cancelCapture() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        captureSession?.clear()
        captureSession = nil
    }

    nonisolated private static func makeTapBlock(captureSession: CaptureSession) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let convertedSamples = convertToPCM16Mono(buffer: buffer)
            let level = AudioLevelAnalyzer.normalizedLevel(for: buffer)

            captureSession.append(contentsOf: convertedSamples)
            captureSession.dispatchLevel(level)
        }
    }

    nonisolated private static func convertToPCM16Mono(buffer: AVAudioPCMBuffer) -> [Int16] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        if let floatData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            return (0..<frameCount).map { frameIndex in
                let average = (0..<channelCount).reduce(Float.zero) { partialResult, channelIndex in
                    partialResult + floatData[channelIndex][frameIndex]
                } / Float(channelCount)

                let clipped = min(max(average, -1), 1)
                return Int16(clipped * Float(Int16.max))
            }
        }

        if let int16Data = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            return (0..<frameCount).map { frameIndex in
                let total = (0..<channelCount).reduce(Int32.zero) { partialResult, channelIndex in
                    partialResult + Int32(int16Data[channelIndex][frameIndex])
                }

                return Int16(total / Int32(channelCount))
            }
        }

        return []
    }
}

private final class CaptureSession: @unchecked Sendable {
    private let sampleAccumulator = SampleAccumulator()
    private let levelRelay: MainQueueLevelRelay

    init(levelRelay: MainQueueLevelRelay) {
        self.levelRelay = levelRelay
    }

    func append(contentsOf samples: [Int16]) {
        sampleAccumulator.append(contentsOf: samples)
    }

    func snapshot() -> [Int16] {
        sampleAccumulator.snapshot()
    }

    func clear() {
        sampleAccumulator.clear()
    }

    func dispatchLevel(_ level: Float) {
        levelRelay.dispatch(level)
    }
}

private final class MainQueueLevelRelay: @unchecked Sendable {
    private let levelHandler: (Float) -> Void

    @MainActor
    init(levelHandler: @escaping (Float) -> Void) {
        self.levelHandler = levelHandler
    }

    func dispatch(_ level: Float) {
        DispatchQueue.main.async {
            self.levelHandler(level)
        }
    }
}

private final class SampleAccumulator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice-companion.audio-capture")
    private var samples: [Int16] = []

    func append(contentsOf newSamples: [Int16]) {
        queue.async {
            self.samples.append(contentsOf: newSamples)
        }
    }

    func snapshot() -> [Int16] {
        queue.sync { samples }
    }

    func clear() {
        queue.sync {
            samples.removeAll(keepingCapacity: false)
        }
    }
}
