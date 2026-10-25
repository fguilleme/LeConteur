import Foundation
import AVFoundation
import ConteurQwen
import Darwin

struct QwenRenderMetrics: Codable, Sendable {
    let generationSeconds: Double
    let audioSeconds: Double
    let mlxPeakBytes: Int
    let observedFootprintBytes: UInt64
    var modelLoads: Int = 0
}

struct QwenRenderedAudio: Sendable {
    let url: URL
    let metrics: QwenRenderMetrics
    var wordTimeline: QwenWordTimeline? = nil
}

struct QwenAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
}

enum QwenStreamEvent: Sendable {
    case audio(QwenAudioChunk)
    case finished(QwenRenderMetrics)
}

/// One serial inference queue shared by book playback and previews. The task chain also
/// waits for cancelled work to really stop before touching the mutable model again.
actor QwenVoiceRenderer {
    static let shared = QwenVoiceRenderer()
    private var model: Qwen3TTSModel?
    private var tail: Task<QwenRenderedAudio, Error>?
    private var runtimePrepared = false
    private var sessions: Set<UUID> = []
    private var pendingRequests = 0
    private var releaseRequested = false

    nonisolated func stream(_ text: String, style: NarrationStyle, language: String, speaker: QwenSpeaker = .ryan) -> AsyncThrowingStream<QwenStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let result = try await render(text, style: style, language: language, speaker: speaker, onChunk: {
                        continuation.yield(.audio($0))
                    })
                    try? FileManager.default.removeItem(at: result.url)
                    try Task.checkCancellation()
                    continuation.yield(.finished(result.metrics))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func render(_ text: String, style: NarrationStyle, language: String,
                speaker: QwenSpeaker = .ryan,
                sessionID: UUID? = nil,
                instructionOverride: String? = nil,
                seed: UInt64? = nil,
                temperature: Float? = nil,
                decoderDiagnosticFolder: URL? = nil,
                onChunk: @escaping @Sendable (QwenAudioChunk) -> Void = { _ in },
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> QwenRenderedAudio {
        try Task.checkCancellation()
        if let sessionID { sessions.insert(sessionID) }
        pendingRequests += 1
        defer {
            pendingRequests -= 1
            if releaseRequested { unloadIfIdle() }
        }
        // Use the pinned model's trained sampling defaults. The reduced French
        // temperature produced very long, degraded passages in device probes.
        // Diagnostics may still override it for controlled comparisons.
        let resolvedTemperature = temperature ?? 0.9
        let previous = tail
        let task = Task.detached(priority: .userInitiated) { [self] in
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            do {
                return try await synthesize(text, style: style, language: language, speaker: speaker,
                                        instructionOverride: instructionOverride, seed: seed, temperature: resolvedTemperature,
                                        decoderDiagnosticFolder: decoderDiagnosticFolder, onChunk: onChunk, progress: progress)
            } catch QwenGenerationError.tokenLimitReached {
                throw QwenError.generationLimitReached
            }
        }
        tail = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func unload() async {
        if let tail { _ = await tail.result }
        unloadIfIdle()
    }

    func endSession(_ id: UUID) { sessions.remove(id) }

    func unloadIfIdle() {
        releaseRequested = true
        // A different/inactive controller may receive the same memory warning.
        // Keep the shared model warm across a session's prefetch and pause gaps.
        guard sessions.isEmpty, pendingRequests == 0 else { return }
        releaseRequested = false
        // Clearing an unused MLX cache would initialise Metal just to free nothing.
        guard runtimePrepared else { return }
        model = nil
        QwenRuntime.clearCache()
        runtimePrepared = false
    }

    private func synthesize(_ text: String, style: NarrationStyle, language: String,
                            speaker: QwenSpeaker,
                            instructionOverride: String?, seed: UInt64?, temperature: Float,
                            decoderDiagnosticFolder: URL?,
                            onChunk: @escaping @Sendable (QwenAudioChunk) -> Void,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> QwenRenderedAudio {
        guard QwenModel.supported else { throw QwenError.unavailable }
        let manifest = try QwenManifest.bundled()
        guard QwenModel.isInstalled(manifest) else { throw QwenError.missing }
        let started = Date()
        QwenRuntime.prepare()
        runtimePrepared = true
        defer { QwenRuntime.clearCache() }
        #if DEBUG
        print("QWEN memory before load: \(Self.memoryFootprint()) available: \(os_proc_available_memory())")
        #endif
        let needsLoading = model == nil
        if needsLoading {
            guard os_proc_available_memory() > 3_500_000_000 else { throw QwenError.insufficientMemory }
            model = try await Qwen3TTSModel.fromModelDirectory(QwenModel.directory)
        }
        try Task.checkCancellation()
        guard let model else { throw QwenError.missing }
        #if DEBUG
        print("QWEN loaded memory: \(Self.memoryFootprint()) available: \(os_proc_available_memory())")
        #endif
        var samples: [Float] = []
        var codecFrames: [[Int32]] = []
        var footprint = Self.memoryFootprint()
        try model.generateChunks(text: text, instruction: instructionOverride ?? style.instruction(language: language),
                                 language: language, speaker: speaker.rawValue, seed: seed, temperature: temperature,
                                 onCodecFrames: decoderDiagnosticFolder == nil ? nil : { codecFrames = $0 }) { chunk in
            samples.append(contentsOf: chunk)
            onChunk(QwenAudioChunk(samples: chunk, sampleRate: model.sampleRate))
            footprint = max(footprint, Self.memoryFootprint())
            #if DEBUG
            print("QWEN chunk seconds: \(Double(samples.count) / Double(model.sampleRate)) memory: \(Self.memoryFootprint()) available: \(os_proc_available_memory())")
            #endif
            progress(Double(samples.count) / Double(model.sampleRate))
        }
        try Task.checkCancellation()
        guard samples.count > model.sampleRate / 10,
              samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.001 }) else { throw QwenError.emptyAudio }
        #if DEBUG || CONTEUR_VALIDATION
        if let folder = decoderDiagnosticFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(codecFrames).write(to: folder.appending(path: "codec-frames.json"))
            let reference = try model.decodePrefixForValidation(codecFrames)
            guard !reference.isEmpty, reference.allSatisfy(\.isFinite), samples.count >= reference.count else { throw QwenError.emptyAudio }
            let prefix = Array(samples.prefix(reference.count))
            let squaredError = zip(prefix, reference).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) }
            let power = reference.reduce(0.0) { $0 + Double($1) * Double($1) }
            let report: [String: Any] = [
                "text": text, "speaker": speaker.rawValue, "language": language,
                "temperature": temperature, "seed": seed.map { String($0) } ?? "random",
                "generatedCodecFrames": codecFrames.count, "comparedCodecFrames": min(codecFrames.count, 96),
                "samples": reference.count, "seconds": Double(reference.count) / Double(model.sampleRate),
                "normalizedRMSE": sqrt(squaredError / max(power, 1e-20)),
                "maxAbsoluteError": zip(prefix, reference).map { abs($0 - $1) }.max() ?? 0,
                "scope": "Same tokens: incremental decoding versus single-batch prefix. Does not validate pronunciation."
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appending(path: "report.json"))
            try Self.writeDiagnosticAudio(prefix, sampleRate: model.sampleRate, to: folder.appending(path: "stream-prefix.wav"))
            try Self.writeDiagnosticAudio(reference, sampleRate: model.sampleRate, to: folder.appending(path: "batch-prefix.wav"))
            print("QWEN_DECODER \(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)")
        }
        #endif
        let url = URL.temporaryDirectory.appending(path: "conteur-qwen-\(UUID().uuidString).wav")
        do {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(model.sampleRate), channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { throw QwenError.emptyAudio }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: samples.count) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close() // Flush the WAV tail before a prefetched passage is opened.
            try Task.checkCancellation()
            return QwenRenderedAudio(url: url, metrics: QwenRenderMetrics(
                generationSeconds: Date().timeIntervalSince(started), audioSeconds: Double(samples.count) / Double(model.sampleRate),
                mlxPeakBytes: QwenRuntime.peakMemory, observedFootprintBytes: footprint,
                modelLoads: needsLoading ? 1 : 0),
                wordTimeline: QwenWordTimeline(text: text, samples: samples, sampleRate: model.sampleRate))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    #if DEBUG || CONTEUR_VALIDATION
    private static func writeDiagnosticAudio(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw QwenError.emptyAudio }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }
    #endif

    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
