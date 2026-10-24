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
                onChunk: @escaping @Sendable (QwenAudioChunk) -> Void = { _ in },
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> QwenRenderedAudio {
        try Task.checkCancellation()
        if let sessionID { sessions.insert(sessionID) }
        pendingRequests += 1
        defer {
            pendingRequests -= 1
            if releaseRequested { unloadIfIdle() }
        }
        let previous = tail
        let task = Task.detached(priority: .userInitiated) { [self] in
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            return try await synthesize(text, style: style, language: language, speaker: speaker, onChunk: onChunk, progress: progress)
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
        var footprint = Self.memoryFootprint()
        try model.generateChunks(text: text, instruction: "Read in \(language). " + style.instruction, language: language, speaker: speaker.rawValue) { chunk in
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
                modelLoads: needsLoading ? 1 : 0))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

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
