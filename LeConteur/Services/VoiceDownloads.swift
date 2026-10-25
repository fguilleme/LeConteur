import Foundation
import Observation
import UIKit

struct VoiceDownloadSpec: Sendable {
    static var defaults: [Self] {
        var result = [Self.qwen].compactMap { $0 }
        #if DEBUG || CONTEUR_VALIDATION
        result.append(.validation)
        #endif
        return result
    }
    struct File: Codable, Sendable {
        let path: String
        let url: URL
        let bytes: Int64
        let sha256: String
        func validate(_ url: URL) throws {
            try QwenManifest.validate(.init(path: path, bytes: bytes, sha256: sha256), at: url)
        }
    }
    let id: String
    let revision: String
    let directory: URL
    let marker: String
    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var isInstalled: Bool {
        (try? String(contentsOf: directory.appending(path: marker), encoding: .utf8)) == revision
            && files.allSatisfy { file in
                Int64((try? directory.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == file.bytes
            }
    }
    static var qwen: Self? {
        guard let manifest = try? QwenManifest.bundled() else { return nil }
        return Self(id: "qwen", revision: manifest.revision, directory: QwenModel.directory, marker: "verified.revision",
                    files: manifest.files.map { file in
            File(path: file.path, url: URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(file.path)")!,
                 bytes: file.bytes, sha256: file.sha256)
        })
    }
}

struct VoiceDownloadPlan: Codable, Sendable {
    enum Phase: String, Codable { case downloading, paused, failed, installed }
    let revision: String
    var generation = UUID()
    var phase: Phase = .downloading
    var verified: Set<String> = []
    var error: String?
}

struct VoiceDownloadTag: Codable, Sendable, Equatable {
    let model: String
    let generation: UUID
    let path: String
    var encoded: String { String(data: try! JSONEncoder().encode(self), encoding: .utf8)! }
    init(model: String, generation: UUID, path: String) { self.model = model; self.generation = generation; self.path = path }
    init?(_ encoded: String?) {
        guard let data = encoded?.data(using: .utf8), let tag = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = tag
    }
}

struct VoiceDownloadSnapshot {
    var installed = false
    var busy = false
    var progress = 0.0
    var status = ""
    var error: String?
}

/// One stable session for all voice files. iOS owns the transfers; Swift Tasks
/// are used only for bounded checksum work, never for the network transfer.
@MainActor @Observable final class VoiceDownloads {
    nonisolated static let sessionIdentifier = "com.guilleme.conteur.voice-downloads.v1"
    static let shared = VoiceDownloads()
    private(set) var snapshots: [String: VoiceDownloadSnapshot] = [:]
    @ObservationIgnored private var plans: [String: VoiceDownloadPlan]
    @ObservationIgnored private let specs: [String: VoiceDownloadSpec]
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let delegate: VoiceDownloadDelegate
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var transfers: [Int: (URLSessionDownloadTask, VoiceDownloadTag)] = [:]
    @ObservationIgnored private var received: [String: Int64] = [:]
    @ObservationIgnored private var resumedTasks: Set<Int> = []
    @ObservationIgnored private var preparations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var checks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var recovering = true
    @ObservationIgnored private var completion: (() -> Void)?
    @ObservationIgnored private var eventsFinished = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    nonisolated static func configuration(identifier: String = sessionIdentifier) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false // This is an explicit user download.
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 3
        return config
    }

    init(specs: [VoiceDownloadSpec] = VoiceDownloadSpec.defaults,
         root: URL = URL.applicationSupportDirectory.appending(path: "VoiceDownloads"),
         configuration: URLSessionConfiguration = VoiceDownloads.configuration()) {
        self.specs = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
        self.root = root
        plans = (try? JSONDecoder().decode([String: VoiceDownloadPlan].self, from: Data(contentsOf: root.appending(path: "plans.json")))) ?? [:]
        delegate = VoiceDownloadDelegate(root: root)
        delegate.owner = self
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegate.queue)
        for spec in specs { refresh(spec.id) }
        recovery = Task { await recover() }
    }

