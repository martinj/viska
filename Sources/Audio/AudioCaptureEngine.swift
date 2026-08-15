import AVFoundation
import Foundation
import OSLog

struct RecordedAudio: Equatable, Sendable {
    let fileURL: URL
    let sampleRate: Int
    let sampleCount: Int
}

@MainActor
protocol AudioCaptureControlling: AnyObject {
    func startCapture(levelHandler: @escaping ([Float]) -> Void) async throws
    func stopCapture() async throws -> RecordedAudio
    func cancelCapture() async
}

@MainActor
final class AudioCaptureEngine: AudioCaptureControlling {
    enum Error: Swift.Error, Sendable {
        case alreadyCapturing
        case inputUnavailable
        case nothingCaptured
    }

    nonisolated static let sampleRate = 16_000

    private let worker: AudioRecorderWorker

    init() {
        self.worker = AudioRecorderWorker()
    }

    func startCapture(levelHandler: @escaping ([Float]) -> Void) async throws {
        let levelRelay = MainQueueLevelRelay(levelHandler: levelHandler)

        try await withTaskCancellationHandler {
            try await worker.start(levelRelay: levelRelay)
            try Task.checkCancellation()
        } onCancel: { [worker] in
            Task {
                await worker.cancel()
            }
        }
    }

    func stopCapture() async throws -> RecordedAudio {
        try await worker.stop()
    }

    func cancelCapture() async {
        await worker.cancel()
    }

    nonisolated static func recordingSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    nonisolated static func normalizedMeterLevel(decibels: Float) -> Float {
        guard decibels > -60 else { return 0 }

        let amplitude = pow(10, decibels / 20)
        return min(sqrt(amplitude * 4), 1)
    }
}

private actor AudioRecorderWorker {
    private let logger = Logger(subsystem: "com.martinjonsson.Viska", category: "AudioCapture")

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var outputURL: URL?
    private var meterHistory = [Float](repeating: 0, count: AudioLevelAnalyzer.bandCount)

    func start(levelRelay: MainQueueLevelRelay) throws {
        guard recorder == nil else { throw AudioCaptureEngine.Error.alreadyCapturing }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viska-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            let recorder = try AVAudioRecorder(
                url: outputURL,
                settings: AudioCaptureEngine.recordingSettings()
            )
            recorder.isMeteringEnabled = true

            guard recorder.prepareToRecord(), recorder.record() else {
                recorder.deleteRecording()
                throw AudioCaptureEngine.Error.inputUnavailable
            }

            self.recorder = recorder
            self.outputURL = outputURL
            meterHistory = [Float](repeating: 0, count: AudioLevelAnalyzer.bandCount)
            startMetering(levelRelay: levelRelay)
            logger.info("Microphone capture started with input-only recorder")
        } catch {
            logger.error("Microphone capture failed to start: \(error.localizedDescription, privacy: .public)")
            self.recorder = nil
            self.outputURL = nil
            throw error
        }
    }

    func stop() throws -> RecordedAudio {
        guard let recorder, let outputURL else {
            throw AudioCaptureEngine.Error.nothingCaptured
        }

        stopMetering()
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.outputURL = nil

        let sampleCount = Int(duration * Double(AudioCaptureEngine.sampleRate))
        guard sampleCount > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 44 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioCaptureEngine.Error.nothingCaptured
        }

        return RecordedAudio(
            fileURL: outputURL,
            sampleRate: AudioCaptureEngine.sampleRate,
            sampleCount: sampleCount
        )
    }

    func cancel() {
        stopMetering()
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        outputURL = nil
        meterHistory = [Float](repeating: 0, count: AudioLevelAnalyzer.bandCount)
    }

    private func startMetering(levelRelay: MainQueueLevelRelay) {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
                await self?.publishMeterLevel(to: levelRelay)
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func publishMeterLevel(to levelRelay: MainQueueLevelRelay) {
        guard let recorder else { return }

        recorder.updateMeters()
        let level = AudioCaptureEngine.normalizedMeterLevel(
            decibels: recorder.averagePower(forChannel: 0)
        )
        meterHistory.removeFirst()
        meterHistory.append(level)
        levelRelay.dispatch(meterHistory)
    }
}

private final class MainQueueLevelRelay: @unchecked Sendable {
    private let levelHandler: ([Float]) -> Void

    @MainActor
    init(levelHandler: @escaping ([Float]) -> Void) {
        self.levelHandler = levelHandler
    }

    func dispatch(_ levels: [Float]) {
        DispatchQueue.main.async {
            self.levelHandler(levels)
        }
    }
}