    func snapshot(_ id: String) -> VoiceDownloadSnapshot { snapshots[id] ?? VoiceDownloadSnapshot() }
    func refreshInstallation(_ id: String) { refresh(id) }
    #if DEBUG
    func testTransfers() async -> [URLSessionTask] { await session.allTasks }
    func closeForTesting() {
        for id in plans.keys { pause(id, error: nil) }
        session.invalidateAndCancel()
    }
    #endif

    func install(_ id: String) {
        Task {
            await recovery?.value
            await preparations[id]?.value
            guard let spec = specs[id], !snapshot(id).busy, !spec.isInstalled else { return }
            plans[id] = VoiceDownloadPlan(revision: spec.revision)
            do { try persist(); prepare(id) }
            catch { fail(id, error) }
        }
    }

    func cancel(_ id: String) { pause(id, error: nil) }

    /// Invalidates old callbacks before the caller removes an installed model.
    func forget(_ id: String) {
        pause(id, error: nil)
        plans.removeValue(forKey: id)
        try? persist()
        snapshots[id] = VoiceDownloadSnapshot()
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        completion = completionHandler
        #if DEBUG || CONTEUR_VALIDATION
        if plans["download-validation"] != nil { VoiceDownloadValidation.record("background-wake") }
        #endif
        finishEventsIfReady()
    }

    func foreground() {
        Task {
            await recovery?.value
            for id in specs.keys where plans[id]?.phase == .downloading { prepare(id) }
            scanIncoming()
        }
    }

    private func recover() async {
        defer { recovering = false; finishEventsIfReady() }
        for (id, plan) in plans where plan.revision != specs[id]?.revision {
            if let spec = specs[id], plan.phase == .downloading { plans[id] = VoiceDownloadPlan(revision: spec.revision) }
            else { plans.removeValue(forKey: id) }
        }
        try? persist()
        let existing = await session.allTasks
        for task in existing {
            guard let task = task as? URLSessionDownloadTask, let tag = VoiceDownloadTag(task.taskDescription), accepts(tag) else {
                task.cancel(); continue
            }
            transfers[task.taskIdentifier] = (task, tag)
            received[key(tag)] = max(0, task.countOfBytesReceived)
            if task.state == .suspended { task.resume() }
        }
        for id in specs.keys {
            if plans[id]?.phase == .downloading { prepare(id) }
            else { refresh(id) }
        }
        scanIncoming()
    }

    private func prepare(_ id: String) {
        guard preparations[id] == nil, let spec = specs[id], let plan = plans[id], plan.phase == .downloading else { return }
        beginChecks()
        refresh(id, status: "Vérification des fichiers…")
        preparations[id] = Task {
            defer { preparations[id] = nil; finishEventsIfReady() }
            do {
                try VoiceDownloadDisk.directory(spec.directory)
                // Recheck imported/partially installed files, preserving every valid one.
                for file in spec.files {
                    try Task.checkCancellation()
                    let destination = spec.directory.appending(path: file.path)
                    let valid = try await validate(file, at: destination, allowMissing: true)
                    guard plans[id]?.generation == plan.generation else { return }
                    if valid { plans[id]?.verified.insert(file.path) }
                    else { plans[id]?.verified.remove(file.path) }
                }
                try persist()
                if completeIfReady(id) { return }
                let missing = spec.files.filter { plans[id]?.verified.contains($0.path) != true }
                let available = try spec.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                let remaining = missing.reduce(Int64(0)) { total, file in
                    total + max(0, file.bytes - (received["\(id):\(file.path)"] ?? 0))
                }
                guard available > remaining + 300_000_000 else { throw QwenError.insufficientSpace }
                // Enqueue ALL missing files now, not one after each background wake.
                for file in missing {
                    let tag = VoiceDownloadTag(model: id, generation: plan.generation, path: file.path)
                    if transfers.values.contains(where: { $0.1 == tag }) || hasIncoming(tag) { continue }
                    enqueue(tag, file: file)
                }
                refresh(id)
            } catch is CancellationError {
                // Durable plan/staging survives expiration; a later launch continues it.
            } catch { if plans[id]?.generation == plan.generation { fail(id, error) } }
        }
    }

    private func enqueue(_ tag: VoiceDownloadTag, file: VoiceDownloadSpec.File, fresh: Bool = false) {
        let resume = resumeURL(tag)
        let task: URLSessionDownloadTask
        if !fresh, let data = try? Data(contentsOf: resume) {
            task = session.downloadTask(withResumeData: data)
            resumedTasks.insert(task.taskIdentifier)
        }
        else { task = session.downloadTask(with: file.url) }
        try? FileManager.default.removeItem(at: resume)
        task.taskDescription = tag.encoded
        task.countOfBytesClientExpectsToReceive = file.bytes
        task.priority = URLSessionTask.highPriority
        #if DEBUG || CONTEUR_VALIDATION
        if tag.model == "download-validation" {
            VoiceDownloadValidation.record("scheduled", bytes: 0)
        }
        #endif
        transfers[task.taskIdentifier] = (task, tag)
        eventsFinished = false
        task.resume()
    }

    fileprivate func progress(_ taskID: Int, tag: VoiceDownloadTag, bytes: Int64) {
        guard accepts(tag) else { return }
        received[key(tag)] = bytes
        #if DEBUG || CONTEUR_VALIDATION
        if tag.model == "download-validation" { VoiceDownloadValidation.progress(bytes) }
        #endif
        refresh(tag.model)
    }

    fileprivate func staged(_ taskID: Int, tag: VoiceDownloadTag) {
        guard accepts(tag), let file = file(tag), checks[taskID] == nil else {
            if !accepts(tag) { removeIncoming(taskID) }
            return
        }
        beginChecks()
        #if DEBUG || CONTEUR_VALIDATION
        if tag.model == "download-validation" { VoiceDownloadValidation.record("received", bytes: file.bytes) }
        #endif
        refresh(tag.model, status: "Vérification du téléchargement…")
        checks[taskID] = Task {
            defer { checks[taskID] = nil; finishEventsIfReady() }
            do {
                await recovery?.value
                await preparations[tag.model]?.value
                try Task.checkCancellation()
                guard accepts(tag) else { removeIncoming(taskID); return }
                let source = incomingURL(taskID)
                _ = try await validate(file, at: source)
                try Task.checkCancellation()
                guard accepts(tag), let spec = specs[tag.model] else { removeIncoming(taskID); return }
                let destination = spec.directory.appending(path: file.path)
                try VoiceDownloadDisk.directory(destination.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: source, to: destination)
                try VoiceDownloadDisk.protect(destination)
                plans[tag.model]?.verified.insert(file.path)
                received[key(tag)] = file.bytes
                try persist()
                removeIncoming(taskID)
                _ = completeIfReady(tag.model)
                refresh(tag.model)
            } catch is CancellationError { /* Leave the durable staging for the next wake. */ }
            catch {
                if accepts(tag) { removeIncoming(taskID); fail(tag.model, error) }
                else { removeIncoming(taskID) }
            }
        }
    }

    fileprivate func finished(_ taskID: Int, tag: VoiceDownloadTag, error: Error?) {
        transfers.removeValue(forKey: taskID)
        let wasResumed = resumedTasks.remove(taskID) != nil
        guard accepts(tag), let error else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? VoiceDownloadDisk.write(data, to: resumeURL(tag)) }
        // Resume data may expire, especially behind signed CDN redirects.
        if wasResumed, ns.code != NSURLErrorCancelled, let file = file(tag) {
            enqueue(tag, file: file, fresh: true)
        } else { fail(tag.model, error) }
    }

    fileprivate func stagingFailed(_ taskID: Int, tag: VoiceDownloadTag, error: Error) {
        guard accepts(tag) else { return }
        fail(tag.model, error)
    }

    func finishedEvents() { eventsFinished = true; finishEventsIfReady() }

    private func pause(_ id: String, error: String?) {
        guard var plan = plans[id] else { return }
        plan.generation = UUID() // No late completion may install after Cancel/Remove.
        plan.phase = error == nil ? .paused : .failed
        plan.error = error
        plans[id] = plan
        preparations[id]?.cancel()
        for (taskID, entry) in transfers where entry.1.model == id {
            let tag = entry.1
            let generation = plan.generation
            entry.0.cancel { [weak self] data in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.plans[id]?.generation == generation, let data else { return }
                    try? VoiceDownloadDisk.write(data, to: self.resumeURL(tag))
                }
            }
            transfers.removeValue(forKey: taskID)
        }
        for (taskID, check) in checks {
            if let tag = incomingTag(taskID), tag.model == id { check.cancel() }
        }
        try? persist()
        refresh(id)
    }

    private func fail(_ id: String, _ error: Error) {
        #if DEBUG || CONTEUR_VALIDATION
        if id == "download-validation" {
            let failure = error as NSError
            VoiceDownloadValidation.record("failed", details: ["domain": failure.domain, "code": failure.code,
                                                               "message": failure.localizedDescription])
        }
        #endif
        pause(id, error: error.localizedDescription)
    }

    @discardableResult private func completeIfReady(_ id: String) -> Bool {
        guard let spec = specs[id], let plan = plans[id], plan.phase == .downloading,
              spec.files.allSatisfy({ plan.verified.contains($0.path) }) else { return false }
        do {
            try VoiceDownloadDisk.write(Data(spec.revision.utf8), to: spec.directory.appending(path: spec.marker))
            plans[id]?.phase = .installed
            try persist()
            #if DEBUG || CONTEUR_VALIDATION
            if id == "download-validation" { VoiceDownloadValidation.record("installed", bytes: spec.totalBytes) }
            #endif
            refresh(id)
            return true
        } catch { fail(id, error); return false }
    }

    private func validate(_ file: VoiceDownloadSpec.File, at url: URL, allowMissing: Bool = false) async throws -> Bool {
        let worker = Task.detached(priority: .utility) { () throws -> Bool in
            do { try file.validate(url); return true }
            catch is CancellationError { throw CancellationError() }
            catch { if allowMissing { return false }; throw error }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func refresh(_ id: String, status: String? = nil) {
        guard let spec = specs[id] else { return }
        let plan = plans[id]
        let installed = spec.isInstalled
        let busy = !installed && plan?.phase == .downloading
        let bytes = spec.files.reduce(Int64(0)) { sum, file in
            sum + (plan?.verified.contains(file.path) == true ? file.bytes : min(file.bytes, max(0, received["\(id):\(file.path)"] ?? 0)))
        }
        snapshots[id] = VoiceDownloadSnapshot(installed: installed, busy: busy,
            progress: installed ? 1 : min(0.99, Double(bytes) / Double(max(1, spec.totalBytes))),
            status: installed ? String(localized: "Installé · Hors ligne") : status ?? (busy ? String(localized: "Téléchargement en arrière-plan · Wi-Fi") : String(localized: "Fichiers terminés conservés")),
            error: plan?.error)
    }

    private func accepts(_ tag: VoiceDownloadTag) -> Bool {
        guard let plan = plans[tag.model], let spec = specs[tag.model] else { return false }
        return plan.phase == .downloading && plan.generation == tag.generation && plan.revision == spec.revision && file(tag) != nil
    }
    private func file(_ tag: VoiceDownloadTag) -> VoiceDownloadSpec.File? { specs[tag.model]?.files.first { $0.path == tag.path } }
    private func key(_ tag: VoiceDownloadTag) -> String { "\(tag.model):\(tag.path)" }
    private func persist() throws { try VoiceDownloadDisk.write(JSONEncoder().encode(plans), to: root.appending(path: "plans.json")) }
    private func resumeURL(_ tag: VoiceDownloadTag) -> URL {
        root.appending(path: "Resume/\(tag.model)/\(file(tag)?.sha256 ?? "unknown").data")
    }
    private func incomingURL(_ id: Int) -> URL { root.appending(path: "Incoming/\(id).download") }
    private func incomingTag(_ id: Int) -> VoiceDownloadTag? {
        (try? String(contentsOf: root.appending(path: "Incoming/\(id).json"), encoding: .utf8)).flatMap(VoiceDownloadTag.init)
    }
    private func removeIncoming(_ id: Int) {
        try? FileManager.default.removeItem(at: incomingURL(id))
        try? FileManager.default.removeItem(at: root.appending(path: "Incoming/\(id).json"))
    }
    private func scanIncoming() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "Incoming"), includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            if let id = Int(url.deletingPathExtension().lastPathComponent), let tag = incomingTag(id) { staged(id, tag: tag) }
        }
    }
    private func hasIncoming(_ tag: VoiceDownloadTag) -> Bool {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "Incoming"), includingPropertiesForKeys: nil)) ?? []
        return urls.contains { url in
            url.pathExtension == "json" && (try? String(contentsOf: url, encoding: .utf8)).flatMap(VoiceDownloadTag.init) == tag
        }
    }
    private func beginChecks() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Vérification des voix") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for check in self.checks.values { check.cancel() }
                for preparation in self.preparations.values { preparation.cancel() }
                self.endChecks()
                // Downloads remain owned by iOS; staged files stay on disk.
                self.completion?(); self.completion = nil
            }
        }
    }
    private func endChecks() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func finishEventsIfReady() {
        guard !recovering, preparations.isEmpty, checks.isEmpty else { return }
        endChecks()
        if eventsFinished, let completion { self.completion = nil; eventsFinished = false; completion() }
    }
}

/// Disk staging is synchronous inside didFinishDownloadingTo: iOS removes its
/// temporary file as soon as that delegate method returns. Only immutable tags
/// cross to the main actor; hashing happens off that actor.
private final class VoiceDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let root: URL
    let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility; return queue
    }()
    @MainActor weak var owner: VoiceDownloads?
    init(root: URL) { self.root = root }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = VoiceDownloadTag(downloadTask.taskDescription) else { return }
        let id = downloadTask.taskIdentifier
        do {
            guard let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, [200, 206].contains(status) else { throw URLError(.badServerResponse) }
            let destination = root.appending(path: "Incoming/\(id).download")
            try VoiceDownloadDisk.directory(destination.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            try VoiceDownloadDisk.protect(destination)
            try VoiceDownloadDisk.write(Data(tag.encoded.utf8), to: root.appending(path: "Incoming/\(id).json"))
            DispatchQueue.main.async { [weak self] in self?.owner?.staged(id, tag: tag) }
        } catch { DispatchQueue.main.async { [weak self] in self?.owner?.stagingFailed(id, tag: tag, error: error) } }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = VoiceDownloadTag(downloadTask.taskDescription) else { return }
        DispatchQueue.main.async { [weak self] in self?.owner?.progress(downloadTask.taskIdentifier, tag: tag, bytes: totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let tag = VoiceDownloadTag(task.taskDescription) else { return }
        DispatchQueue.main.async { [weak self] in self?.owner?.finished(task.taskIdentifier, tag: tag, error: error) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in self?.owner?.finishedEvents() }
    }
}

/// Files remain protected after reboot, but are accessible while subsequently
/// locked so iOS can deliver and verify the model with the screen off.
nonisolated enum VoiceDownloadDisk {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try protect(url)
        var directory = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

final class ConteurAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == VoiceDownloads.sessionIdentifier else { completionHandler(); return }
        VoiceDownloads.shared.handleBackgroundEvents(completionHandler: completionHandler)
    }
    func applicationDidBecomeActive(_ application: UIApplication) { VoiceDownloads.shared.foreground() }
}
